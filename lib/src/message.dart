import 'dart:math';
import 'dart:typed_data';

import 'address.dart';
import 'blockwise.dart';
import 'bytes.dart';
import 'option.dart';
import 'token.dart';
import 'types.dart';

typedef CoalaResponseHandler = void Function(CoalaResponse response);

sealed class CoalaResponse {
  const CoalaResponse();
}

class CoalaMessageResponse extends CoalaResponse {
  const CoalaMessageResponse({required this.message, required this.from});

  final CoapMessage message;
  final Address from;
}

class CoalaErrorResponse extends CoalaResponse {
  const CoalaErrorResponse(this.error, [this.stackTrace]);

  final Object error;
  final StackTrace? stackTrace;
}

class CoapMessage {
  CoapMessage({required this.type, required this.code, int? messageId})
    : messageId = messageId ?? randomMessageId();

  CoapMessage.request({
    required this.type,
    required CoapMethod method,
    Uri? url,
    int? messageId,
  }) : code = CoapCode.request(method),
       messageId = messageId ?? randomMessageId() {
    this.url = url;
  }

  CoapMessage.ackTo({
    required CoapMessage request,
    Address? from,
    required CoapResponseCode code,
  }) : type = CoapReliability.acknowledgement,
       code = CoapCode.response(code),
       messageId = request.messageId {
    url = from?.uriForScheme(request.scheme);
    token = request.token;
  }

  CoapMessage.responseTo({
    required this.type,
    required CoapResponseCode code,
    required CoapMessage request,
    required Address from,
    int? messageId,
  }) : code = CoapCode.response(code),
       messageId = messageId ?? randomMessageId() {
    url = from.uriForScheme(request.scheme);
    token = request.token;
  }

  CoapMessage copy() {
    final copied = CoapMessage(type: type, code: code, messageId: messageId)
      ..payload = payload == null ? null : copyBytes(payload!)
      ..token = token == null ? null : CoapToken(token!.value)
      ..address = address
      ..proxyViaAddress = proxyViaAddress
      ..peerPublicKey = peerPublicKey == null ? null : copyBytes(peerPublicKey!)
      ..addChecksumOnSend = addChecksumOnSend
      .._onResponse = _onResponse;
    for (final option in options) {
      copied.options.add(CoapMessageOption(option.number, option.value));
    }
    return copied;
  }

  CoapReliability type;
  CoapCode code;
  final int messageId;
  Uint8List? payload;
  CoapToken? token;
  Address? address;
  Address? proxyViaAddress;
  Uint8List? peerPublicKey;
  bool addChecksumOnSend = false;
  final List<CoapMessageOption> options = [];

  CoalaResponseHandler? _onResponse;

  CoalaResponseHandler? get onResponse => _onResponse;

  set onResponse(CoalaResponseHandler? value) {
    _onResponse = value;
    if (value != null && token == null) {
      token = CoapToken.generate();
    }
  }

  CoapMethod? get requestMethod => code.method;

  CoapResponseCode? get responseCode => code.responseCode;

  bool get isRequest => code.isRequest;

  bool get isResponse => code.isResponse;

  CoapScheme get scheme {
    final rawScheme = getIntegerOptions(CoapOptionNumber.uriScheme).firstOrNull;
    return CoapScheme.fromValue(rawScheme ?? 0) ?? CoapScheme.coap;
  }

  set scheme(CoapScheme value) {
    removeOption(CoapOptionNumber.uriScheme);
    if (value != CoapScheme.coap) {
      setOption(CoapOptionNumber.uriScheme, intToMinimalBytes(value.value));
    }
  }

  Uri? get url {
    final host =
        getStringOptions(CoapOptionNumber.uriHost).firstOrNull ?? address?.host;
    if (host == null || host.isEmpty) {
      return null;
    }
    final port =
        getIntegerOptions(CoapOptionNumber.uriPort).firstOrNull ??
        address?.port ??
        CoalaDefaults.defaultPort;
    final pathSegments = getStringOptions(CoapOptionNumber.uriPath);
    final queryOptions = getStringOptions(CoapOptionNumber.uriQuery);
    return Uri(
      scheme: scheme.text,
      host: host,
      port: port,
      pathSegments: pathSegments,
      query: queryOptions.isEmpty ? null : queryOptions.join('&'),
    );
  }

