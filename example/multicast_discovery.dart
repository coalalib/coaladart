import 'dart:io';

import 'package:coala/coala.dart';

Future<void> main(List<String> args) async {
  final port = args.contains('--ephemeral') ? 0 : Coala.defaultPort;
  final coala = Coala(
    transport: CoalaUdpTransport(
      port: port,
      reuseAddress: true,
      reusePort: Platform.isMacOS || Platform.isLinux,
    ),
  );

  await coala.start();

  coala.addResource(
    CoapResource(
      method: CoapMethod.get,
      path: '/hello',
      handler: (_) => CoapResourceResponse.string(
        CoapResponseCode.content,
        'hello from ${awaitHostName()}',
      ),
    ),
  );

  final localAddresses = await _localIPv4Addresses();
  final localPort = coala.localPort ?? port;

  print('Coala UDP started on port $localPort.');
  print('Local IPv4 addresses: ${localAddresses.join(', ')}');
  print(
    'Searching peers with multicast ${CoalaDefaults.multicastAddress}:${Coala.defaultPort}...',
  );

  final peers = await coala.resourceDiscovery.run(
    path: CoalaDefaults.discoveryPath,
    timeout: const Duration(seconds: 2),
  );

  final remotePeers = Map<Address, CoapMessage>.fromEntries(
    peers.entries.where((entry) => !localAddresses.contains(entry.key.host)),
  );

  if (remotePeers.isEmpty) {
    print('No remote Coala peers found.');
  } else {
    for (final entry in remotePeers.entries) {
      final payload = entry.value.payloadString;
      print(
        '${entry.key} supports: ${payload.isEmpty ? '(no advertised resources)' : payload}',
      );
    }
  }

  await coala.stop();
}

String awaitHostName() {
  try {
    return Platform.localHostname;
  } on Object {
    return 'unknown-host';
  }
}

Future<Set<String>> _localIPv4Addresses() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: true,
    type: InternetAddressType.IPv4,
  );
  return {
    for (final interface in interfaces)
      for (final address in interface.addresses) address.address,
  };
}
