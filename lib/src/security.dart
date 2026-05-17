import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:pointycastle/export.dart' as pointycastle;

import 'bytes.dart';

class CoapsException implements Exception {
  const CoapsException(this.message);

  final String message;

  @override
  String toString() => 'CoapsException: $message';
}

class CoalaSecurityKeys {
  static final cryptography.X25519 _x25519 = cryptography.X25519();
  static cryptography.SimpleKeyPair? _keyPair;

  static Future<cryptography.SimpleKeyPair> keyPair() async {
    final existing = _keyPair;
    if (existing != null) {
      return existing;
    }
    final generated = await _x25519.newKeyPair();
    _keyPair = generated;
    return generated;
  }

  static Future<Uint8List> publicKeyBytes() async {
    final publicKey = await (await keyPair()).extractPublicKey();
    return copyBytes(publicKey.bytes);
  }

  static Future<void> setPrivateKeySeed(List<int> seed) async {
    if (seed.length != 32) {
      throw ArgumentError.value(
        seed.length,
        'seed.length',
        'X25519 seed must be 32 bytes.',
      );
    }
    _keyPair = await _x25519.newKeyPairFromSeed(seed);
  }

  static Future<cryptography.SecretKey> sharedSecret(
    List<int> peerPublicKey,
  ) async {
    if (peerPublicKey.length != 32) {
      throw ArgumentError.value(
        peerPublicKey.length,
        'peerPublicKey.length',
        'X25519 public key must be 32 bytes.',
      );
    }
    return _x25519.sharedSecretKey(
      keyPair: await keyPair(),
      remotePublicKey: cryptography.SimplePublicKey(
        peerPublicKey,
        type: cryptography.KeyPairType.x25519,
      ),
    );
  }
}

class SecuredSession {
  SecuredSession({required this.incoming});

  final bool incoming;
  CoalaAead? aead;
  Uint8List? peerPublicKey;

  Future<Uint8List> get publicKey => CoalaSecurityKeys.publicKeyBytes();

  Future<void> start(List<int> peerPublicKey) async {
    this.peerPublicKey = copyBytes(peerPublicKey);
    final sharedSecret = await CoalaSecurityKeys.sharedSecret(peerPublicKey);
    final hkdf = cryptography.Hkdf(
      hmac: cryptography.Hmac.sha256(),
      outputLength: 40,
    );
    final output = await hkdf.deriveKey(secretKey: sharedSecret);
    final keyMaterial = await output.extractBytes();
    final firstKey = keyMaterial.sublist(0, 16);
    final secondKey = keyMaterial.sublist(16, 32);
    final firstIv = keyMaterial.sublist(32, 36);
    final secondIv = keyMaterial.sublist(36, 40);
    aead = incoming
        ? CoalaAead(
            peerKey: secondKey,
            myKey: firstKey,
            peerIv: secondIv,
            myIv: firstIv,
          )
        : CoalaAead(
            peerKey: firstKey,
            myKey: secondKey,
            peerIv: firstIv,
            myIv: secondIv,
          );
  }
}

class CoalaAead {
  CoalaAead({
    required List<int> peerKey,
    required List<int> myKey,
    required List<int> peerIv,
    required List<int> myIv,
  }) : peerKey = copyBytes(peerKey),
       myKey = copyBytes(myKey),
       peerIv = copyBytes(peerIv),
       myIv = copyBytes(myIv);

  static const tagLength = 12;

  final Uint8List peerKey;
  final Uint8List myKey;
  final Uint8List peerIv;
  final Uint8List myIv;

  Uint8List seal(
    List<int> plainText, {
    required int counter,
    List<int> aad = const [],
  }) => _AesGcm12.encrypt(
    key: myKey,
    nonce: makeNonce(myIv, counter),
    plainText: plainText,
    aad: aad,
  );

  Uint8List open(
    List<int> cipherText, {
    required int counter,
    List<int> aad = const [],
  }) => _AesGcm12.decrypt(
    key: peerKey,
    nonce: makeNonce(peerIv, counter),
    cipherText: cipherText,
    aad: aad,
  );

