# Coala Dart

Pure Dart implementation of Coala on top of CoAP messages. The package works in
Dart and Flutter mobile/desktop apps because it uses `dart:io` sockets and does
not require Swift, CocoaPods, or platform channels.

Coala Dart ports the main Coala Swift surface:

- UDP client/server API over CoAP datagram encoding.
- Coala TCP frame transport.
- Resources with `GET`, `POST`, `PUT`, and `DELETE` handlers.
- Response callbacks, retransmit pool, and delivery statistics.
- Observe registrations and notifications.
- Multicast discovery on `224.0.0.187:5683/info`.
- Proxy options.
- Block1/Block2 and selective-repeat ARQ for large payloads.
- `coaps` handshake/encryption with X25519, HKDF-SHA256, and AES-GCM using
  Coala's 12-byte authentication tag format.

## Requirements

- Dart SDK `^3.11.0`
- A `dart:io` compatible platform

```bash
dart pub get
dart analyze
dart test
```

## Quick Start

```dart
import 'dart:async';

import 'package:coala/coala.dart';

Future<void> main() async {
  final server = Coala(transport: const CoalaUdpTransport(port: 5683));
  await server.start();

  server.addResource(
    CoapResource(
      method: CoapMethod.get,
      path: '/msg',
      handler: (_) => CoapResourceResponse.string(
        CoapResponseCode.content,
        'Hello from Coala Dart',
      ),
    ),
  );

  final client = Coala(transport: const CoalaUdpTransport(port: 0));
  await client.start();

  final responseCompleter = Completer<CoapMessage>();
  final request =
      CoapMessage.request(
          type: CoapReliability.confirmable,
          method: CoapMethod.get,
          url: Uri.parse('coap://127.0.0.1:5683/msg'),
        )
        ..onResponse = (response) {
          switch (response) {
            case CoalaMessageResponse(:final message):
              responseCompleter.complete(message);
            case CoalaErrorResponse(:final error):
              responseCompleter.completeError(error);
          }
        };

  await client.send(request);
  final response = await responseCompleter.future;
  print(response.payloadString);

  await client.stop();
  await server.stop();
}
```

## Multicast Discovery

The example searches for Coala peers with
`NON GET coap://224.0.0.187:5683/info`.

```bash
dart run example/multicast_discovery.dart
```

If the machine has VPN or tunnel interfaces, the operating system can route
multicast through the wrong interface. In that case, pass the LAN interface
explicitly:

```bash
dart run example/multicast_discovery.dart --interface en0
```

The example starts a UDP socket, registers `/hello`, runs discovery, and prints
remote peers.

## Main API

### `Coala`

| Method | Description |
| --- | --- |
| `Coala({CoalaTransport transport})` | Creates a Coala stack with UDP transport by default. |
| `start()` | Opens the UDP socket or TCP connection, adds the discovery resource, and starts the message pool. UDP transport also joins multicast group `224.0.0.187`. |
| `stop()` | Stops timers/subscriptions and closes the socket. |
| `restart()` | Runs `stop()` and then `start()`. |
| `setTransport(transport)` | Replaces the transport and restarts the stack. |
| `send(message)` | Runs outbound layers, serializes the message, and sends it. If the stack has not been started yet, it starts automatically. |
| `sendWithBlock2DownloadProgress(message, onProgress: ...)` | Sends a request and calls `onProgress` while Block2/ARQ response payload is being accumulated. |
| `addResource(resource)` | Registers a server-side resource. |
| `removeResourcesForPath(path)` | Removes all resources for a path. |
| `startObserving(url: ..., onUpdate: ...)` | Sends `GET` with Observe option `0` and calls `onUpdate` for notifications. |
| `stopObserving(url: ..., onStop: ...)` | Sends `GET` with Observe option `1` and removes the local registration. |
| `configureMessagePool(...)` | Configures retransmit interval and attempt count for confirmable messages. |
| `configureMessagePoolTimeouts(...)` | Sets longer timeouts for selected URI/path patterns. |
| `getStatistics(...)`, `flushStatistics(...)` | Reads and clears direct/proxy delivery counters. |
| `resourceDiscovery.run(...)` | Runs multicast discovery and returns `Map<Address, CoapMessage>`. |

Static API:

- `Coala.defaultPort` - `5683`.
- `Coala.logger` - logger for inbound, outbound, warning, and error messages.
- `Coala.curvePublicKey` - current X25519 public key.
- `Coala.setCurvePrivateKeySeed(seed)` - sets a deterministic X25519 key pair
  from a 32-byte seed.

