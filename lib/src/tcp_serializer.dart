import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';

class CoapTcpFrame {
  const CoapTcpFrame({required this.address, required this.data});

  final Address address;
  final Uint8List data;
}

class CoapTcpSerializer {
  final List<int> _buffer = [];

  static const _delimiter = 77;

  Uint8List encode({required Address address, required List<int> data}) {
    final ip = address.host.split('.').map(int.parse).toList(growable: false);
    if (ip.length != 4 || ip.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError.value(
        address.host,
        'address.host',
        'Only IPv4 addresses are supported.',
      );
    }
    if (data.length > 0xffff) {
      throw ArgumentError.value(
        data.length,
        'data.length',
        'TCP frame payload is too large.',
      );
    }
    return bytes([
      _delimiter,
      ...ip,
      (address.port >> 8) & 0xff,
      address.port & 0xff,
      (data.length >> 8) & 0xff,
      data.length & 0xff,
      ...data,
    ]);
  }

  List<CoapTcpFrame> decode(List<int> data) {
    _buffer.addAll(data);
    final frames = <CoapTcpFrame>[];
    var pos = 0;
    while (_buffer.length - pos >= 9 && _buffer[pos] == _delimiter) {
      final ip = _buffer.sublist(pos + 1, pos + 5);
      final port = ((_buffer[pos + 5] & 0xff) << 8) | (_buffer[pos + 6] & 0xff);
      final size = ((_buffer[pos + 7] & 0xff) << 8) | (_buffer[pos + 8] & 0xff);
      if (_buffer.length - pos - 9 < size) {
        break;
      }
      final payloadStart = pos + 9;
      final payloadEnd = payloadStart + size;
      frames.add(
        CoapTcpFrame(
          address: Address(host: ip.join('.'), port: port),
          data: copyBytes(_buffer.sublist(payloadStart, payloadEnd)),
        ),
      );
      pos = payloadEnd;
    }
    if (pos > 0) {
      _buffer.removeRange(0, pos);
    } else if (_buffer.isNotEmpty && _buffer.first != _delimiter) {
      _buffer.clear();
    }
    return frames;
  }

  void flushBuffer() => _buffer.clear();
}
