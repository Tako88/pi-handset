// The remembered hub endpoint value type. Persistence lives in
// `SecureTokenStore` (one store, two keys — the endpoint is not a secret), so
// this file is the pure value type only.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/endpoint_store.dart';

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
}
