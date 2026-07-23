import 'package:flutter/material.dart';

/// Returns `true` when the caller may open the gallery picker.
///
/// iOS PHPicker and Android system Photo Picker do not require manifest
/// READ_MEDIA_* permissions; the picker grants access to the selected item only.
Future<bool> ensureAvatarGalleryAccess(BuildContext context) async => true;

/// No-op: system picker handles access; no broad photo library permission to re-check.
Future<void> promptAvatarGalleryAccessIfBlocked(BuildContext context) async {}
