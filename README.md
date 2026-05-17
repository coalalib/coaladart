# Coala Dart

Pure Dart migration of the Coala Swift CoAP library. The package is usable from
Flutter mobile and desktop targets because it uses `dart:io` sockets and does
not depend on Swift, CocoaPods, or platform channels.

## Basic Use

```dart
final coala = Coala(transport: const CoalaUdpTransport(port: 5683));
await coala.start();

coala.addResource(
  CoapResource(
    method: CoapMethod.get,
    path: '/msg',
    handler: (_) => CoapResourceResponse.string(
      CoapResponseCode.content,
      'Hello from Coala Dart',
    ),
  ),
);

final request = CoapMessage.request(
  type: CoapReliability.confirmable,
  method: CoapMethod.get,
  url: Uri.parse('coap://192.168.1.20:5683/msg'),
)..onResponse = (response) {
    if (response case CoalaMessageResponse(:final message, :final from)) {
      print('Response from $from: ${message.payloadString}');
    }
  };

await coala.send(request);
```

## Migrated Surface

- CoAP datagram serializer/deserializer
- message types, methods, response codes, options, tokens, addresses
- UDP transport and custom Coala TCP frame transport
- client/server `Coala` API with resources
- response callbacks, retries, delivery statistics
- observer registration/notifications
- multicast discovery resource
- proxy option handling
- block option parsing and basic blockwise accumulation
- deterministic observe tokens compatible with the Swift SHA-256 token strategy
- `coaps` handshake/encryption with X25519, HKDF-SHA256 and AES-GCM using
  Coala's 12-byte authentication tag format
