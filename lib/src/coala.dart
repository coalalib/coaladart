import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'address.dart';
import 'blockwise.dart';
import 'bytes.dart';
import 'logging.dart';
import 'message.dart';
import 'message_pool.dart';
import 'option.dart';
import 'resource.dart';
import 'serializer.dart';
import 'security.dart';
import 'tcp_serializer.dart';
import 'token.dart';
import 'types.dart';

sealed class CoalaTransport {
  const CoalaTransport();
}

class CoalaUdpTransport extends CoalaTransport {
  const CoalaUdpTransport({
    this.port = CoalaDefaults.defaultPort,
    this.bindAddress,
    this.reuseAddress = true,
    this.reusePort = false,
  });

  final int port;
  final InternetAddress? bindAddress;
  final bool reuseAddress;
  final bool reusePort;
}

class CoalaTcpTransport extends CoalaTransport {
  const CoalaTcpTransport({required this.host, required this.port});

  final String host;
  final int port;
}

class CoalaException implements Exception {
  const CoalaException(this.message);

  final String message;

  @override
  String toString() => 'CoalaException: $message';
}

class Coala implements CoalaResourceOwner {
  Coala({CoalaTransport transport = const CoalaUdpTransport()})
    : _transport = transport {
    messagePool = CoapMessagePool(resend: send);
    layerStack = LayerStack();
    resourceDiscovery = ResourceDiscovery(this);
  }

  static const defaultPort = CoalaDefaults.defaultPort;
  static CoalaLogger? get logger => CoalaLog.logger;
  static set logger(CoalaLogger? value) => CoalaLog.logger = value;
  static Future<Uint8List> get curvePublicKey =>
      CoalaSecurityKeys.publicKeyBytes();
  static Future<void> setCurvePrivateKeySeed(List<int> seed) =>
      CoalaSecurityKeys.setPrivateKeySeed(seed);

  late final CoapMessagePool messagePool;
  late final LayerStack layerStack;
  late final ResourceDiscovery resourceDiscovery;

  final List<CoapResourceProtocol> resources = [];

  CoalaTransport _transport;
  RawDatagramSocket? _udpSocket;
  Socket? _tcpSocket;
  StreamSubscription<RawSocketEvent>? _udpSubscription;
  StreamSubscription<Uint8List>? _tcpSubscription;
  final CoapTcpSerializer _tcpSerializer = CoapTcpSerializer();
  bool _discoveryResourceAdded = false;

  CoalaTransport get transport => _transport;

  bool get isSocketConnected {
    final transport = _transport;
    return switch (transport) {
      CoalaUdpTransport() => _udpSocket != null,
      CoalaTcpTransport() => _tcpSocket != null,
    };
  }

  int? get localPort => switch (_transport) {
    CoalaUdpTransport() => _udpSocket?.port,
    CoalaTcpTransport() => _tcpSocket?.port,
  };

  Future<void> start() async {
    await stop();
    final transport = _transport;
    switch (transport) {
      case CoalaUdpTransport():
        final socket = await RawDatagramSocket.bind(
          transport.bindAddress ?? InternetAddress.anyIPv4,
          transport.port,
          reuseAddress: transport.reuseAddress,
          reusePort: transport.reusePort,
        );
        try {
          socket.joinMulticast(InternetAddress(CoalaDefaults.multicastAddress));
        } on Object catch (error) {
          logWarning('Could not join CoAP multicast group: $error');
        }
        _udpSocket = socket;
        _udpSubscription = socket.listen(_handleUdpEvent);
      case CoalaTcpTransport():
        final socket = await Socket.connect(transport.host, transport.port);
        _tcpSocket = socket;
        _tcpSubscription = socket.listen(
          _handleTcpData,
          onDone: () {
            _tcpSocket = null;
          },
        );
    }
    _startDiscoveryService();
    messagePool.start();
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> stop() async {
    messagePool.stop();
    await _udpSubscription?.cancel();
    _udpSubscription = null;
    _udpSocket?.close();
    _udpSocket = null;

    await _tcpSubscription?.cancel();
    _tcpSubscription = null;
    await _tcpSocket?.close();
    _tcpSocket = null;
    _tcpSerializer.flushBuffer();
  }

  Future<void> setTransport(CoalaTransport transport) async {
    _transport = transport;
    await restart();
  }

  void configureMessagePool({
    required Duration expirationTimeout,
    required int totalResendCount,
  }) {
    messagePool
      ..resendInterval = expirationTimeout
      ..maxAttempts = totalResendCount;
    if (isSocketConnected) {
      messagePool.start();
    }
  }

  void configureMessagePoolTimeouts(List<UriPathConfig> urlPaths) {
    messagePool.longRunningUriPaths = List.unmodifiable(urlPaths);
  }

  @override
  Future<void> send(CoapMessage message) async {
    if (!isSocketConnected) {
      await start();
    }

    var address = message.address;
    if (address == null) {
      throw const CoalaException('Message address is not set.');
    }

    final processed = message.copy();
    final context = OutboundContext(address);
    try {
      await layerStack.runOutbound(this, processed, context);
      address = context.toAddress;
      final data = CoapSerializer.encode(processed);
      final transport = _transport;
      switch (transport) {
        case CoalaUdpTransport():
          final socket = _udpSocket;
          if (socket == null) {
            throw const CoalaException('UDP socket is not connected.');
          }
          final host = await _resolveAddress(address.host);
          socket.send(data, host, address.port);
        case CoalaTcpTransport():
          final socket = _tcpSocket;
          if (socket == null) {
            throw const CoalaException('TCP socket is not connected.');
          }
          socket.add(_tcpSerializer.encode(address: address, data: data));
          await socket.flush();
      }
      messagePool.push(message);
    } on _SilentlyIgnoredLayerException {
      return;
    }
  }

  Future<void> sendWithBlock2DownloadProgress(
    CoapMessage message, {
    void Function(Uint8List data)? onProgress,
  }) async {
    final key = message.token?.toString() ?? '';
    layerStack.arqLayer.block2DownloadProgresses[key] = onProgress;
    layerStack.blockwiseLayer.block2DownloadProgresses[key] = onProgress;
    await send(message);
  }

  void addResource(CoapResourceProtocol resource) {
    if (resource is CoapResource) {
      resource.owner = this;
    }
    resources.add(resource);
  }

  void removeResourcesForPath(String path) {
    resources.removeWhere((resource) {
      final matches =
          CoapResource.trimSlashes(resource.path) ==
          CoapResource.trimSlashes(path);
      if (matches && resource is CoapResource) {
        resource.owner = null;
      }
      return matches;
    });
  }

  DeliveryStatistics? getStatistics(Address address, CoapScheme scheme) =>
      messagePool.getStatistics(address, scheme);

  DeliveryStatistics? getStatisticsForMessage(CoapMessage message) {
    final address = message.address;
    return address == null
        ? null
        : messagePool.getStatistics(address, message.scheme);
  }

  void flushStatistics(Address address, CoapScheme scheme) =>
      messagePool.flushStatistics(address, scheme);

  void flushAllStatistics() => messagePool.flushAllStatistics();

  Future<void> startObserving({
    required Uri url,
    required CoalaResponseHandler onUpdate,
  }) async {
    final registerMessage =
        CoapMessage.request(
            type: CoapReliability.confirmable,
            method: CoapMethod.get,
            url: url,
          )
          ..token = resourceDiscovery.tokenForUrl(url)
          ..setIntegerOption(CoapOptionNumber.observe, 0)
          ..onResponse = onUpdate;
    await send(registerMessage);
  }

  Future<void> stopObserving({
    required Uri url,
    void Function()? onStop,
  }) async {
    final registerMessage =
        CoapMessage.request(
            type: CoapReliability.confirmable,
            method: CoapMethod.get,
            url: url,
          )
          ..token = resourceDiscovery.tokenForUrl(url)
          ..setIntegerOption(CoapOptionNumber.observe, 1)
          ..onResponse = (_) => onStop?.call();
    await send(registerMessage);
  }

  void _startDiscoveryService() {
    if (_discoveryResourceAdded) {
      return;
    }
    addResource(
      CoapDiscoveryResource(
        path: CoalaDefaults.discoveryPath,
        handler: (_) {
          final resourcesList = resources
              .map((resource) => '<${resource.path}>')
              .join(',');
          return CoapResourceResponse.string(
            CoapResponseCode.content,
            resourcesList,
          );
        },
      ),
    );
    _discoveryResourceAdded = true;
  }

  void _handleUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    final socket = _udpSocket;
    if (socket == null) {
      return;
    }
    while (true) {
      final datagram = socket.receive();
      if (datagram == null) {
        break;
      }
      final source = Address(
        host: datagram.address.address,
        port: datagram.port,
      );
      unawaited(_decodePayload(from: source, payload: datagram.data));
    }
  }

