import 'dart:async';
import 'dart:io';

import 'package:coala/coala.dart';
import 'package:test/test.dart';

void main() {
  test('serves a local UDP resource', () async {
    final server = Coala(transport: const CoalaUdpTransport(port: 0));
    final client = Coala(transport: const CoalaUdpTransport(port: 0));
    addTearDown(server.stop);
    addTearDown(client.stop);

    await server.start();
    await client.start();

    final serverPort = server.localPort;
    expect(serverPort, isNotNull);

    server.addResource(
      CoapResource(
        method: CoapMethod.get,
        path: '/msg',
        handler: (_) =>
            CoapResourceResponse.string(CoapResponseCode.content, 'pong'),
      ),
    );

    final completer = Completer<CoapMessage>();
    final message =
        CoapMessage.request(
            type: CoapReliability.confirmable,
            method: CoapMethod.get,
            url: Uri.parse('coap://127.0.0.1:$serverPort/msg'),
          )
          ..onResponse = (response) {
            switch (response) {
              case CoalaMessageResponse(:final message):
                completer.complete(message);
              case CoalaErrorResponse(:final error):
                completer.completeError(error);
            }
          };

    await client.send(message);
    final response = await completer.future.timeout(const Duration(seconds: 2));

    expect(response.responseCode, CoapResponseCode.content);
    expect(response.payloadString, 'pong');
  });

  test('serves a local secure UDP resource', () async {
    final server = Coala(transport: const CoalaUdpTransport(port: 0));
    final client = Coala(transport: const CoalaUdpTransport(port: 0));
    addTearDown(server.stop);
    addTearDown(client.stop);
    await server.start();
    await client.start();

    final serverPort = server.localPort;
    expect(serverPort, isNotNull);

    server.addResource(
      CoapResource(
        method: CoapMethod.get,
        path: '/secure',
        handler: (_) => CoapResourceResponse.string(
          CoapResponseCode.content,
          'secret-pong',
        ),
      ),
    );

    final completer = Completer<CoapMessage>();
    final message =
        CoapMessage.request(
            type: CoapReliability.confirmable,
            method: CoapMethod.get,
            url: Uri.parse('coaps://127.0.0.1:$serverPort/secure'),
          )
          ..onResponse = (response) {
            switch (response) {
              case CoalaMessageResponse(:final message):
                completer.complete(message);
              case CoalaErrorResponse(:final error):
                completer.completeError(error);
            }
          };

    await client.send(message);
    final response = await completer.future.timeout(const Duration(seconds: 4));

    expect(response.responseCode, CoapResponseCode.content);
    expect(response.payloadString, 'secret-pong');
  });

  test('transfers large UDP responses with selective-repeat ARQ', () async {
    final server = Coala(transport: const CoalaUdpTransport(port: 0));
    final client = Coala(transport: const CoalaUdpTransport(port: 0));
    addTearDown(server.stop);
    addTearDown(client.stop);

    await server.start();
    await client.start();

    final serverPort = server.localPort;
    expect(serverPort, isNotNull);

    final payload = 'x' * 3000;
    server.addResource(
      CoapResource(
        method: CoapMethod.get,
        path: '/large',
        handler: (_) =>
            CoapResourceResponse.string(CoapResponseCode.content, payload),
      ),
    );

    final completer = Completer<CoapMessage>();
    final message =
        CoapMessage.request(
            type: CoapReliability.confirmable,
            method: CoapMethod.get,
            url: Uri.parse('coap://127.0.0.1:$serverPort/large'),
          )
          ..onResponse = (response) {
            switch (response) {
              case CoalaMessageResponse(:final message):
                completer.complete(message);
              case CoalaErrorResponse(:final error):
                completer.completeError(error);
            }
          };

    await client.send(message);
    final response = await completer.future.timeout(const Duration(seconds: 4));

    expect(response.responseCode, CoapResponseCode.content);
    expect(response.payloadString, payload);
  });

  test('transfers large secure UDP responses', () async {
    final server = Coala(transport: const CoalaUdpTransport(port: 0));
    final client = Coala(transport: const CoalaUdpTransport(port: 0));
    addTearDown(server.stop);
    addTearDown(client.stop);

    await server.start();
    await client.start();

    final serverPort = server.localPort;
    expect(serverPort, isNotNull);

    final payload = 'secure-' * 500;
    server.addResource(
      CoapResource(
        method: CoapMethod.get,
        path: '/secure-large',
        handler: (_) =>
            CoapResourceResponse.string(CoapResponseCode.content, payload),
      ),
    );

    final completer = Completer<CoapMessage>();
    final message =
        CoapMessage.request(
            type: CoapReliability.confirmable,
            method: CoapMethod.get,
            url: Uri.parse('coaps://127.0.0.1:$serverPort/secure-large'),
          )
          ..onResponse = (response) {
            switch (response) {
              case CoalaMessageResponse(:final message):
                completer.complete(message);
              case CoalaErrorResponse(:final error):
                completer.completeError(error);
            }
          };

    await client.send(message);
    final response = await completer.future.timeout(const Duration(seconds: 4));

    expect(response.responseCode, CoapResponseCode.content);
    expect(response.payloadString, payload);
  });

  test(
    'keeps request pending after empty ACK until separate response arrives',
    () async {
      final rawServer = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(rawServer.close);

      final client = Coala(transport: const CoalaUdpTransport(port: 0));
      addTearDown(client.stop);
      client.configureMessagePool(
        expirationTimeout: const Duration(milliseconds: 90),
        totalResendCount: 10,
      );
      await client.start();

      rawServer.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }
        final datagram = rawServer.receive();
        if (datagram == null) {
          return;
        }
        final request = CoapSerializer.decode(datagram.data);
        final clientAddress = Address(
          host: datagram.address.address,
          port: datagram.port,
        );
        final ack = CoapMessage.ackTo(
          request: request,
          from: clientAddress,
          code: CoapResponseCode.empty,
        );
        rawServer.send(
          CoapSerializer.encode(ack),
          datagram.address,
          datagram.port,
        );

        Future<void>.delayed(const Duration(milliseconds: 180), () {
          final response =
              CoapMessage(
                  type: CoapReliability.nonConfirmable,
                  code: const CoapCode.response(CoapResponseCode.content),
                )
                ..token = request.token
                ..payloadString = 'separate';
          rawServer.send(
            CoapSerializer.encode(response),
            datagram.address,
            datagram.port,
          );
        });
      });

      final completer = Completer<CoapMessage>();
      final message =
          CoapMessage.request(
              type: CoapReliability.confirmable,
              method: CoapMethod.get,
              url: Uri.parse('coap://127.0.0.1:${rawServer.port}/separate'),
            )
            ..onResponse = (response) {
              switch (response) {
                case CoalaMessageResponse(:final message):
                  if (!completer.isCompleted) {
                    completer.complete(message);
                  }
                case CoalaErrorResponse(:final error):
                  if (!completer.isCompleted) {
                    completer.completeError(error);
                  }
              }
            };

      await client.send(message);
      final response = await completer.future.timeout(
        const Duration(seconds: 2),
      );

      expect(response.responseCode, CoapResponseCode.content);
      expect(response.payloadString, 'separate');
    },
  );
}