  static Uint8List makeNonce(List<int> iv, int counter) {
    if (iv.length != 4) {
      throw ArgumentError.value(
        iv.length,
        'iv.length',
        'Coala IV must be 4 bytes.',
      );
    }
    return bytes([
      ...iv,
      counter & 0xff,
      (counter >> 8) & 0xff,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
  }
}

class _AesGcm12 {
  static final BigInt _r = BigInt.parse(
    'e1000000000000000000000000000000',
    radix: 16,
  );
  static final BigInt _mask128 = (BigInt.one << 128) - BigInt.one;

  static Uint8List encrypt({
    required List<int> key,
    required List<int> nonce,
    required List<int> plainText,
    List<int> aad = const [],
  }) {
    final cipherText = _ctrCrypt(key, nonce, plainText);
    final tag = _tag(
      key,
      nonce,
      aad,
      cipherText,
    ).sublist(0, CoalaAead.tagLength);
    return bytes([...cipherText, ...tag]);
  }

  static Uint8List decrypt({
    required List<int> key,
    required List<int> nonce,
    required List<int> cipherText,
    List<int> aad = const [],
  }) {
    if (cipherText.length < CoalaAead.tagLength) {
      throw const CoapsException('Cipher text is shorter than the GCM tag.');
    }
    final tagOffset = cipherText.length - CoalaAead.tagLength;
    final encrypted = cipherText.sublist(0, tagOffset);
    final tag = cipherText.sublist(tagOffset);
    final expected = _tag(
      key,
      nonce,
      aad,
      encrypted,
    ).sublist(0, CoalaAead.tagLength);
    if (!listEquals(tag, expected)) {
      throw const CoapsException(
        'AES-GCM authentication tag validation failed.',
      );
    }
    return _ctrCrypt(key, nonce, encrypted);
  }

  static Uint8List _ctrCrypt(List<int> key, List<int> nonce, List<int> input) {
    final result = Uint8List(input.length);
    var counter = _j0(nonce);
    var offset = 0;
    while (offset < input.length) {
      counter = _increment32(counter);
      final stream = _aesBlock(key, counter);
      final count = input.length - offset < 16 ? input.length - offset : 16;
      for (var i = 0; i < count; i += 1) {
        result[offset + i] = input[offset + i] ^ stream[i];
      }
      offset += count;
    }
    return result;
  }

  static Uint8List _tag(
    List<int> key,
    List<int> nonce,
    List<int> aad,
    List<int> cipherText,
  ) {
    final h = _aesBlock(key, Uint8List(16));
    final s = _ghash(h, aad, cipherText);
    return _xor16(_aesBlock(key, _j0(nonce)), s);
  }

  static Uint8List _j0(List<int> nonce) {
    if (nonce.length == 12) {
      return bytes([...nonce, 0, 0, 0, 1]);
    }
    final h = Uint8List(16);
    return _ghash(h, const [], nonce);
  }

  static Uint8List _ghash(List<int> h, List<int> aad, List<int> cipherText) {
    var y = BigInt.zero;
    final hValue = _bytesToBigInt(h);
    for (final block in _blocks(aad)) {
      y = _multiply(y ^ _bytesToBigInt(block), hValue);
    }
    for (final block in _blocks(cipherText)) {
      y = _multiply(y ^ _bytesToBigInt(block), hValue);
    }
    final lengthBlock = Uint8List(16);
    _writeUint64(lengthBlock, 0, aad.length * 8);
    _writeUint64(lengthBlock, 8, cipherText.length * 8);
    y = _multiply(y ^ _bytesToBigInt(lengthBlock), hValue);
    return _bigIntTo16(y);
  }

  static Iterable<Uint8List> _blocks(List<int> data) sync* {
    for (var offset = 0; offset < data.length; offset += 16) {
      final block = Uint8List(16);
      final end = offset + 16 < data.length ? offset + 16 : data.length;
      block.setRange(0, end - offset, data, offset);
      yield block;
    }
  }

  static BigInt _multiply(BigInt x, BigInt y) {
    var z = BigInt.zero;
    var v = y;
    for (var i = 0; i < 128; i += 1) {
      if (((x >> (127 - i)) & BigInt.one) == BigInt.one) {
        z ^= v;
      }
      if ((v & BigInt.one) == BigInt.zero) {
        v >>= 1;
      } else {
        v = (v >> 1) ^ _r;
      }
    }
    return z & _mask128;
  }

  static Uint8List _aesBlock(List<int> key, List<int> input) {
    if (key.length != 16) {
      throw ArgumentError.value(
        key.length,
        'key.length',
        'AES-128 key must be 16 bytes.',
      );
    }
    if (input.length != 16) {
      throw ArgumentError.value(
        input.length,
        'input.length',
        'AES block must be 16 bytes.',
      );
    }
    final cipher = pointycastle.AESEngine()
      ..init(true, pointycastle.KeyParameter(copyBytes(key)));
    final out = Uint8List(16);
    cipher.processBlock(copyBytes(input), 0, out, 0);
    return out;
  }

  static Uint8List _increment32(List<int> block) {
    final next = copyBytes(block);
    var value =
        ((next[12] & 0xff) << 24) |
        ((next[13] & 0xff) << 16) |
        ((next[14] & 0xff) << 8) |
        (next[15] & 0xff);
    value = (value + 1) & 0xffffffff;
    next[12] = (value >> 24) & 0xff;
    next[13] = (value >> 16) & 0xff;
    next[14] = (value >> 8) & 0xff;
    next[15] = value & 0xff;
    return next;
  }

  static Uint8List _xor16(List<int> left, List<int> right) =>
      bytes(List<int>.generate(16, (i) => left[i] ^ right[i]));

  static BigInt _bytesToBigInt(List<int> input) {
    var result = BigInt.zero;
    for (final byte in input) {
      result = (result << 8) | BigInt.from(byte & 0xff);
    }
    return result;
  }

  static Uint8List _bigIntTo16(BigInt input) {
    final result = Uint8List(16);
    var value = input;
    for (var i = 15; i >= 0; i -= 1) {
      result[i] = (value & BigInt.from(0xff)).toInt();
      value >>= 8;
    }
    return result;
  }

  static void _writeUint64(Uint8List out, int offset, int value) {
    final high = value ~/ 0x100000000;
    final low = value & 0xffffffff;
    out[offset] = (high >> 24) & 0xff;
    out[offset + 1] = (high >> 16) & 0xff;
    out[offset + 2] = (high >> 8) & 0xff;
    out[offset + 3] = high & 0xff;
    out[offset + 4] = (low >> 24) & 0xff;
    out[offset + 5] = (low >> 16) & 0xff;
    out[offset + 6] = (low >> 8) & 0xff;
    out[offset + 7] = low & 0xff;
  }
}