  set url(Uri? value) {
    removeOption(CoapOptionNumber.uriHost);
    removeOption(CoapOptionNumber.uriPort);
    removeOption(CoapOptionNumber.uriPath);
    removeOption(CoapOptionNumber.uriQuery);

    final parsedScheme = value == null
        ? null
        : CoapScheme.fromString(value.scheme);
    if (parsedScheme != null) {
      scheme = parsedScheme;
    }

    if (value == null) {
      address = null;
      return;
    }

    for (final segment in value.pathSegments.where(
      (segment) => segment.isNotEmpty,
    )) {
      setOption(CoapOptionNumber.uriPath, stringToBytes(segment));
    }
    if (value.query.isNotEmpty) {
      for (final item in value.query.split('&')) {
        if (item.isNotEmpty) {
          setOption(CoapOptionNumber.uriQuery, stringToBytes(item));
        }
      }
    }
    if (value.host.isNotEmpty) {
      address = Address.fromUri(value);
    } else {
      address = null;
    }
  }

  List<CoapMessageOption> getOptions(CoapOptionNumber number) => options
      .where((option) => option.number == number)
      .toList(growable: false);

  List<String> getStringOptions(CoapOptionNumber number) => getOptions(
    number,
  ).map((option) => option.stringValue).toList(growable: false);

  List<int> getIntegerOptions(CoapOptionNumber number) => getOptions(
    number,
  ).map((option) => option.integerValue).toList(growable: false);

  List<Uint8List> getOpaqueOptions(CoapOptionNumber number) =>
      getOptions(number).map((option) => option.value).toList(growable: false);

  void setOption(CoapOptionNumber number, List<int>? value) {
    if (value == null) {
      removeOption(number);
      return;
    }
    if (!number.repeatable) {
      removeOption(number);
    }
    options.add(CoapMessageOption(number, value));
  }

  void setStringOption(CoapOptionNumber number, String value) =>
      setOption(number, stringToBytes(value));

  void setIntegerOption(CoapOptionNumber number, int value) =>
      setOption(number, intToMinimalBytes(value));

  void removeOption(CoapOptionNumber number) {
    options.removeWhere((option) => option.number == number);
  }

  CoapBlockOption? get block1Option {
    final value = getIntegerOptions(CoapOptionNumber.block1).firstOrNull;
    return value == null ? null : CoapBlockOption.fromInteger(value);
  }

  set block1Option(CoapBlockOption? value) {
    setOption(
      CoapOptionNumber.block1,
      value == null ? null : intToMinimalBytes(value.value),
    );
  }

  CoapBlockOption? get block2Option {
    final value = getIntegerOptions(CoapOptionNumber.block2).firstOrNull;
    return value == null ? null : CoapBlockOption.fromInteger(value);
  }

  set block2Option(CoapBlockOption? value) {
    setOption(
      CoapOptionNumber.block2,
      value == null ? null : intToMinimalBytes(value.value),
    );
  }

  bool get isMulticast => address?.host == CoalaDefaults.multicastAddress;

  String get payloadString => payload == null ? '' : bytesToString(payload!);

  set payloadString(String value) {
    payload = stringToBytes(value);
  }

  String get shortDescription {
    final buffer = StringBuffer(
      '${type.toString()} ${code.toString()} [id$messageId]',
    );
    if (scheme == CoapScheme.coapSecure) {
      buffer.write(' secure');
    }
    if (isRequest) {
      final path = '/${getStringOptions(CoapOptionNumber.uriPath).join('/')}';
      buffer.write(' $path');
      final query = url?.query;
      if (query != null && query.isNotEmpty) {
        buffer.write('?$query');
      }
    }
    final block1 = block1Option;
    if (block1 != null) {
      buffer.write(', 1:$block1');
    }
    final block2 = block2Option;
    if (block2 != null) {
      buffer.write(', 2:$block2');
    }
    final data = payload;
    if (data != null) {
      buffer.write(', [${data.length}b]');
    }
    return buffer.toString();
  }

  String get longDescription {
    final buffer = StringBuffer(shortDescription);
    if (token != null) {
      buffer.write(' TOKEN:${token.toString()}');
    }
    final data = payload;
    if (data != null && data.isNotEmpty) {
      final text = bytesToString(data);
      buffer.write(
        text.isEmpty ? ' PAYLOAD of <${data.length}b>' : ' PAYLOAD:$text',
      );
    }
    buffer.write(' OPTIONS:[${options.join(', ')}]');
    return buffer.toString();
  }

  static int randomMessageId() => 1 + Random.secure().nextInt(65535);
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

class CoalaDefaults {
  static const defaultPort = 5683;
  static const multicastAddress = '224.0.0.187';
  static const discoveryPath = 'info';
}