  void _handleTcpData(Uint8List data) {
    for (final frame in _tcpSerializer.decode(data)) {
      unawaited(_decodePayload(from: frame.address, payload: frame.data));
    }
  }

  Future<void> _decodePayload({
    required Address from,
    required List<int> payload,
  }) async {
    CoapMessage message;
    try {
      message = CoapSerializer.decode(payload);
    } on Object catch (error) {
      logError('Could not deserialize CoAP message: $error');
      return;
    }
    message.address ??= from;
    final context = InboundContext(from);
    try {
      await layerStack.runInbound(this, message, context);
    } on _SilentlyIgnoredLayerException {
      // Layer already handled the message, usually by sending an ACK.
    } on Object catch (error, stackTrace) {
      logError('Inbound CoAP processing failed: $error');
      message.onResponse?.call(CoalaErrorResponse(error, stackTrace));
    } finally {
      final ack = context.ack;
      if (ack != null) {
        await send(ack);
      }
    }
  }

  Future<InternetAddress> _resolveAddress(String host) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      return literal;
    }
    final addresses = await InternetAddress.lookup(host);
    if (addresses.isEmpty) {
      throw CoalaException('Could not resolve host $host.');
    }
    return addresses.first;
  }
}

class ResourceDiscovery {
  ResourceDiscovery(this._coala);

  final Coala _coala;

  Future<Map<Address, CoapMessage>> run({
    String path = CoalaDefaults.discoveryPath,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    if (_coala.transport is! CoalaUdpTransport) {
      return const {};
    }
    final responses = <Address, CoapMessage>{};
    final url = Uri(
      scheme: CoapScheme.coap.text,
      host: CoalaDefaults.multicastAddress,
      port: CoalaDefaults.defaultPort,
      path: path,
    );
    final message =
        CoapMessage.request(
            type: CoapReliability.nonConfirmable,
            method: CoapMethod.get,
            url: url,
          )
          ..onResponse = (response) {
            if (response case CoalaMessageResponse(
              :final message,
              :final from,
            )) {
              responses[from] = message;
            }
          };
    await _coala.send(message);
    await Future<void>.delayed(timeout);
    return responses;
  }

  CoapToken tokenForUrl(Uri url) => CoapToken(
    sha256
        .convert(utf8.encode(url.toString()))
        .bytes
        .take(CoapToken.maxLength)
        .toList(growable: false),
  );
}

class LayerStack {
  LayerStack()
    : proxyLayer = ProxyLayer(),
      reliabilityLayer = ReliabilityLayer(),
      requestLayer = RequestLayer(),
      responseLayer = ResponseLayer(),
      observeLayer = ObserveLayer(),
      securityLayer = SecurityLayer(),
      arqLayer = ArqLayer(),
      blockwiseLayer = BlockwiseLayer(),
      logLayer = LogLayer();

  final ProxyLayer proxyLayer;
  final ReliabilityLayer reliabilityLayer;
  final RequestLayer requestLayer;
  final ResponseLayer responseLayer;
  final ObserveLayer observeLayer;
  final SecurityLayer securityLayer;
  final ArqLayer arqLayer;
  final BlockwiseLayer blockwiseLayer;
  final LogLayer logLayer;

