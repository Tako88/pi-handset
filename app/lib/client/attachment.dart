/// One image picked from the gallery, ready to be sent as an `images` arg on
/// the `prompt` command.
///
/// Pure Dart: no Flutter import, so it tests without a binding. The bridge turns
/// each entry into pi's `ImageContent` (`{type:'image',data,mimeType}`); the
/// bytes travel base64-encoded inside the existing `command` frame's opaque
/// `args`, so no protocol change is involved.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The largest image we will send, in bytes. Chosen so the base64 form
/// (4/3 the size, ~467 KiB here) plus the envelope stays well under the hub's
/// 1 MiB `maxPayload`. pi itself does not resize an image on this path, so this
/// guard is the only size defence.
const int maxAttachmentBytes = 350 * 1024;

/// Whether [bytes] is small enough to send.
bool withinAttachmentCap(int bytes) => bytes <= maxAttachmentBytes;

/// An image read from the gallery, with the mime type sniffed from the bytes.
class PickedImage {
  final Uint8List bytes;
  final String mimeType;

  const PickedImage(this.bytes, this.mimeType);

  /// The `images` entry shape the bridge expects.
  Map<String, Object?> toArg() => {
    'data': base64Encode(bytes),
    'mimeType': mimeType,
  };
}

/// The mime type implied by [bytes]' magic number, defaulting to `image/jpeg`.
///
/// Sniffed from the returned bytes rather than trusted from the picker, because
/// `imageQuality` can re-encode an animated GIF/WEBP into a static JPEG.
String imageMimeType(Uint8List bytes) {
  if (_startsWith(bytes, [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (_startsWith(bytes, [0xFF, 0xD8])) return 'image/jpeg';
  if (_startsWith(bytes, [0x47, 0x49, 0x46])) return 'image/gif';
  if (_startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) &&
      _matchesAt(bytes, 8, [0x57, 0x45, 0x42, 0x50])) {
    return 'image/webp';
  }
  return 'image/jpeg';
}

bool _startsWith(Uint8List bytes, List<int> prefix) =>
    _matchesAt(bytes, 0, prefix);

bool _matchesAt(Uint8List bytes, int offset, List<int> pattern) {
  if (bytes.length < offset + pattern.length) return false;
  for (var i = 0; i < pattern.length; i++) {
    if (bytes[offset + i] != pattern[i]) return false;
  }
  return true;
}
