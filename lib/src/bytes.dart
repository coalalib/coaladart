import 'dart:convert';
import 'dart:typed_data';

Uint8List bytes(Iterable<int> values) =>
    Uint8List.fromList(List<int>.from(values));

Uint8List copyBytes(List<int> values) => Uint8List.fromList(values);

Uint8List intToMinimalBytes(int value) {
  if (value < 0) {
    throw ArgumentError.value(value, 'value', 'Must be non-negative.');
  }
  if (value == 0) {
    return Uint8List(0);
  }
  final result = <int>[];
  var remaining = value;
  while (remaining > 0) {
    result.insert(0, remaining & 0xff);
    remaining >>= 8;
  }
  return Uint8List.fromList(result);
}

int bytesToInt(List<int> data) {
  var value = 0;
  for (final byte in data) {
    value = (value << 8) | (byte & 0xff);
  }
  return value;
}

Uint8List stringToBytes(String value) => Uint8List.fromList(utf8.encode(value));

String bytesToString(List<int> data) => utf8.decode(data, allowMalformed: true);

String hex(List<int> data) =>
    data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

bool listEquals(List<int> left, List<int> right) {
  if (identical(left, right)) {
    return true;
  }
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i += 1) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

int listHash(List<int> data) {
  var hash = 0;
  for (final byte in data) {
    hash = 0x1fffffff & (hash + byte);
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    hash ^= hash >> 6;
  }
  hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
  hash ^= hash >> 11;
  return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
}
