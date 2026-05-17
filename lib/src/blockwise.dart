import 'option.dart';

enum CoapBlockSize {
  size16(0, 16),
  size32(1, 32),
  size64(2, 64),
  size128(3, 128),
  size256(4, 256),
  size512(5, 512),
  size1024(6, 1024);

  const CoapBlockSize(this.value, this.bytes);

  final int value;
  final int bytes;

  static CoapBlockSize? fromValue(int value) {
    for (final item in values) {
      if (item.value == value) {
        return item;
      }
    }
    return null;
  }
}

class CoapBlockOption {
  const CoapBlockOption({
    required this.num,
    required this.more,
    required this.size,
  });

  factory CoapBlockOption.fromInteger(int value) {
    final blockSize = CoapBlockSize.fromValue(value & 0x07);
    if (blockSize == null) {
      throw FormatException('Invalid CoAP block option SZX.', value);
    }
    return CoapBlockOption(
      num: value >> 4,
      more: ((value >> 3) & 1) == 1,
      size: blockSize,
    );
  }

  final int num;
  final bool more;
  final CoapBlockSize size;

  int get value => (num << 4) | ((more ? 1 : 0) << 3) | size.value;

  CoapMessageOption toOption(CoapOptionNumber number) =>
      CoapMessageOption.integer(number, value);

  @override
  String toString() => '$num/${more ? 1 : 0}/${size.bytes}';
}

class SlidingWindow<T> {
  SlidingWindow({required this.size, this.offset = 0})
    : values = List<T?>.filled(size, null, growable: true);

  final int size;
  int offset;
  final List<T?> values;

  int get tail => offset + size - 1;

  void setValue(T value, int index) {
    final windowIndex = index - offset;
    if (windowIndex < 0) {
      return;
    }
    if (windowIndex >= size) {
      throw RangeError.index(index, values, 'index');
    }
    values[windowIndex] = value;
  }

  T? advance() {
    final first = values.first;
    if (first == null) {
      return null;
    }
    values
      ..removeAt(0)
      ..add(null);
    offset += 1;
    return first;
  }

  T? getValueAtWindowIndex(int index) => values[index];
}

class SrTxBlock {
  const SrTxBlock({
    required this.number,
    required this.data,
    required this.more,
  });

  final int number;
  final List<int> data;
  final bool more;
}

class SrTxState {
  SrTxState({
    required this.data,
    required int windowSize,
    required this.blockSize,
  }) {
    final totalBlocks =
        data.length ~/ blockSize + (data.length % blockSize == 0 ? 0 : 1);
    final effectiveWindowSize = windowSize < totalBlocks
        ? windowSize
        : totalBlocks;
    window = SlidingWindow<bool>(
      size: effectiveWindowSize,
      offset: -effectiveWindowSize,
    );
    if (effectiveWindowSize > 0) {
      for (var index = -effectiveWindowSize; index <= -1; index += 1) {
        window.setValue(true, index);
      }
    }
  }

  final List<int> data;
  final int blockSize;
  late final SlidingWindow<bool> window;

  int get windowSize => window.size;

  bool get isCompleted {
    var lastDeliveredBlock = window.offset;
    var index = 0;
    while (index < window.size && window.getValueAtWindowIndex(index) == true) {
      lastDeliveredBlock += 1;
      index += 1;
    }
    return lastDeliveredBlock * blockSize >= data.length;
  }

  void didTransmit(int blockNumber) {
    window.setValue(true, blockNumber);
  }

  SrTxBlock? popBlock() {
    if (window.advance() == null) {
      return null;
    }
    final blockNumber = window.tail;
    final rangeStart = blockNumber * blockSize;
    final rangeEnd = rangeStart + blockSize < data.length
        ? rangeStart + blockSize
        : data.length;
    if (rangeStart >= rangeEnd) {
      return null;
    }
    return SrTxBlock(
      number: blockNumber,
      data: data.sublist(rangeStart, rangeEnd),
      more: rangeEnd != data.length,
    );
  }
}

class SrRxState {
  final Map<int, List<int>> _receivedData = {};
  int? _finalBlockNumber;
  final List<int> accumulator = [];
  List<int>? data;

  void didReceive({
    required List<int> block,
    required int number,
    required bool isFinalBlock,
  }) {
    accumulator.addAll(block);
    _receivedData[number] = block;
    if (isFinalBlock) {
      _finalBlockNumber = number;
    }
    final finalBlockNumber = _finalBlockNumber;
    if (finalBlockNumber != null &&
        finalBlockNumber == _receivedData.length - 1) {
      data = [
        for (var i = 0; i <= finalBlockNumber; i += 1) ...?_receivedData[i],
      ];
    }
  }
}