  late final List<InLayer> inLayers = [
    proxyLayer,
    securityLayer,
    logLayer,
    reliabilityLayer,
    arqLayer,
    blockwiseLayer,
    observeLayer,
    requestLayer,
    responseLayer,
  ];

  late final List<OutLayer> outLayers = [
    observeLayer,
    arqLayer,
    blockwiseLayer,
    logLayer,
    securityLayer,
    proxyLayer,
  ];

  Future<void> runOutbound(
    Coala coala,
    CoapMessage message,
    OutboundContext context,
  ) async {
    for (final layer in outLayers) {
      await layer.runOutbound(coala, message, context);
    }
  }

  Future<void> runInbound(
    Coala coala,
    CoapMessage message,
    InboundContext context,
  ) async {
    Object? stackError;
    StackTrace? stackTrace;
    for (final layer in inLayers) {
      try {
        await layer.runInbound(coala, message, context);
      } on _SilentlyIgnoredLayerException catch (error, trace) {
        stackError = error;
        stackTrace = trace;
        break;
      } on Object catch (error, trace) {
        stackError = error;
        stackTrace = trace;
        break;
      }
    }
    if (stackError != null) {
      Error.throwWithStackTrace(stackError, stackTrace ?? StackTrace.current);
    }
  }
}

class OutboundContext {
  OutboundContext(this.toAddress);

  Address toAddress;
}

class InboundContext {
  InboundContext(this.fromAddress);

  Address fromAddress;
  CoapMessage? ack;
}

abstract interface class InLayer {
  FutureOr<void> runInbound(
    Coala coala,
    CoapMessage message,
    InboundContext context,
  );
}

abstract interface class OutLayer {
  FutureOr<void> runOutbound(
    Coala coala,
    CoapMessage message,
    OutboundContext context,
  );
}

class ProxyLayer implements InLayer, OutLayer {
  @override
  void runInbound(Coala coala, CoapMessage message, InboundContext context) {
    final previousMessage = coala.messagePool.getSourceMessageFor(message);
    final proxyViaAddress = previousMessage?.proxyViaAddress;
    final realAddress = previousMessage?.address;
    if (proxyViaAddress != null &&
        realAddress != null &&
        proxyViaAddress == context.fromAddress) {
      message
        ..proxyViaAddress = proxyViaAddress
        ..address = realAddress;
      context.fromAddress = realAddress;
    }
    if (message.getOptions(CoapOptionNumber.proxyUri).isNotEmpty) {
      context.ack = CoapMessage.ackTo(
        request: message,
        from: context.fromAddress,
        code: CoapResponseCode.proxyingNotSupported,
      );
      throw const _SilentlyIgnoredLayerException();
    }
  }

  @override
  void runOutbound(Coala coala, CoapMessage message, OutboundContext context) {
    final proxyAddress = message.proxyViaAddress;
    if (proxyAddress == null) {
      return;
    }
    final url = message.url;
    if (url == null || url.host.isEmpty) {
      message.removeOption(CoapOptionNumber.proxyUri);
      context.toAddress = proxyAddress;
      return;
    }
    final port = url.hasPort ? url.port : CoalaDefaults.defaultPort;
    message.setStringOption(
      CoapOptionNumber.proxyUri,
      '${url.scheme}://${url.host}:$port',
    );
    context.toAddress = proxyAddress;
  }
}

class ReliabilityLayer implements InLayer {
  @override
  void runInbound(Coala coala, CoapMessage message, InboundContext context) {
    switch (message.type) {
      case CoapReliability.confirmable:
        context.ack = CoapMessage.ackTo(
          request: message,
          from: context.fromAddress,
          code: CoapResponseCode.empty,
        );
      case CoapReliability.acknowledgement:
      case CoapReliability.reset:
        if (message.code != const CoapCode.response(CoapResponseCode.empty) &&
            message
                .getOptions(CoapOptionNumber.selectiveRepeatWindowSize)
                .isNotEmpty) {
          coala.messagePool.didTransmitMessage(message.messageId);
        }
      case CoapReliability.nonConfirmable:
        break;
    }
  }
}

class SecurityLayer implements InLayer, OutLayer {
  final Map<SecuredSessionKey, SecuredSession> _securedSessionPool = {};
  final Map<Address, int> _proxySecurityIdPool = {};
  final List<CoapMessage> _pendingMessages = [];

