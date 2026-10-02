/// Picks one image from the device gallery and reads it into a [PickedImage].
///
/// This is the only place the app names the `image_picker` plugin. There is no
/// seam here; tests that need a fake wrap this function reference (the shell
/// takes an optional `pickImage` callback defaulting to [pickGalleryImage]).
/// A platform error (permission denial, picker failure) is deliberately allowed
/// to propagate — the shell turns it into a visible message — while a user
/// cancel returns null silently.
library;

import 'package:image_picker/image_picker.dart';

import '../client/attachment.dart';

/// The default picker. Downscales to 1280 px at quality 80 so a phone photo
/// usually lands under [maxAttachmentBytes]; callers must still check
/// [withinAttachmentCap] and refuse an oversized result.
Future<PickedImage?> pickGalleryImage() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 1280,
    maxHeight: 1280,
    imageQuality: 80,
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  return PickedImage(bytes, imageMimeType(bytes));
}