### Transports

| Class | Description |
| --- | --- |
| `CoalaUdpTransport` | UDP transport. Fields: `port`, `bindAddress`, `multicastInterface`, `reuseAddress`, `reusePort`. |
| `CoalaTcpTransport` | TCP transport with Coala frame format. Fields: `host`, `port`. |

Use `multicastInterface` when the operating system chooses the wrong outgoing
interface for multicast:

```dart
final interfaces = await NetworkInterface.list(
  type: InternetAddressType.IPv4,
);
final en0 = interfaces.firstWhere((item) => item.name == 'en0');

final coala = Coala(
  transport: CoalaUdpTransport(multicastInterface: en0),
);
```

### Resources

| Class | Description |
| --- | --- |
| `CoapResource` | Regular resource with `method`, `path`, and handler. |
| `ObservableResource` | `GET` resource with Observe support and `notifyObservers()`. |
| `CoapDiscoveryResource` | Discovery resource that responds with content-format `40`. |
| `CoapResourceRequest` | Incoming request data: `query`, `payload`, `payloadString`, `message`, `from`. |
| `CoapResourceResponse` | Response code and optional payload. Includes `CoapResourceResponse.string(...)`. |

Example `POST` resource:

```dart
coala.addResource(
  CoapResource(
    method: CoapMethod.post,
    path: '/config',
    handler: (request) {
      print('Payload from ${request.from}: ${request.payloadString}');
      return const CoapResourceResponse(CoapResponseCode.changed);
    },
  ),
);
```

## Messages and Methods

### CoAP Methods

| Method | Purpose |
| --- | --- |
| `CoapMethod.get` | Read a resource representation or state. |
| `CoapMethod.post` | Send a command or create/update subordinate state. |
| `CoapMethod.put` | Replace or set resource state. |
| `CoapMethod.delete` | Delete a resource or clear state. |

Exact semantics are defined by the server-side handler, as in CoAP.

### Reliability Types

| Type | Purpose |
| --- | --- |
| `CoapReliability.confirmable` (`CON`) | Requires ACK/RST. The message pool retransmits until timeout. |
| `CoapReliability.nonConfirmable` (`NON`) | Sends without requiring ACK. Used by discovery. |
| `CoapReliability.acknowledgement` (`ACK`) | Acknowledges a CON message. |
| `CoapReliability.reset` (`RST`) | Rejects a message or Observe notification. |

### `CoapMessage`

| API | Description |
| --- | --- |
| `CoapMessage(...)` | Creates a message with explicit `type` and `code`. |
| `CoapMessage.request(...)` | Creates a request from a `CoapMethod` and optional `Uri`. |
| `CoapMessage.ackTo(...)` | Creates an ACK for an incoming request. |
| `CoapMessage.responseTo(...)` | Creates a response with token/address copied from a request. |
| `url` | Reads/writes URI through CoAP options: scheme, host, port, path, query. |
| `address` | Remote endpoint used for sending. Usually set through `url`. |
| `token` | CoAP token. Assigning `onResponse` generates a token automatically if missing. |
| `payload`, `payloadString` | Binary or UTF-8 payload. |
| `addChecksumOnSend` | When `true`, `send` adds/refreshes `checksum` (`4006`) before serialization. |
| `setOption(...)`, `setStringOption(...)`, `setIntegerOption(...)` | Set CoAP options. |
| `getOptions(...)`, `getStringOptions(...)`, `getIntegerOptions(...)` | Read CoAP options. |
| `block1Option`, `block2Option` | Typed accessors for Block1/Block2. |
| `copy()` | Deep copy with payload, token, and options. |

Responses are delivered through the callback:

```dart
final message =
    CoapMessage.request(
        type: CoapReliability.confirmable,
        method: CoapMethod.get,
        url: Uri.parse('coap://192.168.1.10:5683/info'),
      )
      ..onResponse = (response) {
        switch (response) {
          case CoalaMessageResponse(:final message, :final from):
            print('Response from $from: ${message.payloadString}');
          case CoalaErrorResponse(:final error):
            print('Request failed: $error');
        }
      };

await coala.send(message);
```

## Discovery

`ResourceDiscovery.run()` works only with UDP transport:

```dart
final peers = await coala.resourceDiscovery.run(
  path: CoalaDefaults.discoveryPath,
  timeout: const Duration(seconds: 2),
);
```

Defaults:

- multicast group: `224.0.0.187`
- port: `5683`
- path: `info`
- request: `NON GET coap://224.0.0.187:5683/info`

