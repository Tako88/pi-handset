// The remembered hub endpoint value type. Persistence lives in
// `SecureTokenStore` (one store, four keys — the endpoints are not secrets), so
// this file is the pure value type only.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/endpoint_store.dart';

void main() {
  group('HubEndpoint', () {
    test('encode is host:port and decode round-trips it', () {
      const endpoint = HubEndpoint(host: '192.168.1.10', port: 8787);

      expect(endpoint.encode(), '192.168.1.10:8787');
      expect(HubEndpoint.decode('192.168.1.10:8787'), endpoint);
    });

    test('decode rejects a malformed value', () {
      expect(HubEndpoint.decode('no-port'), isNull);
      expect(HubEndpoint.decode('host:'), isNull);
      expect(HubEndpoint.decode(':8787'), isNull);
      expect(HubEndpoint.decode('host:notaport'), isNull);
      expect(HubEndpoint.decode('host:0'), isNull);
      expect(HubEndpoint.decode(null), isNull);
    });
  });

  group('encodeEndpoints/decodeEndpoints', () {
    test('encodeEndpoints joins the list with newlines', () {
      expect(
        encodeEndpoints(const [
          HubEndpoint(host: 'a', port: 1),
          HubEndpoint(host: 'b', port: 2),
        ]),
        'a:1\nb:2',
      );
    });

    test('decodeEndpoints parses a legacy single value', () {
      expect(decodeEndpoints('a:1'), const [HubEndpoint(host: 'a', port: 1)]);
    });

    test('decodeEndpoints parses a newline list', () {
      expect(
        decodeEndpoints('a:1\nb:2'),
        const [
          HubEndpoint(host: 'a', port: 1),
          HubEndpoint(host: 'b', port: 2),
        ],
      );
    });

    test('decodeEndpoints skips a malformed line', () {
      expect(
        decodeEndpoints('a:1\ngarbage'),
        const [HubEndpoint(host: 'a', port: 1)],
      );
    });

    test('decodeEndpoints is empty for null', () {
      expect(decodeEndpoints(null), isEmpty);
    });
  });

  group('candidateLabel', () {
    test('labels a private LAN address', () {
      expect(candidateLabel('192.168.1.10'), 'Home network');
    });

    test('labels a Tailscale/CGNAT address', () {
      expect(candidateLabel('100.64.1.2'), 'Tailscale');
    });

    test('falls back to the host for anything else', () {
      expect(candidateLabel('example'), 'example');
    });
  });
}
