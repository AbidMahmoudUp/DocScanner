import 'dart:async';


import 'package:flutter/material.dart';

/// Resolves an image's intrinsic size without decoding it at full resolution.
///
/// The crop canvas has to match the capture's aspect ratio exactly, or the
/// normalized quad the user drags would not line up with the pixels.
Future<Size> resolveImageSize(ImageProvider provider) {
  final completer = Completer<Size>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;

  listener = ImageStreamListener(
    (ImageInfo info, bool synchronous) {
      if (!completer.isCompleted) {
        completer.complete(Size(info.image.width.toDouble(), info.image.height.toDouble()));
      }
      info.dispose();
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? stack) {
      if (!completer.isCompleted) completer.completeError(error);
      stream.removeListener(listener);
    },
  );

  stream.addListener(listener);
  return completer.future;
}