Responses are collected by source address. For multicast requests, the original
message remains in the pool for the discovery window, so multiple responses can
be received for the same token.

## Observe

Server-side:

```dart
final temperature = ObservableResource(
  path: '/temperature',
  handler: (_) => CoapResourceResponse.string(
    CoapResponseCode.content,
    '23.4',
  ),
);

coala.addResource(temperature);
await temperature.notifyObservers();
```

Client-side:

```dart
await coala.startObserving(
  url: Uri.parse('coap://192.168.1.10:5683/temperature'),
  onUpdate: (response) {
    if (response case CoalaMessageResponse(:final message)) {
      print(message.payloadString);
    }
  },
);

await coala.stopObserving(
  url: Uri.parse('coap://192.168.1.10:5683/temperature'),
);
```

Observe tokens are deterministic from the URL to match Coala Swift behavior.
Notifications are filtered by Observe sequence number. When `Max-Age` expires,
the client re-registers automatically.

## Secure Coala (`coaps`)

Use a URI with the `coaps` scheme. The handshake starts automatically:

```dart
final request =
    CoapMessage.request(
      type: CoapReliability.confirmable,
      method: CoapMethod.get,
      url: Uri.parse('coaps://192.168.1.10:5683/secure'),
    )..onResponse = handleResponse;

await coala.send(request);
```

Internally:

- X25519 key agreement.
- HKDF-SHA256 derives two AES keys and two IVs.
- Payload and encrypted URI are carried through Coala custom options.
- AES-GCM tag is truncated to 12 bytes for Coala Swift compatibility.
- A deterministic key can be set with `Coala.setCurvePrivateKeySeed(seed)`.

## Blockwise and Large Payloads

Payloads larger than `1024` bytes are split into Block1/Block2 segments. For
Coala peers, the stack also uses selective-repeat ARQ with option
`selectiveRepeatWindowSize` (`3001`) to send a window of blocks and reassemble
the payload on the receiver.

Use this helper for download progress:

```dart
await coala.sendWithBlock2DownloadProgress(
  request,
  onProgress: (data) {
    print('Downloaded ${data.length} bytes');
  },
);
```

## Serializer API

| API | Description |
| --- | --- |
| `CoapSerializer.encode(message)` | Encodes `CoapMessage` into a CoAP datagram. |
| `CoapSerializer.decode(data)` | Decodes a datagram into `CoapMessage`. |
| `CoapTcpSerializer.encode(...)` | Encodes a Coala TCP frame: delimiter, IPv4, port, payload length, payload. |
| `CoapTcpSerializer.decode(data)` | Stream-decodes TCP frames and keeps incomplete frame data in an internal buffer. |
| `CoapTcpSerializer.flushBuffer()` | Clears the frame buffer. |

## How Coala Differs from CoAP

CoAP is a standard application protocol: message format, methods, response
codes, options, UDP transport, reliability model, Observe, Blockwise, and
discovery conventions. Coala Dart uses the CoAP message model and wire format
for basic UDP datagrams, but adds compatibility with the Coala ecosystem.

Key differences:

- Discovery uses the Coala convention: multicast `224.0.0.187`, path `info`,
  and port `5683`. This is not the generic `/.well-known/core` discovery
  endpoint.
- `coaps` here is not DTLS. Secure mode is implemented at the Coala layer with
  X25519 handshake, HKDF-SHA256, AES-GCM, and custom CoAP options.
- Coala defines custom options: `uriScheme` (`2111`),
  `selectiveRepeatWindowSize` (`3001`), `proxySecurityId` (`3004`),
  `handshakeType` (`3999`), `sessionNotFound` (`4001`), `sessionExpired`
  (`4003`), `coapsUri` (`4005`), and `checksum` (`4006`).
- `checksum` is not added automatically by default. Set
  `message.addChecksumOnSend = true` to add/refresh it during `send`; incoming
  peers that support it verify CRC32 against the serialized message with the
  checksum option removed.
- Large messages can use Coala selective-repeat ARQ on top of Block1/Block2,
  not only basic CoAP blockwise exchange.
- TCP transport uses a custom Coala frame format, not RFC 8323 CoAP-over-TCP
  framing.
- The API is organized around a client/server object model: `Coala`,
  resources, callbacks, observe registry, message pool, and statistics.

In short: regular CoAP peers can understand simple UDP CoAP datagrams, but Coala
features such as secure mode, Coala TCP framing, selective-repeat ARQ, and the
discovery payload require Coala extension support on the other side.
