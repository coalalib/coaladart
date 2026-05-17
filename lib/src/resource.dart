import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'message.dart';
import 'option.dart';
import 'types.dart';

typedef CoapResourceHandler =
    CoapResourceResponse Function(CoapResourceRequest request);

class CoapResourceRequest {
  const CoapResourceRequest({
    required this.query,
    required this.payload,
    required this.message,
    required this.from,
  });

  final Map<String, List<String>> query;
  final Uint8List? payload;
  final CoapMessage message;
  final Address from;

  String get payloadString => payload == null ? '' : bytesToString(payload!);
}

class CoapResourceResponse {
  const CoapResourceResponse(this.code, [this.payload]);

  factory CoapResourceResponse.string(CoapResponseCode code, String payload) =>
      CoapResourceResponse(code, stringToBytes(payload));

  final CoapResponseCode code;
  final Uint8List? payload;
}

abstract interface class CoapResourceProtocol {
  CoapMethod get method;

  String get path;

  CoapMessage responseForRequest(CoapMessage message, Address fromAddress);
}

class CoapResource implements CoapResourceProtocol {
  CoapResource({
    required this.method,
    required this.path,
    required CoapResourceHandler handler,
  }) : _handler = handler;

  final CoapResourceHandler _handler;
  CoalaResourceOwner? owner;

  @override
  final CoapMethod method;

  @override
  final String path;

  bool matchesPath(String requestPath) =>
      trimSlashes(requestPath) == trimSlashes(path);

  bool matches(CoapMethod requestMethod, String requestPath) =>
      requestMethod == method && matchesPath(requestPath);

  @override
  CoapMessage responseForRequest(CoapMessage message, Address fromAddress) {
    final response = _handler(
      CoapResourceRequest(
        query: _queryMap(message.url),
        payload: message.payload,
        message: message,
        from: fromAddress,
      ),
    );
    final responseMessage = CoapMessage.ackTo(
      request: message,
      from: fromAddress,
      code: response.code,
    )..payload = response.payload;
    return responseMessage;
  }

  static String trimSlashes(String path) =>
      path.replaceAll(RegExp(r'^/+|/+$'), '');

  static Map<String, List<String>> _queryMap(Uri? uri) {
    if (uri == null || uri.query.isEmpty) {
      return const {};
    }
    return uri.queryParametersAll;
  }
}

abstract interface class CoalaResourceOwner {
  Future<void> send(CoapMessage message);
}

class ObservableResource extends CoapResource {
  ObservableResource({required super.path, required super.handler})
    : super(method: CoapMethod.get);

  final Set<CoapObserver> _observers = {};
  int _sequenceNumber = 0;

  int get observersCount => _observers.length;

  int get sequenceNumber => _sequenceNumber;

  void addObserver(CoapObserver observer) => _observers.add(observer);

  void removeObserver(CoapObserver observer) => _observers.remove(observer);

  Future<void> notifyObservers() async {
    _sequenceNumber += 1;
    final response = _handler(
      CoapResourceRequest(
        query: const {},
        payload: null,
        message: CoapMessage(
          type: CoapReliability.nonConfirmable,
          code: const CoapCode.request(CoapMethod.get),
        ),
        from: const Address(host: '0.0.0.0', port: 0),
      ),
    );
    for (final observer in _observers.toList(growable: false)) {
      await _sendNotification(response, observer);
    }
  }

  Future<void> _sendNotification(
    CoapResourceResponse response,
    CoapObserver observer,
  ) async {
    final registerMessage = observer.registerMessage;
    final notification =
        CoapMessage(
            type: CoapReliability.confirmable,
            code: CoapCode.response(response.code),
          )
          ..url = observer.address.uriForScheme(registerMessage.scheme)
          ..payload = response.payload
          ..token = registerMessage.token
          ..setIntegerOption(CoapOptionNumber.observe, _sequenceNumber);
    await owner?.send(notification);
  }
}

class CoapObserver {
  const CoapObserver({required this.address, required this.registerMessage});

  final Address address;
  final CoapMessage registerMessage;

  @override
  bool operator ==(Object other) =>
      other is CoapObserver && other.address == address;

  @override
  int get hashCode => address.hashCode;
}

class CoapDiscoveryResource extends CoapResource {
  CoapDiscoveryResource({required super.path, required super.handler})
    : super(method: CoapMethod.get);

  @override
  CoapMessage responseForRequest(CoapMessage message, Address fromAddress) {
    final response = super.responseForRequest(message, fromAddress);
    response.setIntegerOption(CoapOptionNumber.contentFormat, 40);
    return response;
  }
}
