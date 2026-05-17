enum LogLevel { verbose, debug, info, warning, error }

abstract interface class CoalaLogger {
  void log(String message, LogLevel level, {bool asynchronous = true});
}

class DefaultCoalaLogger implements CoalaLogger {
  DefaultCoalaLogger({this.minLogLevel = LogLevel.warning});

  LogLevel minLogLevel;

  @override
  void log(String message, LogLevel level, {bool asynchronous = true}) {
    if (level.index < minLogLevel.index) {
      return;
    }
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
    // ignore: avoid_print
    print('$time ${level.name}: $message');
  }
}

void logVerbose(String message, {bool asynchronous = true}) =>
    CoalaLog.logger?.log(message, LogLevel.verbose, asynchronous: asynchronous);

void logDebug(String message, {bool asynchronous = true}) =>
    CoalaLog.logger?.log(message, LogLevel.debug, asynchronous: asynchronous);

void logInfo(String message, {bool asynchronous = true}) =>
    CoalaLog.logger?.log(message, LogLevel.info, asynchronous: asynchronous);

void logWarning(String message, {bool asynchronous = true}) =>
    CoalaLog.logger?.log(message, LogLevel.warning, asynchronous: asynchronous);

void logError(String message, {bool asynchronous = true}) =>
    CoalaLog.logger?.log(message, LogLevel.error, asynchronous: asynchronous);

class CoalaLog {
  static CoalaLogger? logger = DefaultCoalaLogger();
}