  @override
  Future<void> runInbound(
    Coala coala,
    CoapMessage message,
    InboundContext context,
  ) async {
    if (message.scheme != CoapScheme.coapSecure) {
      if (message
              .getIntegerOptions(CoapOptionNumber.handshakeType)
              .firstOrNull ==
          1) {
        await _handleIncomingHandshake(coala, message, context);
        return;
      }

      final hasSessionError =
          message
              .getIntegerOptions(CoapOptionNumber.sessionNotFound)
              .isNotEmpty ||
          message.getIntegerOptions(CoapOptionNumber.sessionExpired).isNotEmpty;
      if (hasSessionError) {
        final sourceMessage = coala.messagePool.getSourceMessageFor(message);
        if (sourceMessage != null) {
          coala.messagePool.remove(sourceMessage);
          sourceMessage.address = context.fromAddress;
          final proxySecurityId = sourceMessage.proxyViaAddress == null
              ? null
              : _proxySecurityIdPool[context.fromAddress];
          _startSession(
            sessionKey: SecuredSessionKey(
              address: context.fromAddress,
              proxyAddress: sourceMessage.proxyViaAddress,
              proxySecurityId: proxySecurityId,
            ),
            toAddress: context.fromAddress,
            coala: coala,
            message: sourceMessage,
          );
        }
      }
      return;
    }

    var sessionAddress = context.fromAddress;
    final proxySecurityId = _proxySecurityId(message);
    if (proxySecurityId != null) {
      final outgoingMessage = coala.messagePool.getSourceMessageFor(message);
      final outgoingAddress = outgoingMessage?.address;
      if (outgoingAddress != null &&
          outgoingMessage!.getOptions(CoapOptionNumber.proxyUri).isEmpty) {
        sessionAddress = outgoingAddress;
      }
    }

    final sessionKey = SecuredSessionKey(
      address: sessionAddress,
      proxyAddress: message.proxyViaAddress,
      proxySecurityId: proxySecurityId,
    );
    final session = _securedSessionPool[sessionKey];
    final aead = session?.aead;
    if (session == null || aead == null) {
      final sessionNotFound =
          CoapMessage.ackTo(
              request: message,
              from: context.fromAddress,
              code: CoapResponseCode.unauthorized,
            )
            ..url = context.fromAddress.uriForScheme(CoapScheme.coap)
            ..setIntegerOption(CoapOptionNumber.sessionNotFound, 1);
      if (proxySecurityId != null) {
        sessionNotFound.setIntegerOption(
          CoapOptionNumber.proxySecurityId,
          proxySecurityId,
        );
      }
      await coala.send(sessionNotFound);
      throw const _SilentlyIgnoredLayerException();
    }

    final payload = message.payload;
    if (payload != null) {
      message.payload = aead.open(payload, counter: message.messageId);
    }
    final encryptedUri = message
        .getOptions(CoapOptionNumber.coapsUri)
        .firstOrNull
        ?.value;
    if (encryptedUri != null) {
      final urlData = aead.open(encryptedUri, counter: message.messageId);
      message.url = Uri.parse(bytesToString(urlData));
    }
    message.peerPublicKey = session.peerPublicKey;
  }

  @override
  Future<void> runOutbound(
    Coala coala,
    CoapMessage message,
    OutboundContext context,
  ) async {
    if (message.scheme != CoapScheme.coapSecure) {
      return;
    }

    int? proxySecurityId;
    if (message.proxyViaAddress != null) {
      proxySecurityId =
          _proxySecurityIdPool[context.toAddress] ??
          Random.secure().nextInt(1 << 32);
      _proxySecurityIdPool[context.toAddress] = proxySecurityId;
    }
    message.setOption(
      CoapOptionNumber.proxySecurityId,
      proxySecurityId == null ? null : intToMinimalBytes(proxySecurityId),
    );

    final sessionKey = SecuredSessionKey(
      address: context.toAddress,
      proxyAddress: message.proxyViaAddress,
      proxySecurityId: proxySecurityId,
    );
    final session = _securedSessionPool[sessionKey];
    if (session == null) {
      _startSession(
        sessionKey: sessionKey,
        toAddress: context.toAddress,
        coala: coala,
        message: message,
      );
      throw const _SilentlyIgnoredLayerException();
    }

    final aead = session.aead;
    if (aead == null) {
      _pendingMessages.add(message.copy());
      throw const _SilentlyIgnoredLayerException();
    }

    final payload = message.payload;
    if (payload != null) {
      message.payload = aead.seal(payload, counter: message.messageId);
    }
    final url = message.url;
    if (url != null) {
      message.setOption(
        CoapOptionNumber.coapsUri,
        aead.seal(stringToBytes(url.toString()), counter: message.messageId),
      );
    }
    message
      ..removeOption(CoapOptionNumber.uriPath)
      ..removeOption(CoapOptionNumber.uriQuery);
  }

  Future<void> _handleIncomingHandshake(
    Coala coala,
    CoapMessage message,
    InboundContext context,
  ) async {
    final payload = message.payload;
    if (payload == null) {
      throw const CoalaException('Handshake payload is missing.');
    }
    if (message.requestMethod != CoapMethod.get) {
      return;
    }
    final proxySecurityId = _proxySecurityId(message);
    final sessionKey = SecuredSessionKey(
      address: context.fromAddress,
      proxyAddress: message.proxyViaAddress,
      proxySecurityId: proxySecurityId,
    );
    final session = SecuredSession(incoming: true);
    _securedSessionPool[sessionKey] = session;
    await session.start(payload);
    final response =
        CoapMessage.ackTo(
            request: message,
            from: context.fromAddress,
            code: CoapResponseCode.content,
          )
          ..setIntegerOption(CoapOptionNumber.handshakeType, 2)
          ..payload = await session.publicKey;
    if (proxySecurityId != null) {
      response.setIntegerOption(
        CoapOptionNumber.proxySecurityId,
        proxySecurityId,
      );
    }
    await coala.send(response);
    throw const _SilentlyIgnoredLayerException();
  }

  void _startSession({
    required SecuredSessionKey sessionKey,
    required Address toAddress,
    required Coala coala,
    required CoapMessage message,
  }) {
    final session = SecuredSession(incoming: false);
    _securedSessionPool[sessionKey] = session;
    _pendingMessages.add(message.copy());
    final handshake =
        _performHandshake(
          coala: coala,
          session: session,
          address: toAddress,
          proxySecurityId: sessionKey.proxySecurityId,
          triggeredBy: message,
          sessionKey: sessionKey,
        ).catchError((Object error, StackTrace stackTrace) {
          _securedSessionPool.remove(sessionKey);
          _failPendingMessages(toAddress, error, stackTrace);
        });
    unawaited(handshake);
  }

  Future<void> _performHandshake({
    required Coala coala,
    required SecuredSession session,
    required Address address,
    required CoapMessage triggeredBy,
    required SecuredSessionKey sessionKey,
    int? proxySecurityId,
  }) async {
    final message =
        CoapMessage.request(
            type: CoapReliability.confirmable,
            method: CoapMethod.get,
            url: address.uriForScheme(CoapScheme.coap),
          )
          ..setIntegerOption(CoapOptionNumber.handshakeType, 1)
          ..payload = await session.publicKey
          ..proxyViaAddress = triggeredBy.proxyViaAddress;
    if (proxySecurityId != null) {
      message.setIntegerOption(
        CoapOptionNumber.proxySecurityId,
        proxySecurityId,
      );
    }
    message.onResponse = (response) {
      unawaited(
        _handleHandshakeResponse(
          response,
          session: session,
          address: address,
          triggeredBy: triggeredBy,
          sessionKey: sessionKey,
          coala: coala,
        ),
      );
    };
    await coala.send(message);
  }

