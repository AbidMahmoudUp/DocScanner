import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';

import '../../data/local/file_storage.dart';

/// Raised when an image cannot be brought in from the gallery.
class ImportException implements Exception {
  const ImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Brings existing photos into the scan pipeline.
///
/// A picked image is copied into the app's captures folder first, so from that
/// point on it is indistinguishable from a camera capture: the same detection,
/// crop and enhancement run on it, and the same cleanup sweeps it away.
class ImageImportService {
  ImageImportService(this._storage, {ImagePicker? picker})
      : _picker = picker ?? ImagePicker();

  final FileStorage _storage;
  final ImagePicker _picker;

  /// Opens the system photo picker and returns local paths for what was
  /// chosen, in the order the user picked them. Empty when they backed out.
  ///
  /// On Android 13+ this is the system Photo Picker, which grants access to
  /// just the chosen items — no storage permission is requested, and the app
  /// never sees the rest of the gallery.
  Future<List<String>> pickFromGallery({bool allowMultiple = true}) async {
    try {
      final picked = allowMultiple
          ? await _picker.pickMultiImage()
          : [?await _picker.pickImage(source: ImageSource.gallery)];

      final paths = <String>[];
      for (final image in picked) {
        paths.add(await _copyIntoCaptures(image));
      }
      return paths;
    } on PlatformException catch (error) {
      throw ImportException(error.message ?? 'The gallery could not be opened');
    } on FileSystemException catch (error) {
      throw ImportException('Could not read that image: ${error.osError?.message ?? error.message}');
    }
  }

  /// Copies the picked file into app storage.
  ///
  /// The picker hands back a URI-backed temp file that the system may reclaim,
  /// so nothing downstream should depend on it still being there.
  Future<String> _copyIntoCaptures(XFile image) async {
    final destination = _storage.newCapturePath();
    await File(image.path).copy(destination);
    return destination;
  }
}
