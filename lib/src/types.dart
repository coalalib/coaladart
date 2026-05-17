import 'registry_code.dart';

enum CoapReliability {
  confirmable(0, 'CON'),
  nonConfirmable(1, 'NON'),
  acknowledgement(2, 'ACK'),
  reset(3, 'RST');

  const CoapReliability(this.value, this.label);

  final int value;
  final String label;

  static CoapReliability? fromValue(int value) {
    for (final item in values) {
      if (item.value == value) {
        return item;
      }
    }
    return null;
  }

  @override
  String toString() => label;
}

enum CoapMethod {
  get(1, 'GET'),
  post(2, 'POST'),
  put(3, 'PUT'),
  delete(4, 'DELETE');

  const CoapMethod(this.value, this.label);

  final int value;
  final String label;

  CoapRegistryCode get registryCode => CoapRegistryCode.fromInt(value);

  static CoapMethod? fromValue(int value) {
    for (final item in values) {
      if (item.value == value) {
        return item;
      }
    }
    return null;
  }

  @override
  String toString() => label;
}

enum CoapResponseCode {
  empty(0, 'Empty'),
  created(65, 'Created'),
  deleted(66, 'Deleted'),
  valid(67, 'Valid'),
  changed(68, 'Changed'),
  content(69, 'Content'),
  continued(95, 'Continue'),
  badRequest(128, 'Bad Request'),
  unauthorized(129, 'Unauthorized'),
  badOption(130, 'Bad Option'),
  forbidden(131, 'Forbidden'),
  notFound(132, 'Not Found'),
  methodNotAllowed(133, 'Method Not Allowed'),
  notAcceptable(134, 'Not Acceptable'),
  requestEntityIncomplete(136, 'Request Entity Incomplete'),
  preconditionFailed(140, 'Precondition Failed'),
  requestEntityTooLarge(141, 'Request Entity Too Large'),
  unsupportedContentFormat(143, 'Unsupported Content Format'),
  internalServerError(160, 'Internal Server Error'),
  notImplemented(161, 'Not Implemented'),
  badGateway(162, 'Bad Gateway'),
  serviceUnavailable(163, 'Service Unavailable'),
  gatewayTimeout(164, 'Gateway Timeout'),
  proxyingNotSupported(165, 'Proxying Not Supported');

  const CoapResponseCode(this.value, this.label);

  final int value;
  final String label;

  CoapRegistryCode get registryCode => CoapRegistryCode.fromInt(value);

  bool get isError => registryCode.isError;

  static CoapResponseCode? fromValue(int value) {
    for (final item in values) {
      if (item.value == value) {
        return item;
      }
    }
    return null;
  }

  @override
  String toString() => '${registryCode.toString()} $label';
}

enum CoapScheme {
  coap(0, 'coap'),
  coapSecure(1, 'coaps');

  const CoapScheme(this.value, this.text);

  final int value;
  final String text;

  static CoapScheme? fromValue(int value) {
    for (final item in values) {
      if (item.value == value) {
        return item;
      }
    }
    return null;
  }

  static CoapScheme? fromString(String value) {
    for (final item in values) {
      if (item.text == value) {
        return item;
      }
    }
    return null;
  }
}

class CoapCode {
  const CoapCode._({this.method, this.responseCode});

  const CoapCode.request(CoapMethod method)
    : this._(method: method, responseCode: null);

  const CoapCode.response(CoapResponseCode responseCode)
    : this._(method: null, responseCode: responseCode);

  factory CoapCode.fromValue(int value) {
    final method = CoapMethod.fromValue(value);
    if (method != null) {
      return CoapCode.request(method);
    }
    final response = CoapResponseCode.fromValue(value);
    if (response != null) {
      return CoapCode.response(response);
    }
    throw ArgumentError.value(value, 'value', 'Unknown CoAP code.');
  }

  final CoapMethod? method;
  final CoapResponseCode? responseCode;

  bool get isRequest => method != null;

  bool get isResponse =>
      responseCode != null && responseCode != CoapResponseCode.empty;

  int get value => method?.value ?? responseCode!.value;

  @override
  String toString() {
    if (method != null) {
      return method.toString();
    }
    return responseCode.toString();
  }

  @override
  bool operator ==(Object other) => other is CoapCode && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