  Future<void> _handleHandshakeResponse(
    CoalaResponse response, {
    required SecuredSession session,
    required Address address,
    required CoapMessage triggeredBy,
    required SecuredSessionKey sessionKey,
    required Coala coala,
  }) async {
    try {
      final peerKey = switch (response) {
        CoalaMessageResponse(:final message, :final from) =>
          _peerKeyFromHandshakeResponse(message, from, session),
        CoalaErrorResponse(:final error) => throw error,
      };
      final expectedPeerKey = triggeredBy.peerPublicKey;
      if (expectedPeerKey != null && !listEquals(peerKey, expectedPeerKey)) {
        throw const CoapsException('Peer public key validation failed.');
      }
      await session.start(peerKey);
      _sendPendingMessages(address, coala);
    } on Object catch (error, stackTrace) {
      _securedSessionPool.remove(sessionKey);
      _failPendingMessages(address, error, stackTrace);
    }
  }

  Uint8List _peerKeyFromHandshakeResponse(
    CoapMessage message,
    Address from,
    SecuredSession session,
  ) {
    final payload = message.payload;
    if (payload == null) {
      throw const CoalaException('Handshake response payload is missing.');
    }
    final responseSessionKey = SecuredSessionKey(
      address: from,
      proxyAddress: message.proxyViaAddress,
      proxySecurityId: _proxySecurityId(message),
    );
    _securedSessionPool[responseSessionKey] = session;
    return payload;
  }

  int? _proxySecurityId(CoapMessage message) =>
      message.getIntegerOptions(CoapOptionNumber.proxySecurityId).firstOrNull;

  void _sendPendingMessages(Address toAddress, Coala coala) {
    final pending = _removePendingMessages(toAddress);
    for (final message in pending) {
      unawaited(coala.send(message));
    }
  }

  void _failPendingMessages(
    Address toAddress,
    Object error,
    StackTrace stackTrace,
  ) {
    final pending = _removePendingMessages(toAddress);
    for (final message in pending) {
      message.onResponse?.call(CoalaErrorResponse(error, stackTrace));
    }
  }

  List<CoapMessage> _removePendingMessages(Address toAddress) {
    final pending = _pendingMessages
        .where((message) => message.address == toAddress)
        .map((message) => message.copy())
        .toList(growable: false);
    _pendingMessages.removeWhere((message) => message.address == toAddress);
    return pending;
  }
}

class SecuredSessionKey {
  const SecuredSessionKey({
    required this.address,
    this.proxyAddress,
    this.proxySecurityId,
  });

  final Address address;
  final Address? proxyAddress;
  final int? proxySecurityId;

  @override
  bool operator ==(Object other) =>
      other is SecuredSessionKey &&
      other.address == address &&
      other.proxyAddress == proxyAddress &&
      other.proxySecurityId == proxySecurityId;

  @override
  int get hashCode => Object.hash(address, proxyAddress, proxySecurityId);
}

class RequestLayer implements InLayer {
  @override
  Future<void> runInbound(
    Coala coala,
    CoapMessage message,
    InboundContext context,
  ) async {
    final method = message.requestMethod;
    final path = message.url?.path;
    if (method == null ||
        path == null ||
        (message.type != CoapReliability.confirmable &&
            message.type != CoapReliability.nonConfirmable)) {
      return;
    }

    final resourcesAtPath = coala.resources
        .where(
          (resource) =>
              CoapResource.trimSlashes(resource.path) ==
              CoapResource.trimSlashes(path),
        )
        .toList(growable: false);
    final resourcesWithMethod = resourcesAtPath
        .where((resource) => resource.method == method)
        .toList(growable: false);

    if (resourcesWithMethod.isEmpty) {
      final errorCode = resourcesAtPath.isNotEmpty
          ? CoapResponseCode.methodNotAllowed
          : CoapResponseCode.notFound;
      if (context.ack != null) {
        context.ack!.code = CoapCode.response(errorCode);
      } else {
        await coala.send(
          CoapMessage(
            type: CoapReliability.nonConfirmable,
            code: CoapCode.response(errorCode),
            messageId: message.messageId,
          )..url = context.fromAddress.uriForScheme(message.scheme),
        );
      }
      return;
    }

    for (final resource in resourcesWithMethod) {
      final resourceResponse = resource.responseForRequest(
        message,
        context.fromAddress,
      );
      if (context.ack != null) {
        context.ack!
          ..code = resourceResponse.code
          ..payload = resourceResponse.payload;
        for (final option in resourceResponse.options) {
          context.ack!.setOption(option.number, option.value);
        }
      } else {
        final separateResponse =
            CoapMessage(
                type: CoapReliability.nonConfirmable,
                code: resourceResponse.code,
                messageId: message.messageId,
              )
              ..payload = resourceResponse.payload
              ..url = context.fromAddress.uriForScheme(message.scheme)
              ..token = message.token;
        for (final option in resourceResponse.options) {
          separateResponse.setOption(option.number, option.value);
        }
        await coala.send(separateResponse);
      }
    }
  }
}

class ResponseLayer implements InLayer {
  @override
  void runInbound(Coala coala, CoapMessage message, InboundContext context) {
    if (!message.isResponse) {
      return;
    }
    final sourceMessage = coala.messagePool.getSourceMessageFor(message);
    if (sourceMessage == null) {
      if (message.getIntegerOptions(CoapOptionNumber.observe).isEmpty) {
        logWarning(
          'Pool did not find outgoing request for message id ${message.messageId}',
        );
      }
      return;
    }
    final response = message.type == CoapReliability.reset
        ? const CoalaErrorResponse(CoalaException('Request has been reset.'))
        : CoalaMessageResponse(message: message, from: context.fromAddress);
    scheduleMicrotask(() {
      if (coala.messagePool.getByMessageId(sourceMessage.messageId) == null) {
        return;
      }
      sourceMessage.onResponse?.call(response);
      if (!sourceMessage.isMulticast) {
        coala.messagePool.remove(sourceMessage);
      }
    });
  }
}

class ObserveLayer implements InLayer, OutLayer {
  final ObservedResourcesRegistry observedResourcesRegistry =
      ObservedResourcesRegistry();

