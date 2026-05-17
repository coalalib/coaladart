import 'dart:typed_data';

import 'bytes.dart';

class CoapOptionNumber implements Comparable<CoapOptionNumber> {
  const CoapOptionNumber(this.value, [this.name]);

  static const ifMatch = CoapOptionNumber(1, 'ifMatch');
  static const uriHost = CoapOptionNumber(3, 'uriHost');
  static const eTag = CoapOptionNumber(4, 'eTag');
  static const ifNoneMatch = CoapOptionNumber(5, 'ifNoneMatch');
  static const observe = CoapOptionNumber(6, 'observe');
  static const uriPort = CoapOptionNumber(7, 'uriPort');
  static const locationPath = CoapOptionNumber(8, 'locationPath');
  static const uriPath = CoapOptionNumber(11, 'uriPath');
  static const contentFormat = CoapOptionNumber(12, 'contentFormat');
  static const maxAge = CoapOptionNumber(14, 'maxAge');
  static const uriQuery = CoapOptionNumber(15, 'uriQuery');
  static const accept = CoapOptionNumber(17, 'accept');
  static const locationQuery = CoapOptionNumber(20, 'locationQuery');
  static const block2 = CoapOptionNumber(23, 'block2');
  static const block1 = CoapOptionNumber(27, 'block1');
  static const proxyUri = CoapOptionNumber(35, 'proxyUri');
  static const proxyScheme = CoapOptionNumber(39, 'proxyScheme');
  static const size1 = CoapOptionNumber(60, 'size1');
  static const selectiveRepeatWindowSize = CoapOptionNumber(
    3001,
    'selectiveRepeatWindowSize',
  );
  static const proxySecurityId = CoapOptionNumber(3004, 'proxySecurityId');
  static const uriScheme = CoapOptionNumber(2111, 'uriScheme');
  static const handshakeType = CoapOptionNumber(3999, 'handshakeType');
  static const sessionNotFound = CoapOptionNumber(4001, 'sessionNotFound');
  static const sessionExpired = CoapOptionNumber(4003, 'sessionExpired');
  static const coapsUri = CoapOptionNumber(4005, 'coapsUri');

  static const known = <int, CoapOptionNumber>{
    1: ifMatch,
    3: uriHost,
    4: eTag,
    5: ifNoneMatch,
    6: observe,
    7: uriPort,
    8: locationPath,
    11: uriPath,
    12: contentFormat,
    14: maxAge,
    15: uriQuery,
    17: accept,
    20: locationQuery,
    23: block2,
    27: block1,
    35: proxyUri,
    39: proxyScheme,
    60: size1,
    2111: uriScheme,
    3001: selectiveRepeatWindowSize,
    3004: proxySecurityId,
    3999: handshakeType,
    4001: sessionNotFound,
    4003: sessionExpired,
    4005: coapsUri,
  };

  factory CoapOptionNumber.fromValue(int value) =>
      known[value] ?? CoapOptionNumber(value);

  final int value;
  final String? name;

  bool get repeatable {
    switch (value) {
      case 1:
      case 4:
      case 8:
      case 11:
      case 15:
      case 20:
        return true;
      default:
        return false;
    }
  }

  bool get critical => value.isOdd;

  bool get isBlock => value == block1.value || value == block2.value;

  @override
  int compareTo(CoapOptionNumber other) => value.compareTo(other.value);

  @override
  String toString() => name ?? 'option$value';

  @override
  bool operator ==(Object other) =>
      other is CoapOptionNumber && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

class CoapMessageOption {
  CoapMessageOption(this.number, List<int> value) : value = copyBytes(value);

  factory CoapMessageOption.integer(CoapOptionNumber number, int value) =>
      CoapMessageOption(number, intToMinimalBytes(value));

  factory CoapMessageOption.string(CoapOptionNumber number, String value) =>
      CoapMessageOption(number, stringToBytes(value));

  final CoapOptionNumber number;
  final Uint8List value;

  int get integerValue => bytesToInt(value);

  String get stringValue => bytesToString(value);

  @override
  String toString() {
    final string = stringValue;
    final parts = <String>[number.toString()];
    if (string.isNotEmpty) {
      parts.add('S:$string');
    }
    if (value.isNotEmpty) {
      parts.add('U:$integerValue');
    }
    return parts.join(' ');
  }
}
