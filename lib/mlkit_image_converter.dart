import 'dart:typed_data';
import 'dart:ui';

import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:image/image.dart' as img;

Uint8List convertRgbToNv21Bytes(Uint8List rgb, int width, int height) {
  final int frameSize = width * height;
  final Uint8List nv21 = Uint8List(frameSize + frameSize ~/ 2);

  int yIndex = 0;
  int uvIndex = frameSize;

  for (int j = 0; j < height; j++) {
    for (int i = 0; i < width; i++) {
      final int r = rgb[(j * width + i) * 3];
      final int g = rgb[(j * width + i) * 3 + 1];
      final int b = rgb[(j * width + i) * 3 + 2];

      // Calculate Y component
      final int y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
      nv21[yIndex++] = y.clamp(0, 255);

      // Calculate U and V components for even indices
      if (j % 2 == 0 && i % 2 == 0) {
        final int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
        final int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;

        nv21[uvIndex++] = v.clamp(0, 255);
        nv21[uvIndex++] = u.clamp(0, 255);
      }
    }
  }

  return nv21;
}

/// converts the img lib Image to an InputImage suitable for mlkit on Android
/// (nv21. yuv420 also supported apparently, but the format field is ignored)
/// Marks the image as rotated 90 degrees (Frame camera orientation)
InputImage rgbImageToNv21InputImage(img.Image image) {
  final bytes = convertRgbToNv21Bytes(image.buffer.asUint8List(), image.width, image.height);

  final metadata = InputImageMetadata(
      format: InputImageFormat.nv21, // ignored on Android
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: InputImageRotation.rotation90deg,
      bytesPerRow: 0); // ignored on Android

  return InputImage.fromBytes(bytes: bytes, metadata: metadata);
}

/// converts the img lib Image to an InputImage suitable for mlkit on iOS
/// Marks the image as rotated 90 degrees (Frame camera orientation)
InputImage rgbImageToBgra8888InputImage(img.Image image) {
  // add an alpha channel
  var convertedIm = image.convert(numChannels: 4);

  // swap the order of the channels to what InputImage needs
  convertedIm.remapChannels(img.ChannelOrder.bgra);

  return InputImage.fromBytes(bytes: convertedIm.buffer.asUint8List(),
                              metadata: InputImageMetadata(size: Size(image.width.toDouble(), image.height.toDouble()),
                              rotation: InputImageRotation.rotation90deg,
                              format: InputImageFormat.bgra8888,
                              bytesPerRow: image.rowStride));
}
