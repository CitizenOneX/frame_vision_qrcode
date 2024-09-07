import 'dart:typed_data';
import 'dart:ui';

import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:image/image.dart' as img;

Uint8List convertRGBToNV21(Uint8List rgb, int width, int height) {
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

Uint8List convertRGBToNV21AndRotate90CCW(Uint8List rgb, int width, int height) {
  final int frameSize = width * height;
  final Uint8List nv21 = Uint8List(frameSize + frameSize ~/ 2);

  int yIndex = 0;
  int uvIndex = frameSize;

  for (int j = 0; j < width; j++) { // Note: Iterate over width first
    for (int i = height - 1; i >= 0; i--) { // Iterate over height in reverse
      final int rgbIndex = (i * width + j) * 3;
      final int r = rgb[rgbIndex];
      final int g = rgb[rgbIndex + 1];
      final int b = rgb[rgbIndex + 2];

      // Calculate Y component
      final int y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
      nv21[yIndex++] = y.clamp(0, 255);

      // Calculate U and V components for even indices (rotated)
      if (j % 2 == 0 && (height - i) % 2 == 0) {
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
/// Marks the image as rotated 90 degrees, as photos from Frame are
InputImage rgbImageToInputImage(img.Image image) {
  final bytes = convertRGBToNV21(image.buffer.asUint8List(), image.width, image.height);

  final metadata = InputImageMetadata(
      format: InputImageFormat.nv21, // ignored on Android
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: InputImageRotation.rotation90deg,
      bytesPerRow: 0); // ignored on Android

  return InputImage.fromBytes(bytes: bytes, metadata: metadata);
}

Uint8List encodeYUV420SP(img.Image image) {
  if (image.numChannels != 4) throw Exception('Image should be in format argb');
  if (!image.hasAlpha || image.buffer.lengthInBytes != (image.width * image.height * 4)) throw Exception('Image should be in format argb');
  if (image.data!.toUint8List().length != (image.width * image.height * 4))  throw Exception('Image should be in format argb');
  print('All looks good to me');

  Uint8List argb = image.data!.toUint8List();
  int width = image.width;
  int height = image.height;

  int ySize = width * height;
  int uvSize = width * height * 2;
  var yuv420sp = List<int>.filled((width * height * 3) ~/ 2, 0);

  final int frameSize = width * height;
  int yIndex = 0;
  int uvIndex = frameSize;

  int a, R, G, B, Y, U, V;
  int index = 0;
  for (int j = 0; j < height; j++) {
    for (int i = 0; i < width; i++) {
      a = (argb[index] & 0xff000000) >> 24; // a is not used obviously
      R = (argb[index] & 0xff0000) >> 16;
      G = (argb[index] & 0xff00) >> 8;
      B = (argb[index] & 0xff) >> 0;

      // well known RGB to YUV algorithm
      Y = ((66 * R + 129 * G + 25 * B + 128) >> 8) + 16;
      U = ((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128;
      V = ((112 * R - 94 * G - 18 * B + 128) >> 8) + 128;

      /* NV21 has a plane of Y and interleaved planes of VU each sampled by a factor of 2
      meaning for every 4 Y pixels there are 1 V and 1 U.
      Note the sampling is every otherpixel AND every other scanline.*/
      yuv420sp[yIndex++] = ((Y < 0) ? 0 : ((Y > 255) ? 255 : Y));
      if (j % 2 == 0 && index % 2 == 0) {
        yuv420sp[uvIndex++] = ((V < 0) ? 0 : ((V > 255) ? 255 : V));
        yuv420sp[uvIndex++] = ((U < 0) ? 0 : ((U > 255) ? 255 : U));
      }
      index++;
    }
  }

  return Uint8List.fromList(yuv420sp);
}

/// converts the img lib Image to an InputImage suitable for mlkit on Android
/// (nv21. yuv420 also supported apparently, but the format field is ignore)
/// Marks the image as rotated 90 degrees, as photos from Frame are
InputImage imgLibImageToInputImage(img.Image image) {
  final bytes = encodeYUV420SP(image);

  final metadata = InputImageMetadata(
      format: InputImageFormat.nv21, // ignored on Android
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: InputImageRotation.rotation90deg,
      bytesPerRow: 0); // ignored on Android

  return InputImage.fromBytes(bytes: bytes, metadata: metadata);
}