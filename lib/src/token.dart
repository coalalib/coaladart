import 'dart:math';
import 'dart:typed_data';

import 'bytes.dart';

class CoapToken {
  CoapToken(List<int> value)
    : value = copyBytes(value),
      assert(value.length <= maxLength);

  factory CoapToken.generate({int length = 4}) {
    if (length < 1 || length > maxLength) {
      throw RangeError.range(length, 1, maxLength, 'length');
    }
    final random = Random.secure();
    return CoapToken(List<int>.generate(length, (_) => random.nextInt(256)));
  }

  static const maxLength = 8;

  final Uint8List value;

  int get length => value.length;

  @override
  String toString() => hex(value);

  @override
  bool operator ==(Object other) =>
      other is CoapToken && listEquals(other.value, value);

  @override
  int get hashCode => listHash(value);
}
