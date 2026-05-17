import 'types.dart';

class Address {
  const Address({required this.host, required this.port});

  factory Address.parse(String value) {
    final index = value.lastIndexOf(':');
    if (index <= 0 || index == value.length - 1) {
      throw FormatException('Address must be in host:port format.', value);
    }
    final port = int.tryParse(value.substring(index + 1));
    if (port == null || port < 0 || port > 65535) {
      throw FormatException('Invalid address port.', value);
    }
    return Address(host: value.substring(0, index), port: port);
  }

  factory Address.fromUri(Uri uri, {int defaultPort = 5683}) {
    if (uri.host.isEmpty) {
      throw FormatException('URI has no host.', uri.toString());
    }
    final port = uri.hasPort ? uri.port : defaultPort;
    return Address(host: uri.host, port: port);
  }

  final String host;
  final int port;

  Uri uriForScheme(CoapScheme scheme) =>
      Uri(scheme: scheme.text, host: host, port: port);

  @override
  String toString() => '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is Address && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}
