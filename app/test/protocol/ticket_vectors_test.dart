// The shared ticket-normalization vectors, asserted against the Dart port.
//
// JS `toUpperCase` performs Unicode full case mappings that a naive Dart port
// does not (e.g. `ß` -> `SS`), and this is the one place the two languages were
// expected to drift. The vectors pin the exact normalized output, not just
// accept/reject.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/protocol/ticket.dart';

void main() {
  final file =
      jsonDecode(
            File('../protocol/fixtures/tickets/vectors.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final vectors = (file['vectors'] as List).cast<Map<String, dynamic>>();

  test('the vector file pins the same alphabet and length ticket.dart uses', () {
    expect(file['alphabet'], ticketAlphabet);
    expect(file['length'], ticketLength);
  });

  test('every vector normalizes exactly as ticket.dart does', () {
    expect(vectors, isNotEmpty, reason: 'the vector file must not be empty');
    for (final vector in vectors) {
      final result = normalizeTicket(vector['input']);
      if (vector['accept'] == true) {
        expect(
          result,
          vector['normalized'],
          reason: '${vector['name']}: expected ${vector['normalized']}, got $result',
        );
      } else {
        expect(result, isNull, reason: '${vector['name']}: expected rejection, got $result');
      }
    }
  });
}
