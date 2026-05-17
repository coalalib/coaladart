import 'dart:async';

import 'address.dart';
import 'message.dart';
import 'token.dart';
import 'types.dart';

class CoapMessagePoolException implements Exception {
  const CoapMessagePoolException(this.message);

  final String message;

  @override
  String toString() => 'CoapMessagePoolException: $message';
}

class UriPathConfig {
  const UriPathConfig({required this.path, required this.timeout});

  final String path;
  final Duration timeout;
}

class DeliveryStatistics {
  const DeliveryStatistics({
    required this.scheme,
    required this.address,
    required this.direct,
    required this.proxy,
  });

  final CoapScheme scheme;
  final Address address;
  final DeliveryCounters direct;
  final DeliveryCounters proxy;

  DeliveryStatistics copyWith({
    DeliveryCounters? direct,
    DeliveryCounters? proxy,
  }) => DeliveryStatistics(
    scheme: scheme,
    address: address,
    direct: direct ?? this.direct,
    proxy: proxy ?? this.proxy,
  );
}

class DeliveryCounters {
  const DeliveryCounters({
    required this.totalCount,
    required this.retransmitsCount,
  });

  final int totalCount;
  final int retransmitsCount;

  DeliveryCounters increment({required bool retransmit}) => DeliveryCounters(
    totalCount: totalCount + 1,
    retransmitsCount: retransmitsCount + (retransmit ? 1 : 0),
  );
}

typedef MessageResender = Future<void> Function(CoapMessage message);

class CoapMessagePool {
  CoapMessagePool({required MessageResender resend}) : _resend = resend;

  final MessageResender _resend;
  final Map<int, _PoolElement> _elements = {};
  final Map<CoapToken, int> _messageIdForToken = {};
  final Map<_DeliveryStatisticsKey, DeliveryStatistics> _statistics = {};
  Timer? _timer;

  Duration resendInterval = const Duration(milliseconds: 750);
  int maxAttempts = 6;
  List<UriPathConfig> longRunningUriPaths = const [];

  void start() {
    stop();
    _timer = Timer.periodic(
      Duration(
        milliseconds: (resendInterval.inMilliseconds / 3).round().clamp(
          1,
          1 << 31,
        ),
      ),
      (_) => tick(),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void push(CoapMessage message) {
    if (message.type == CoapReliability.acknowledgement) {
      return;
    }
    final token = message.token;
    if (token != null) {
      _messageIdForToken[token] = message.messageId;
    }
    _trackStatistics(message);
    final existing = _elements[message.messageId];
    if (existing != null) {
      existing.timesSent += 1;
      existing.lastSend = DateTime.now();
      return;
    }
    _elements[message.messageId] = _PoolElement(message);
  }

  void didTransmitMessage(int messageId) {
    _elements[messageId]?.didTransmit = true;
  }

  CoapMessage? getSourceMessageFor(CoapMessage message) =>
      getByToken(message.token) ?? getByMessageId(message.messageId);

  CoapMessage? getByToken(CoapToken? token) {
    if (token == null) {
      return null;
    }
    final messageId = _messageIdForToken[token];
    return messageId == null ? null : getByMessageId(messageId);
  }

  CoapMessage? getByMessageId(int messageId) => _elements[messageId]?.message;

  int? timesSent(int messageId) => _elements[messageId]?.timesSent;

  void removeByMessageId(int messageId) {
    _messageIdForToken.removeWhere((_, value) => value == messageId);
    _elements.remove(messageId);
  }

  void remove(CoapMessage message) {
    final token = message.token;
    if (token != null) {
      final messageId = _messageIdForToken.remove(token);
      if (messageId != null) {
        _elements.remove(messageId);
      }
    }
    _elements.remove(message.messageId);
  }

  void removeAll() {
    _messageIdForToken.clear();
    _elements.clear();
  }

  void flushPoolMetrics(CoapMessage message) {
    final element = _elements[message.messageId];
    if (element == null) {
      return;
    }
    element
      ..timesSent = 0
      ..lastSend = DateTime.now();
  }

  DeliveryStatistics? getStatistics(Address address, CoapScheme scheme) =>
      _statistics[_DeliveryStatisticsKey(scheme, address)];

  void flushStatistics(Address address, CoapScheme scheme) {
    _statistics.remove(_DeliveryStatisticsKey(scheme, address));
  }

  void flushAllStatistics() => _statistics.clear();

  Future<void> tick() async {
    for (final element in _elements.values.toList(growable: false)) {
      switch (_actionFor(element)) {
        case _PoolAction.delete:
          remove(element.message);
        case _PoolAction.wait:
          break;
        case _PoolAction.resend:
          await _resend(element.message);
        case _PoolAction.timeout:
          final address =
              element.message.address ??
              const Address(host: 'unknown', port: 0);
          element.message.onResponse?.call(
            CoalaErrorResponse(
              CoapMessagePoolException(
                'Peer $address did not respond to CON message',
              ),
            ),
          );
          remove(element.message);
      }
    }
  }

  void _trackStatistics(CoapMessage message) {
    final address = message.address;
    if (address == null) {
      return;
    }
    final key = _DeliveryStatisticsKey(message.scheme, address);
    final existing =
        _statistics[key] ??
        DeliveryStatistics(
          scheme: message.scheme,
          address: address,
          direct: const DeliveryCounters(totalCount: 0, retransmitsCount: 0),
          proxy: const DeliveryCounters(totalCount: 0, retransmitsCount: 0),
        );
    final retransmit = _elements.containsKey(message.messageId);
    _statistics[key] = message.proxyViaAddress == null
        ? existing.copyWith(
            direct: existing.direct.increment(retransmit: retransmit),
          )
        : existing.copyWith(
            proxy: existing.proxy.increment(retransmit: retransmit),
          );
  }

  _PoolAction _actionFor(_PoolElement element) {
    final elapsed = DateTime.now().difference(element.lastSend);
    if (element.message.type == CoapReliability.confirmable) {
      if (element.timesSent >= maxAttempts) {
        return element.didTransmit ? _PoolAction.delete : _PoolAction.timeout;
      }
      if (element.didTransmit) {
        return _PoolAction.delete;
      }
      final path = '/${element.message.url?.pathSegments.join('/') ?? ''}';
      final query = element.message.url?.query ?? '';
      final custom = longRunningUriPaths
          .where(
            (config) =>
                path.contains(config.path) || query.contains(config.path),
          )
          .firstOrNull;
      final timeout = custom?.timeout ?? resendInterval;
      return elapsed > timeout ? _PoolAction.resend : _PoolAction.wait;
    }
    final timeout = resendInterval * maxAttempts;
    return elapsed > timeout ? _PoolAction.delete : _PoolAction.wait;
  }
}

class _PoolElement {
  _PoolElement(this.message);

  final CoapMessage message;
  int timesSent = 1;
  DateTime lastSend = DateTime.now();
  bool didTransmit = false;
}

enum _PoolAction { resend, wait, delete, timeout }

class _DeliveryStatisticsKey {
  const _DeliveryStatisticsKey(this.scheme, this.address);

  final CoapScheme scheme;
  final Address address;

  @override
  bool operator ==(Object other) =>
      other is _DeliveryStatisticsKey &&
      other.scheme == scheme &&
      other.address == address;

  @override
  int get hashCode => Object.hash(scheme, address);
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    return iterator.current;
  }
}
