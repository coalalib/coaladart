class CoapRegistryCode {
  const CoapRegistryCode(this.major, this.minor)
    : assert(major >= 0 && major <= 7),
      assert(minor >= 0 && minor <= 31);

  factory CoapRegistryCode.fromInt(int value) {
    if (value < 0 || value > 255) {
      throw ArgumentError.value(value, 'value', 'Must fit into one byte.');
    }
    return CoapRegistryCode(value >> 5, value & 0x1f);
  }

  factory CoapRegistryCode.fromParts(int major, int minor) =>
      CoapRegistryCode(major, minor);

  factory CoapRegistryCode.fromDouble(double value) {
    final triple = (value * 100).round();
    return CoapRegistryCode(triple ~/ 100, triple % 100);
  }

  final int major;
  final int minor;

  int get intValue => ((major & 0x07) << 5) | (minor & 0x1f);

  bool get isError => major >= 4;

  @override
  String toString() => '$major.${minor.toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) =>
      other is CoapRegistryCode && other.major == major && other.minor == minor;

  @override
  int get hashCode => Object.hash(major, minor);
}
