/// The composer's gallery-pick action, lifted out of the app shell.
///
/// Owns the pick/refuse/arm sequence for one attachment: it invokes the picker,
/// turns a platform error into a visible message (a user cancel is silent),
/// refuses an oversized image locally, and hands an accepted pick to the shell,
/// which owns the attachment slot. A pure action layer: all it needs from the
/// shell is a liveness probe.
library;

import 'package:flutter/material.dart';

import '../client/attachment.dart';
import '../platform/gallery_picker.dart';

/// The composer's attach action.
class AttachmentActions {
  AttachmentActions({required this.isMounted});

  /// Whether the owning State is still mounted. Read at each guard point, at
  /// the position the shell's own `mounted` checks held.
  final bool Function() isMounted;

  /// Picks one gallery image and arms it for the next send. A cancel is silent;
  /// a platform error and an over-cap image each get a visible reason. The
  /// messenger is captured before the picker's await, because this context is
  /// gone once it returns.
  Future<void> pick(
    BuildContext context, {
    required Future<PickedImage?> Function()? pickImage,
    required void Function(PickedImage) onPicked,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final PickedImage? picked;
    try {
      picked = await (pickImage ?? pickGalleryImage)();
    } catch (_) {
      if (!isMounted()) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the gallery')),
      );
      return;
    }
    if (!isMounted()) return;
    if (picked == null) return;
    if (!withinAttachmentCap(picked.bytes.length)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('That image is too large to send')),
      );
      return;
    }
    onPicked(picked);
  }
}
