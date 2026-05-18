import 'dart:convert';

import 'package:coala/coala.dart';
import 'package:test/test.dart';

void main() {
  test('encodes and decodes CoAP request datagram', () {
    final message =
        CoapMessage.request(
            type: CoapReliability.confirmable,
            method: CoapMethod.get,
            url: Uri.parse('coap://127.0.0.1:5683/sensors/temp?unit=c'),
          )
          ..token = CoapToken([1, 2, 3, 4])
          ..payload = utf8.encode('hello');

    final encoded = CoapSerializer.encode(message);
    final decoded = CoapSerializer.decode(encoded);

    expect(decoded.type, CoapReliability.confirmable);
    expect(decoded.requestMethod, CoapMethod.get);
    expect(decoded.messageId, message.messageId);
    expect(decoded.token, message.token);
    decoded.address = message.address;
    expect(decoded.url.toString(), 'coap://127.0.0.1:5683/sensors/temp?unit=c');
    expect(decoded.payloadString, 'hello');
  });

  test('supports extended options', () {
    final message = CoapMessage(
      type: CoapReliability.nonConfirmable,
      code: const CoapCode.response(CoapResponseCode.content),
    )..setStringOption(CoapOptionNumber.coapsUri, 'coaps://example.test/a');

    final decoded = CoapSerializer.decode(CoapSerializer.encode(message));

    expect(decoded.getStringOptions(CoapOptionNumber.coapsUri), [
      'coaps://example.test/a',
    ]);
  });

  test('verifies checksum option when present', () {
    final message =
        CoapMessage.request(
            type: CoapReliability.confirmable,
            method: CoapMethod.post,
            url: Uri.parse('coap://127.0.0.1:5683/checksum'),
          )
          ..token = CoapToken([1, 2, 3])
          ..payload = utf8.encode('checksum payload');

    final checksum = CoapSerializer.checksumForMessage(message);
    message.setStringOption(CoapOptionNumber.checksum, checksum);

    final decoded = CoapSerializer.decode(CoapSerializer.encode(message));

    expect(decoded.getStringOptions(CoapOptionNumber.checksum), [checksum]);
    expect(decoded.payloadString, 'checksum payload');
  });

  test('rejects checksum mismatch when checksum option is present', () {
    final message =
        CoapMessage.request(
            type: CoapReliability.confirmable,
            method: CoapMethod.post,
            url: Uri.parse('coap://127.0.0.1:5683/checksum'),
          )
          ..payload = utf8.encode('checksum payload')
          ..setStringOption(CoapOptionNumber.checksum, '00000000');

    expect(
      () => CoapSerializer.decode(CoapSerializer.encode(message)),
      throwsA(
        isA<CoapDeserializationException>().having(
          (error) => error.message,
          'message',
          contains('Checksum mismatch'),
        ),
      ),
    );
  });

  test('adds checksum option when send flag is enabled', () {
    final message =
        CoapMessage.request(
            type: CoapReliability.confirmable,
            method: CoapMethod.post,
            url: Uri.parse('coap://127.0.0.1:5683/checksum'),
          )
          ..token = CoapToken([1, 2, 3])
          ..payload = utf8.encode('checksum payload')
          ..addChecksumOnSend = true;

    final decoded = CoapSerializer.decode(
      CoapSerializer.encode(message, addChecksumIfNeeded: true),
    );

    final checksums = decoded.getStringOptions(CoapOptionNumber.checksum);
    expect(checksums, hasLength(1));
    expect(checksums.first, CoapSerializer.checksumForMessage(decoded));
    expect(decoded.payloadString, 'checksum payload');
  });

  test('encodes and decodes custom TCP frames', () {
    final serializer = CoapTcpSerializer();
    final data = [0x40, 0x01, 0x00, 0x01];
    final frame = serializer.encode(
      address: const Address(host: '192.168.1.10', port: 5683),
      data: data,
    );

    final decoded = serializer.decode(frame);

    expect(decoded, hasLength(1));
    expect(
      decoded.single.address,
      const Address(host: '192.168.1.10', port: 5683),
    );
    expect(decoded.single.data, data);
  });
}
