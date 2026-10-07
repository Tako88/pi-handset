// The attachment model: mime sniffing from magic bytes, the base64 arg shape,
// and the local size cap. Pure Dart, no Flutter, so it tests without a binding.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/attachment.dart';

void main() {
  group('imageMimeType', () {
    test('sniffs PNG', () {
      expect(
        imageMimeType(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])),
        'image/png',
      );
    });

    test('sniffs JPEG', () {
      expect(
        imageMimeType(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])),
        'image/jpeg',
      );
    });

    test('sniffs GIF', () {
      expect(
        imageMimeType(Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])),
        'image/gif',
      );
    });

    test('sniffs WEBP', () {
      // RIFF....WEBP
      expect(
        imageMimeType(
          Uint8List.fromList([
            0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
            0x57, 0x45, 0x42, 0x50,
          ]),
        ),
        'image/webp',
      );
    });

    test('falls back to image/jpeg for unknown bytes', () {
      expect(
        imageMimeType(Uint8List.fromList([0x00, 0x01, 0x02, 0x03])),
        'image/jpeg',
      );
    });
  });

  group('PickedImage.toArg', () {
    test('base64-encodes the bytes and keeps the mime type', () {
      final image = PickedImage(
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
        'image/png',
      );

      expect(image.toArg(), {
        'data': base64Encode([0x89, 0x50, 0x4E, 0x47]),
        'mimeType': 'image/png',
      });
    });
  });

  group('withinAttachmentCap', () {
    test('accepts a size exactly at the cap', () {
      expect(withinAttachmentCap(maxAttachmentBytes), isTrue);
    });

    test('rejects one byte over the cap', () {
      expect(withinAttachmentCap(maxAttachmentBytes + 1), isFalse);
    });
  });
}
