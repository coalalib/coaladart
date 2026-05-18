import 'dart:typed_data';

import 'bytes.dart';
import 'message.dart';
import 'option.dart';
import 'token.dart';
import 'types.dart';

class CoapSerializationException implements Exception {
  const CoapSerializationException(this.message);

  final String message;

  @override
  String toString() => 'CoapSerializationException: $message';
}

class CoapDeserializationException implements Exception {
  const CoapDeserializationException(this.message);

  final String message;

  @override
  String toString() => 'CoapDeserializationException: $message';
}

class CoapSerializer {
  static const version = 1;

  static Uint8List encode(
    CoapMessage message, {
    bool addChecksumIfNeeded = false,
  }) {
    if (addChecksumIfNeeded && message.addChecksumOnSend) {
      message = message.copy()
        ..setStringOption(
          CoapOptionNumber.checksum,
          checksumForMessage(message),
        );
    }

    final token = message.token;
    final tokenLength = token?.length ?? 0;
    if (tokenLength > CoapToken.maxLength) {
      throw const CoapSerializationException(
        'Token length must be <= 8 bytes.',
      );
    }

    final out = BytesBuilder(copy: false);
    out.add([
      (version << 6) | (message.type.value << 4) | tokenLength,
      message.code.value,
      (message.messageId >> 8) & 0xff,
      message.messageId & 0xff,
    ]);
    if (token != null) {
      out.add(token.value);
    }

    final sortedOptions = message.options.toList(growable: false)
      ..sort((left, right) => left.number.value.compareTo(right.number.value));

    var previousNumber = 0;
    for (final option in sortedOptions) {
      if (option.value.length > 0xffff) {
        throw const CoapSerializationException('Option value is too long.');
      }
      final delta = option.number.value - previousNumber;
      if (delta < 0) {
        throw const CoapSerializationException(
          'Options must be sorted by number.',
        );
      }
      previousNumber = option.number.value;
      final deltaField = _optionField(delta);
      final lengthField = _optionField(option.value.length);
      out.add([(deltaField.halfByte << 4) | lengthField.halfByte]);
      out.add(deltaField.extendedData);
      out.add(lengthField.extendedData);
      out.add(option.value);
    }

    final payload = message.payload;
    if (payload != null && payload.isNotEmpty) {
      out.add([0xff]);
      out.add(payload);
    }

    return out.toBytes();
  }

  static CoapMessage decode(List<int> data) {
    if (data.length < 4) {
      throw const CoapDeserializationException('CoAP header is too short.');
    }
    var pos = 0;
    final first = data[pos++];
    final decodedVersion = first >> 6;
    if (decodedVersion != version) {
      throw CoapDeserializationException(
        'Unsupported CoAP version $decodedVersion.',
      );
    }
    final type = CoapReliability.fromValue((first >> 4) & 0x03);
    if (type == null) {
      throw const CoapDeserializationException('Unknown CoAP message type.');
    }
    final tokenLength = first & 0x0f;
    if (tokenLength > CoapToken.maxLength) {
      throw const CoapDeserializationException('Invalid token length.');
    }
    final code = CoapCode.fromValue(data[pos++]);
    final messageId = ((data[pos++] & 0xff) << 8) | (data[pos++] & 0xff);
    if (pos + tokenLength > data.length) {
      throw const CoapDeserializationException(
        'Token exceeds datagram length.',
      );
    }

    final message = CoapMessage(type: type, code: code, messageId: messageId);
    if (tokenLength > 0) {
      message.token = CoapToken(data.sublist(pos, pos + tokenLength));
      pos += tokenLength;
    }

    var previousNumber = 0;
    while (pos < data.length) {
      final firstByte = data[pos++];
      if (firstByte == 0xff) {
        if (pos == data.length) {
          throw const CoapDeserializationException(
            'Payload marker without payload.',
          );
        }
        message.payload = copyBytes(data.sublist(pos));
        break;
      }

      final delta = _readOptionField(
        firstByte >> 4,
        data,
        () => pos,
        (value) => pos = value,
      );
      final length = _readOptionField(
        firstByte & 0x0f,
        data,
        () => pos,
        (value) => pos = value,
      );
      final number = previousNumber + delta;
      if (pos + length > data.length) {
        throw const CoapDeserializationException(
          'Option value exceeds datagram length.',
        );
      }
      message.setOption(
        CoapOptionNumber.fromValue(number),
        data.sublist(pos, pos + length),
      );
      pos += length;
      previousNumber = number;
    }
    _verifyChecksum(message);
    return message;
  }

  static String checksumForMessage(CoapMessage message) {
    final checksumMessage = message.copy()
      ..removeOption(CoapOptionNumber.checksum);
    return _crc32Hex(encode(checksumMessage));
  }

  static void _verifyChecksum(CoapMessage message) {
    final expected = message
        .getStringOptions(CoapOptionNumber.checksum)
        .firstOrNull;
    if (expected == null) {
      return;
    }
    final computed = checksumForMessage(message);
    if (expected.toLowerCase() != computed) {
      throw CoapDeserializationException(
        'Checksum mismatch: expected $expected got $computed.',
      );
    }
  }

  static String _crc32Hex(List<int> data) =>
      _crc32(data).toRadixString(16).padLeft(8, '0');

  static int _crc32(List<int> data) {
    var crc = 0xffffffff;
    for (final byte in data) {
      crc = (crc ^ (byte & 0xff)) & 0xffffffff;
      for (var i = 0; i < 8; i += 1) {
        if ((crc & 1) == 1) {
          crc = ((crc >> 1) ^ 0xedb88320) & 0xffffffff;
        } else {
          crc = (crc >> 1) & 0xffffffff;
        }
      }
    }
    return (~crc) & 0xffffffff;
  }

  static _OptionField _optionField(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'Must be non-negative.');
    }
    if (value <= 12) {
      return _OptionField(value, const []);
    }
    if (value <= 269) {
      return _OptionField(13, [value - 13]);
    }
    if (value <= 0xffff) {
      final shifted = value - 269;
      return _OptionField(14, [(shifted >> 8) & 0xff, shifted & 0xff]);
    }
    throw ArgumentError.value(value, 'value', 'Option field is too large.');
  }

  static int _readOptionField(
    int halfByte,
    List<int> data,
    int Function() getPos,
    void Function(int) setPos,
  ) {
    var pos = getPos();
    switch (halfByte) {
      case >= 0 && <= 12:
        return halfByte;
      case 13:
        if (pos >= data.length) {
          throw const CoapDeserializationException(
            'Missing extended option field.',
          );
        }
        setPos(pos + 1);
        return data[pos] + 13;
      case 14:
        if (pos + 1 >= data.length) {
          throw const CoapDeserializationException(
            'Missing extended option field.',
          );
        }
        final value = ((data[pos] & 0xff) << 8) | (data[pos + 1] & 0xff);
        setPos(pos + 2);
        return value + 269;
      default:
        throw const CoapDeserializationException(
          'Invalid option field marker.',
        );
    }
  }
}

class _OptionField {
  const _OptionField(this.halfByte, this.extendedData);

  final int halfByte;
  final List<int> extendedData;
}
