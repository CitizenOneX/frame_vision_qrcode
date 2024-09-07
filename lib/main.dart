import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert_native_img_stream/convert_native_img_stream.dart' as convert_native;
import 'package:flutter/material.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';

import 'camera.dart';
import 'image_data_response.dart';
import 'mlkit_image_converter.dart';
import 'simple_frame_app.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  late BarcodeScanner barcodeScanner;

  // the image and metadata to show
  Image? _image;
  ImageMetadata? _imageMeta;
  final Stopwatch _stopwatch = Stopwatch();

  // camera settings
  int _qualityIndex = 2;
  final List<double> _qualityValues = [10, 25, 50, 100];
  double _exposure = 0.0; // -2.0 <= val <= 2.0
  int _meteringModeIndex = 0;
  final List<String> _meteringModeValues = ['SPOT', 'CENTER_WEIGHTED', 'AVERAGE'];
  int _autoExpGainTimes = 0; // val >= 0; number of times auto exposure and gain algorithm will be run every 100ms
  double _shutterKp = 0.1;  // val >= 0 (we offer 0.1 .. 0.5)
  int _shutterLimit = 6000; // 4 < val < 16383
  double _gainKp = 1.0;     // val >= 0 (we offer 1.0 .. 5.0)
  int _gainLimit = 248;     // 0 <= val <= 248

  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });
  }

  @override
  Future<void> run() async {
    currentState = ApplicationState.running;
    if (mounted) setState(() {});

    // set up the Barcode Scanner
    final List<BarcodeFormat> formats = [BarcodeFormat.all];
    final barcodeScanner = BarcodeScanner(formats: formats);

    // keep looping, taking photos and displaying, until user clicks cancel
    while (currentState == ApplicationState.running) {

      try {
        // the image metadata (camera settings) to show under the image
        ImageMetadata meta = ImageMetadata(_qualityValues[_qualityIndex].toInt(), _autoExpGainTimes, _meteringModeValues[_meteringModeIndex], _exposure, _shutterKp, _shutterLimit, _gainKp, _gainLimit);

        // send the lua command to request a photo from the Frame
        _stopwatch.reset();
        _stopwatch.start();
        await frame!.sendDataRaw(CameraSettingsMsg.pack(_qualityIndex, _autoExpGainTimes, _meteringModeIndex, _exposure, _shutterKp, _shutterLimit, _gainKp, _gainLimit));

        // synchronously await the image response
        Uint8List imageData = await imageDataResponse(frame!.dataResponse, _qualityValues[_qualityIndex].toInt()).first;
        _stopwatch.stop();

        // received a whole-image Uint8List with jpeg header and footer included
        // note: the image from the Frame camera is rotated clockwise 90 degrees. The barcode/qrcode scanner might be
        // one of the few vision apps that are not affected by this, so for now don't rotate the image as a preprocessing step

        try {
          img.Image? im = img.decodeJpg(imageData);
          _log.info('Image after decode from jpg: $im');

          if (im == null) {
            _log.severe('Unable to decode jpg');
            continue;
          }

          InputImage mlkitImage;

          if (Platform.isAndroid) {
            // Android mlkit needs NV21 InputImage format
            // this function wants an img.Image with rgb-formatted uint8 pixels, in Frame camera orientation (i.e. rotated 90 degrees clockwise) - mlkit will reverse the rotation
            mlkitImage = rgbImageToInputImage(im);
            _log.info('Image converted to mlkit InputImage: ${mlkitImage.metadata!.size}');
          }
          else {
            // iOS mlkit needs bgra8888 InputImage format
            // TODO untested

            // add in the alpha channel
            var convertedIm = im.convert(numChannels: 4);

            // swap the order of the channels to what InputImage needs
            convertedIm.remapChannels(img.ChannelOrder.bgra);

            // convert to mlkit's preferred image format for iOS
            mlkitImage = InputImage.fromBytes(
                                  bytes: convertedIm.buffer.asUint8List(),
                                  metadata: InputImageMetadata(size: const Size(512, 512),
                                  rotation: InputImageRotation.rotation90deg,
                                  format: InputImageFormat.bgra8888,
                                  bytesPerRow: 512*4));
          }

          _log.info('About to process the image');
          final List<Barcode> barcodes = await barcodeScanner.processImage(mlkitImage);

          for (Barcode barcode in barcodes) {
            _log.info('Barcode found: ${barcode.type.name} ${barcode.displayValue} ${barcode.rawValue}');

            final BarcodeType type = barcode.type;
            final Rect boundingBox = barcode.boundingBox;
            final String? displayValue = barcode.displayValue;
            final String? rawValue = barcode.rawValue;

            // See API reference for complete list of supported types
            if (type case BarcodeType.url) {
              final barcodeUrl = barcode.value as BarcodeUrl;
              _log.info('Barcode URL: ${barcodeUrl.title} ${barcodeUrl.url}');
              // TODO print URL on Frame and ListView
              // open URL on phone in browser
              break;
            }
            else {
              // just print data on Frame, in ListView
            }
          }

          // Widget UI
          //Image imWidget = Image.memory(imageData, gaplessPlayback: true,);
          // TODO, for now convert it back to make sure our nv21 looks good
          var nv21 = convert_native.ConvertNativeImgStream();
          _log.info('MLKit Image Bytes: ${mlkitImage.bytes!.length}');
          Uint8List reconstructedJpg = (await nv21.convertImgToBytes(mlkitImage.bytes!, 512, 512, rotationFix: 0))!;
          _log.info('Reconstructed Image Bytes: ${reconstructedJpg.length}');

          var reconstructedImg = img.decodeJpg(reconstructedJpg);
          _log.info('Reconstructed Image: $reconstructedImg');

          Image imWidget = Image.memory(reconstructedJpg, gaplessPlayback: true,);

          // add the size and elapsed time to the image metadata widget
          meta.size = imageData.length;
          meta.elapsedTimeMs = _stopwatch.elapsedMilliseconds;

          _log.fine('Image file size in bytes: ${imageData.length}, elapsedMs: ${_stopwatch.elapsedMilliseconds}');

          setState(() {
            _image = imWidget;
            _imageMeta = meta;
          });

          // Perform vision processing pipeline

        } catch (e) {
          _log.severe('Error converting bytes to image: $e');
        }

      } catch (e) {
        _log.severe('Error executing application: $e');
      }
    }

    // clean up the barcode Scanner resources
    barcodeScanner.close();
  }

  /// cancel the current photo
  @override
  Future<void> cancel() async {
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Vision',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Frame Vision"),
          actions: [getBatteryWidget()]
        ),
        drawer: Drawer(
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              const DrawerHeader(
                decoration: BoxDecoration(
                  color: Colors.blue,
                ),
                child: Text('Camera Settings',
                  style: TextStyle(color: Colors.white, fontSize: 24),
                  ),
              ),
              ListTile(
                title: const Text('Quality'),
                subtitle: Slider(
                  value: _qualityIndex.toDouble(),
                  min: 0,
                  max: _qualityValues.length - 1,
                  divisions: _qualityValues.length - 1,
                  label: _qualityValues[_qualityIndex].toString(),
                  onChanged: (value) {
                    setState(() {
                      _qualityIndex = value.toInt();
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('Auto Exposure/Gain Runs'),
                subtitle: Slider(
                  value: _autoExpGainTimes.toDouble(),
                  min: 0,
                  max: 10,
                  divisions: 10,
                  label: _autoExpGainTimes.toInt().toString(),
                  onChanged: (value) {
                    setState(() {
                      _autoExpGainTimes = value.toInt();
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('Metering Mode'),
                subtitle: DropdownButton<int>(
                  value: _meteringModeIndex,
                  onChanged: (int? newValue) {
                    setState(() {
                      _meteringModeIndex = newValue!;
                    });
                  },
                  items: _meteringModeValues
                      .map<DropdownMenuItem<int>>((String value) {
                    return DropdownMenuItem<int>(
                      value: _meteringModeValues.indexOf(value),
                      child: Text(value),
                    );
                  }).toList(),
                ),
              ),
              ListTile(
                title: const Text('Exposure'),
                subtitle: Slider(
                  value: _exposure,
                  min: -2,
                  max: 2,
                  divisions: 8,
                  label: _exposure.toString(),
                  onChanged: (value) {
                    setState(() {
                      _exposure = value;
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('Shutter KP'),
                subtitle: Slider(
                  value: _shutterKp,
                  min: 0.1,
                  max: 0.5,
                  divisions: 4,
                  label: _shutterKp.toStringAsFixed(1),
                  onChanged: (value) {
                    setState(() {
                      _shutterKp = value;
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('Shutter Limit'),
                subtitle: Slider(
                  value: _shutterLimit.toDouble(),
                  min: 4,
                  max: 16383,
                  divisions: 10,
                  label: _shutterLimit.toStringAsFixed(0),
                  onChanged: (value) {
                    setState(() {
                      _shutterLimit = value.toInt();
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('Gain KP'),
                subtitle: Slider(
                  value: _gainKp,
                  min: 1.0,
                  max: 5.0,
                  divisions: 4,
                  label: _gainKp.toStringAsFixed(1),
                  onChanged: (value) {
                    setState(() {
                      _gainKp = value;
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('Gain Limit'),
                subtitle: Slider(
                  value: _gainLimit.toDouble(),
                  min: 0,
                  max: 248,
                  divisions: 8,
                  label: _gainLimit.toStringAsFixed(0),
                  onChanged: (value) {
                    setState(() {
                      _gainLimit = value.toInt();
                    });
                  },
                ),
              ),
            ],
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  Transform(
                    alignment: Alignment.center,
                    // images are rotated 90 degrees clockwise from the Frame
                    // so reverse that for display
                    transform: Matrix4.rotationZ(-pi*0.5),
                    child: _image,
                  ),
                  const Divider(),
                  if (_imageMeta != null) _imageMeta!,
                ],
              )
            ),
            const Divider(),
          ],
        ),
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.camera_alt), const Icon(Icons.cancel)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}

class ImageMetadata extends StatelessWidget {
  final int quality;
  final int exposureRuns;
  final String meteringMode;
  final double exposure;
  final double shutterKp;
  final int shutterLimit;
  final double gainKp;
  final int gainLimit;

  ImageMetadata(this.quality, this.exposureRuns, this.meteringMode, this.exposure, this.shutterKp, this.shutterLimit, this.gainKp, this.gainLimit, {super.key});

  late int size;
  late int elapsedTimeMs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('Quality: $quality\nExposureRuns: $exposureRuns\nMeteringMode: $meteringMode\nExposure: $exposure'),
        const Spacer(),
        Text('ShutterKp: $shutterKp\nShutterLim: $shutterLimit\nGainKp: $gainKp\nGainLim: $gainLimit'),
        const Spacer(),
        Text('Size: ${(size/1024).toStringAsFixed(1)} kb\nTime: $elapsedTimeMs ms'),
      ],
    );
  }
}