  @override
  Future<void> runInbound(
    Coala coala,
    CoapMessage message,
    InboundContext context,
  ) async {
    if (message.code.method case final method?) {
      await _processRequest(method, coala, message, context);
      return;
    }
    final responseCode = message.code.responseCode;
    if (responseCode != null && responseCode != CoapResponseCode.empty) {
      _processResponse(responseCode, coala, message, context);
    }
  }

  @override
  void runOutbound(Coala coala, CoapMessage message, OutboundContext context) {
    final observeAction = message
        .getIntegerOptions(CoapOptionNumber.observe)
        .firstOrNull;
    if (message.requestMethod != CoapMethod.get ||
        observeAction == null ||
        message.token == null) {
      return;
    }
    if (observeAction == 0 &&
        message.url != null &&
        message.onResponse != null) {
      observedResourcesRegistry.didStartObserving(
        ObservedResource(
          url: message.url!,
          coala: coala,
          handler: message.onResponse!,
        ),
        message.token!,
      );
    } else if (observeAction == 1) {
      observedResourcesRegistry.didStopObservingResource(message.token!);
    }
  }

  Future<void> _processRequest(
    CoapMethod method,
    Coala coala,
    CoapMessage message,
    InboundContext context,
  ) async {
    final path = message.url?.path;
    final observeOption = message
        .getIntegerOptions(CoapOptionNumber.observe)
        .firstOrNull;
    if (method != CoapMethod.get || path == null || observeOption == null) {
      return;
    }
    for (final resource in coala.resources) {
      if (resource is! ObservableResource || !resource.matches(method, path)) {
        continue;
      }
      final observer = CoapObserver(
        address: context.fromAddress,
        registerMessage: message,
      );
      switch (observeOption) {
        case 0:
          resource.addObserver(observer);
          final notification = resource.responseForRequest(
            message,
            context.fromAddress,
          );
          context.ack
            ?..code = notification.code
            ..payload = notification.payload
            ..setIntegerOption(
              CoapOptionNumber.observe,
              resource.sequenceNumber,
            );
          throw const _SilentlyIgnoredLayerException();
        case 1:
          resource.removeObserver(observer);
      }
    }
  }

  void _processResponse(
    CoapResponseCode code,
    Coala coala,
    CoapMessage message,
    InboundContext context,
  ) {
    final token = message.token;
    if (token == null) {
      return;
    }
    final observeOption = message
        .getIntegerOptions(CoapOptionNumber.observe)
        .firstOrNull;
    if (observedResourcesRegistry.resourceForToken(token) != null) {
      coala.messagePool.remove(message);
      final notification = ObserverNotification(
        message: message,
        from: context.fromAddress,
        sequenceNumber: observeOption,
        maxAge: message.getIntegerOptions(CoapOptionNumber.maxAge).firstOrNull,
      );
      observedResourcesRegistry.didReceive(notification, token);
      if (observeOption == null || code.isError) {
        observedResourcesRegistry.didStopObservingResource(token);
      }
      if (observeOption != null) {
        context.ack?.setIntegerOption(CoapOptionNumber.observe, observeOption);
      }
    } else if (observeOption != null) {
      final reset =
          CoapMessage(
              type: CoapReliability.reset,
              code: const CoapCode.response(CoapResponseCode.notFound),
              messageId: message.messageId,
            )
            ..url = context.fromAddress.uriForScheme(message.scheme)
            ..token = token;
      unawaited(coala.send(reset));
    }
  }
}

class ObservedResource {
  ObservedResource({
    required this.url,
    required this.coala,
    required this.handler,
  });

  final Uri url;
  final Coala coala;
  final CoalaResponseHandler handler;
  DateTime? validUntil;
  int? sequenceNumber;
}

class ObserverNotification {
  const ObserverNotification({
    required this.message,
    required this.from,
    this.sequenceNumber,
    this.maxAge,
  });

  final CoapMessage message;
  final Address from;
  final int? sequenceNumber;
  final int? maxAge;
}

class ObservedResourcesRegistry {
  final Map<CoapToken, ObservedResource> _tokenToResource = {};
  Timer? _timer;

  ObservedResource? resourceForToken(CoapToken token) =>
      _tokenToResource[token];

