import 'package:coala/coala.dart';
import 'package:test/test.dart';

void main() {
  test('Coala AEAD matches a standard AES-GCM vector with truncated tag', () {
    final aead = CoalaAead(
      peerKey: List<int>.filled(16, 0),
      myKey: List<int>.filled(16, 0),
      peerIv: [0, 0, 0, 0],
      myIv: [0, 0, 0, 0],
    );

    final sealed = aead.seal(List<int>.filled(16, 0), counter: 0);

    expect(sealed, [
      0x03,
      0x88,
      0xda,
      0xce,
      0x60,
      0xb6,
      0xa3,
      0x92,
      0xf3,
      0x28,
      0xc2,
      0xb9,
      0x71,
      0xb2,
      0xfe,
      0x78,
      0xab,
      0x6e,
      0x47,
      0xd4,
      0x2c,
      0xec,
      0x13,
      0xbd,
      0xf5,
      0x3a,
      0x67,
      0xb2,
    ]);
  });

  test('Coala AEAD uses 12-byte tags and validates them', () {
    final aead = CoalaAead(
      peerKey: List<int>.filled(16, 1),
      myKey: List<int>.filled(16, 2),
      peerIv: [3, 4, 5, 6],
      myIv: [7, 8, 9, 10],
    );
    final peer = CoalaAead(
      peerKey: List<int>.filled(16, 2),
      myKey: List<int>.filled(16, 1),
      peerIv: [7, 8, 9, 10],
      myIv: [3, 4, 5, 6],
    );

    final sealed = aead.seal([1, 2, 3, 4], counter: 42);

    expect(sealed, hasLength(4 + CoalaAead.tagLength));
    expect(peer.open(sealed, counter: 42), [1, 2, 3, 4]);

    sealed[0] ^= 0xff;
    expect(
      () => peer.open(sealed, counter: 42),
      throwsA(isA<CoapsException>()),
    );
  });
}