  void didStartObserving(ObservedResource resource, CoapToken token) {
    _tokenToResource[token] = resource;
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void didStopObservingResource(CoapToken token) {
    _tokenToResource.remove(token);
    if (_tokenToResource.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void didReceive(ObserverNotification notification, CoapToken token) {
    final resource = _tokenToResource[token];
    if (resource == null) {
      return;
    }
    final previous = resource.sequenceNumber;
    final current = notification.sequenceNumber;
    if (previous != null && current != null && previous >= current) {
      return;
    }
    resource.handler(
      CoalaMessageResponse(
        message: notification.message,
        from: notification.from,
      ),
    );
    resource
      ..validUntil = _expirationDateFor(notification.maxAge)
      ..sequenceNumber = current;
  }

  DateTime? _expirationDateFor(int? maxAge) {
    if (maxAge == null) {
      return null;
    }
    return DateTime.now().add(Duration(seconds: maxAge + 5));
  }

  void _tick() {
    for (final entry in _tokenToResource.entries.toList(growable: false)) {
      final resource = entry.value;
      final validUntil = resource.validUntil;
      if (validUntil != null && validUntil.isBefore(DateTime.now())) {
        unawaited(
          resource.coala.startObserving(
            url: resource.url,
            onUpdate: resource.handler,
          ),
        );
        _tokenToResource.remove(entry.key);
      }
    }
  }
}

class ArqLayer implements InLayer, OutLayer {
  static const blockSize = CoapBlockSize.size1024;

  final Map<CoapToken, _ArqReceiveState> _rxStates = {};
  final Map<CoapToken, _ArqTransmitState> _txStates = {};
  final Map<String, void Function(Uint8List data)?> block2DownloadProgresses =
      {};
  int defaultSendWindowSize = 70;

  @override
  Future<void> runInbound(
    Coala coala,
    CoapMessage message,
    InboundContext context,
  ) async {
    final token = message.token;
    if (token == null ||
        message
            .getOptions(CoapOptionNumber.selectiveRepeatWindowSize)
            .isEmpty) {
      return;
    }
    final windowSize =
        message
            .getIntegerOptions(CoapOptionNumber.selectiveRepeatWindowSize)
            .firstOrNull ??
        defaultSendWindowSize;
    for (final optionNumber in [
      CoapOptionNumber.block1,
      CoapOptionNumber.block2,
    ]) {
      final blockValue = message.getIntegerOptions(optionNumber).firstOrNull;
      if (blockValue == null) {
        continue;
      }
      final block = CoapBlockOption.fromInteger(blockValue);
      await _processIncomingBlock(
        coala: coala,
        message: message,
        context: context,
        token: token,
        block: block,
        optionNumber: optionNumber,
        windowSize: windowSize,
      );
    }
  }

  @override
  Future<void> runOutbound(
    Coala coala,
    CoapMessage message,
    OutboundContext context,
  ) async {
    final token = message.token;
    final payload = message.payload;
    if (token == null || payload == null || payload.length <= blockSize.bytes) {
      return;
    }

    coala.messagePool.remove(message);
    final originalMessage = message.copy();
    if (originalMessage.type != CoapReliability.confirmable) {
      originalMessage.type = CoapReliability.confirmable;
    }
    final srState = SrTxState(
      data: payload,
      windowSize: defaultSendWindowSize,
      blockSize: blockSize.bytes,
    );
    _txStates[token] = _ArqTransmitState(
      token: token,
      originalMessage: originalMessage,
      selectiveRepeat: srState,
    );
    await _sendMoreData(coala, token);
    throw const _SilentlyIgnoredLayerException();
  }

  Future<void> _processIncomingBlock({
    required Coala coala,
    required CoapMessage message,
    required InboundContext context,
    required CoapToken token,
    required CoapBlockOption block,
    required CoapOptionNumber optionNumber,
    required int windowSize,
  }) async {
    switch (message.type) {
      case CoapReliability.acknowledgement:
      case CoapReliability.reset:
        final timesSent = coala.messagePool.timesSent(message.messageId) ?? 0;
        final retransmits = timesSent > 0 ? timesSent - 1 : 0;
        _didTransmit(block.num, token, retransmits);
        coala.messagePool.removeByMessageId(message.messageId);
        final state = _txStates[token];
        if (state == null) {
          throw const CoalaException('Unexpected ARQ acknowledgement.');
        }
        if (state.selectiveRepeat.isCompleted) {
          _txStates.remove(token);
          coala.messagePool.push(state.originalMessage);
          return;
        }
        await _sendMoreData(coala, token);
        throw const _SilentlyIgnoredLayerException();

      case CoapReliability.confirmable:
        final payload = message.payload;
        if (payload == null) {
          throw const CoalaException('ARQ payload is missing.');
        }
        final state = _rxStates.putIfAbsent(
          token,
          () => _ArqReceiveState(
            token: token,
            outboundMessage: coala.messagePool.getByToken(token),
            originalMessage: message.copy(),
            selectiveRepeat: SrRxState(),
          ),
        );
        state.selectiveRepeat.didReceive(
          block: payload,
          number: block.num,
          isFinalBlock: !block.more,
        );
        block2DownloadProgresses[token.toString()]?.call(
          copyBytes(state.selectiveRepeat.accumulator),
        );

        context.ack
          ?..setIntegerOption(optionNumber, block.value)
          ..setIntegerOption(
            CoapOptionNumber.selectiveRepeatWindowSize,
            windowSize,
          )
          ..proxyViaAddress = message.proxyViaAddress;

        final outboundMessage = state.outboundMessage;
        if (outboundMessage != null) {
          coala.messagePool.flushPoolMetrics(outboundMessage);
        }

        final data = state.selectiveRepeat.data;
        if (data != null) {
          if (outboundMessage != null) {
            coala.messagePool.push(outboundMessage);
          }
          message.payload = copyBytes(data);
          message.options
            ..clear()
            ..addAll(
              state.originalMessage.options.where(
                (option) =>
                    !option.number.isBlock &&
                    option.number != CoapOptionNumber.selectiveRepeatWindowSize,
              ),
            );
          _rxStates.remove(token);
          block2DownloadProgresses.remove(token.toString());
          return;
        }

        if (context.ack != null) {
          context.ack!.code = const CoapCode.response(
            CoapResponseCode.continued,
          );
        }
        throw const _SilentlyIgnoredLayerException();

      case CoapReliability.nonConfirmable:
        throw const CoalaException('ARQ expects CON block messages.');
    }
  }

  Future<void> _sendMoreData(Coala coala, CoapToken token) async {
    while (true) {
      final state = _txStates[token];
      final block = state?.selectiveRepeat.popBlock();
      if (state == null || block == null) {
        return;
      }
      await _sendBlock(
        coala,
        block,
        state.originalMessage,
        token,
        state.selectiveRepeat.windowSize,
      );
    }
  }

  Future<void> _sendBlock(
    Coala coala,
    SrTxBlock block,
    CoapMessage originalMessage,
    CoapToken token,
    int windowSize,
  ) async {
    final blockMessage =
        CoapMessage(type: originalMessage.type, code: originalMessage.code)
          ..payload = copyBytes(block.data)
          ..token = token
          ..address = originalMessage.address
          ..proxyViaAddress = originalMessage.proxyViaAddress
          ..peerPublicKey = originalMessage.peerPublicKey;
    for (final option in originalMessage.options) {
      blockMessage.setOption(option.number, option.value);
    }
    final blockOption = CoapBlockOption(
      num: block.number,
      more: block.more,
      size: blockSize,
    );
    blockMessage.setIntegerOption(
      originalMessage.isRequest
          ? CoapOptionNumber.block1
          : CoapOptionNumber.block2,
      blockOption.value,
    );
    blockMessage.setIntegerOption(
      CoapOptionNumber.selectiveRepeatWindowSize,
      windowSize,
    );
    blockMessage.onResponse = (response) {
      if (response case CoalaErrorResponse(:final error, :final stackTrace)) {
        _fail(error, stackTrace, token);
      }
    };
    await coala.send(blockMessage);
  }

  void _didTransmit(int blockNumber, CoapToken token, int retransmits) {
    final state = _txStates[token];
    if (state == null) {
      return;
    }
    state
      ..retransmitCount += retransmits
      ..selectiveRepeat.didTransmit(blockNumber);
  }

  void _fail(Object error, StackTrace? stackTrace, CoapToken token) {
    final state = _txStates[token];
    state?.originalMessage.onResponse?.call(
      CoalaErrorResponse(error, stackTrace),
    );
    _rxStates.remove(token);
    _txStates.remove(token);
  }
}

class _ArqTransmitState {
  _ArqTransmitState({
    required this.token,
    required this.originalMessage,
    required this.selectiveRepeat,
  });

  final CoapToken token;
  final CoapMessage originalMessage;
  final SrTxState selectiveRepeat;
  int retransmitCount = 0;
}

class _ArqReceiveState {
  _ArqReceiveState({
    required this.token,
    required this.outboundMessage,
    required this.originalMessage,
    required this.selectiveRepeat,
  });

  final CoapToken token;
  final CoapMessage? outboundMessage;
  final CoapMessage originalMessage;
  final SrRxState selectiveRepeat;
}

class BlockwiseLayer implements InLayer, OutLayer {
  static const blockSize = CoapBlockSize.size1024;

  final Map<CoapToken, _BlockwiseState> _stateForToken = {};
  final Map<String, void Function(Uint8List data)?> block2DownloadProgresses =
      {};

  @override
  Future<void> runInbound(
    Coala coala,
    CoapMessage message,
    InboundContext context,
  ) async {
    final block1 = message.block1Option;
    if (block1 != null) {
      _processIncomingBlock(message, block1, CoapOptionNumber.block1, context);
    }
    final block2 = message.block2Option;
    if (block2 != null) {
      _processIncomingBlock(message, block2, CoapOptionNumber.block2, context);
    }
  }

  @override
  void runOutbound(Coala coala, CoapMessage message, OutboundContext context) {
    final option = message.isRequest
        ? message.block1Option
        : message.block2Option;
    _trimOutgoingMessage(message, option);
  }

  void _processIncomingBlock(
    CoapMessage message,
    CoapBlockOption option,
    CoapOptionNumber optionNumber,
    InboundContext context,
  ) {
    final token = message.token;
    if (token == null) {
      return;
    }
    final payload = message.payload;
    if (payload == null) {
      throw const CoalaException('Blockwise message payload is missing.');
    }
    final state = option.num == 0 ? _BlockwiseState() : _stateForToken[token];
    if (state == null) {
      throw const CoalaException('Unexpected blockwise continuation.');
    }
    if (state.expectedNextNum != option.num) {
      throw const CoalaException('Out-of-order blockwise segment.');
    }
    state
      ..accumulator.addAll(payload)
      ..expectedNextNum = option.num + 1;
    if (optionNumber == CoapOptionNumber.block2) {
      block2DownloadProgresses[token.toString()]?.call(
        copyBytes(state.accumulator),
      );
    }
    context.ack?.setIntegerOption(optionNumber, option.value);
    if (option.more) {
      _stateForToken[token] = state;
      if (context.ack != null) {
        context.ack!.code = const CoapCode.response(CoapResponseCode.continued);
      }
      throw const _SilentlyIgnoredLayerException();
    }
    message
      ..payload = copyBytes(state.accumulator)
      ..removeOption(optionNumber);
    _stateForToken.remove(token);
    block2DownloadProgresses.remove(token.toString());
  }

  void _trimOutgoingMessage(
    CoapMessage message,
    CoapBlockOption? requestedOption,
  ) {
    final payload = message.payload;
    if (payload == null || payload.length <= blockSize.bytes) {
      return;
    }
    final rangeStart = (requestedOption?.num ?? 0) * blockSize.bytes;
    final rangeEnd = (rangeStart + blockSize.bytes).clamp(0, payload.length);
    final moreDataLeft = rangeEnd < payload.length;
    message.payload = copyBytes(payload.sublist(rangeStart, rangeEnd));
    final blockOption = CoapBlockOption(
      num: requestedOption?.num ?? 0,
      more: moreDataLeft,
      size: blockSize,
    );
    if (message.isRequest) {
      message.block1Option = blockOption;
    } else {
      message.block2Option = blockOption;
    }
  }
}

class _BlockwiseState {
  final List<int> accumulator = [];
  int expectedNextNum = 0;
}

class LogLayer implements InLayer, OutLayer {
  bool visual = false;

  @override
  void runInbound(Coala coala, CoapMessage message, InboundContext context) {
    logInfo(
      'Receiving message: ${message.longDescription} from: ${context.fromAddress}',
    );
  }

  @override
  void runOutbound(Coala coala, CoapMessage message, OutboundContext context) {
    final proxy = message.proxyViaAddress == null
        ? ''
        : ' via proxy ${message.proxyViaAddress}';
    logInfo(
      'Sending message: ${message.longDescription} to: ${context.toAddress}$proxy',
    );
  }
}

class _SilentlyIgnoredLayerException implements Exception {
  const _SilentlyIgnoredLayerException();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    return iterator.current;
  }
}
