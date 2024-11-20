import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:image/image.dart' as img;
import 'package:image_mlkit_converter/image_mlkit_converter.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/text_utils.dart';
import 'package:simple_frame_app/tx/camera_settings.dart';
import 'package:simple_frame_app/rx/photo.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/tx/plain_text.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  // the Google ML Kit barcode scanner
  late BarcodeScanner barcodeScanner;

  // the image and metadata to show
  Image? _image;
  ImageMetadata? _imageMeta;
  List<Barcode> _codesFound = [];

  final Stopwatch _stopwatch = Stopwatch();

  // camera settings
  int _qualityIndex = 2;
  final List<double> _qualityValues = [10, 25, 50, 100];
  int _meteringIndex = 2;
  final List<String> _meteringValues = ['SPOT', 'CENTER_WEIGHTED', 'AVERAGE'];
  int _autoExpGainTimes = 2; // val >= 0; number of times auto exposure and gain algorithm will be run (every 100ms)
  final int _autoExpInterval = 100; // 0<= val <= 255; sleep time between runs of the autoexposure algorithm
  double _exposure = 0.18; // 0.0 <= val <= 1.0
  double _exposureSpeed = 0.5;  // 0.0 <= val <= 1.0
  int _shutterLimit = 16383; // 4 < val < 16383
  int _analogGainLimit = 1;     // 0 <= val <= 248 (actually firmware requires 1.0 <= val <= 248.0)
  double _whiteBalanceSpeed = 0.5;  // 0.0 <= val <= 1.0

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
    _codesFound.clear();
    await frame!.sendMessage(TxPlainText(msgCode: 0x12, text: ' '));

    // keep looping, taking photos and displaying, until user clicks cancel
    while (currentState == ApplicationState.running) {

      try {
        // the image metadata (camera settings) to show under the image
        ImageMetadata meta = ImageMetadata(_qualityValues[_qualityIndex].toInt(), _autoExpGainTimes, _meteringValues[_meteringIndex], _exposure, _exposureSpeed, _shutterLimit, _analogGainLimit, _whiteBalanceSpeed);

        // send the lua command to request a photo from the Frame
        _stopwatch.reset();
        _stopwatch.start();

        var txcs = TxCameraSettings(
          msgCode: 0x0d,
          qualityIndex: _qualityIndex,
          autoExpGainTimes: _autoExpGainTimes,
          autoExpInterval: _autoExpInterval,
          meteringIndex: _meteringIndex,
          exposure: _exposure,
          exposureSpeed: _exposureSpeed,
          shutterLimit: _shutterLimit,
          analogGainLimit: _analogGainLimit,
          whiteBalanceSpeed: _whiteBalanceSpeed,
        );

        await frame!.sendMessage(txcs);

        // synchronously await the image response
        Uint8List imageData = await RxPhoto(qualityLevel: _qualityValues[_qualityIndex].toInt()).attach(frame!.dataResponse).first;
        _stopwatch.stop();

        // received a whole-image Uint8List with jpeg header and footer included
        // note: the image from the Frame camera is rotated clockwise 90 degrees.
        // Some vision apps will be affected by this, so in those cases either pass in orientation metadata
        // or rotate the image data back to upright.
        // MLKit accepts orientation metadata in its InputImage constructor, so we save time by not needing to bake in a rotation.

        // Widget UI
        Image imWidget = Image.memory(imageData, gaplessPlayback: true,);

        // add the size and elapsed time to the image metadata widget
        meta.size = imageData.length;
        meta.elapsedTimeMs = _stopwatch.elapsedMilliseconds;

        _log.fine(() => 'Image file size in bytes: ${imageData.length}, elapsedMs: ${_stopwatch.elapsedMilliseconds}');

        setState(() {
          _image = imWidget;
          _imageMeta = meta;
        });

        // Perform vision processing pipeline
        try {
          // will sometimes throw an Exception on decoding, but doesn't return null
          _stopwatch.reset();
          _stopwatch.start();
          img.Image im = img.decodeJpg(imageData)!;
          _stopwatch.stop();
          _log.fine(() => 'Jpeg decoding took: ${_stopwatch.elapsedMilliseconds} ms');

          // Android mlkit needs NV21 InputImage format
          // iOS mlkit needs bgra8888 InputImage format
          // In both cases orientation metadata is passed to mlkit, so no need to bake in a rotation
          _stopwatch.reset();
          _stopwatch.start();
          // Frame images are rotated 90 degrees clockwise
          InputImage mlkitImage = ImageMlkitConverter.imageToMlkitInputImage(im, InputImageRotation.rotation90deg);
          _stopwatch.stop();
          _log.fine(() => 'NV21/BGRA8888 conversion took: ${_stopwatch.elapsedMilliseconds} ms');

          // run the qrcode/barcode detector
          _stopwatch.reset();
          _stopwatch.start();
          _codesFound = await barcodeScanner.processImage(mlkitImage);
          _stopwatch.stop();
          _log.fine(() => 'Barcode scanning took: ${_stopwatch.elapsedMilliseconds} ms');

          // stop the running loop if a barcode has been found
          if (_codesFound.isNotEmpty) {

            List<String> frameText = [];
            // loop over any codes found
            for (Barcode barcode in _codesFound) {

              if (barcode.type case BarcodeType.url) {
                final barcodeUrl = barcode.value as BarcodeUrl;
                frameText.add('${barcode.type.name}: ${barcodeUrl.url}');
              }
              else {
                frameText.add('${barcode.type.name}: ${barcode.displayValue}');
              }
            }

            _log.fine(() => 'Codes found: $frameText');

            // print the detected barcodes on the Frame display
            await frame!.sendMessage(
              TxPlainText(
                msgCode: 0x12,
                text: TextUtils.wrapText(frameText.join('\n'), 640, 4).join('\n')
              )
            );

            setState(() {
              currentState = ApplicationState.canceling;
            });

            break;
          }

        } catch (e) {
          _log.severe('Error converting bytes to image: $e');
        }

      } catch (e) {
        _log.severe('Error executing application: $e');
      }
    }

    // clean up the barcode Scanner resources
    await barcodeScanner.close();

    setState(() {
      currentState = ApplicationState.ready;
    });
  }

  /// cancel the current photo
  @override
  Future<void> cancel() async {
    currentState = ApplicationState.canceling;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame QRcode/Barcode Reader',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Frame QRcode/Barcode Reader'),
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
                title: const Text('Metering'),
                subtitle: DropdownButton<int>(
                  value: _meteringIndex,
                  onChanged: (int? newValue) {
                    setState(() {
                      _meteringIndex = newValue!;
                    });
                  },
                  items: _meteringValues
                      .map<DropdownMenuItem<int>>((String value) {
                    return DropdownMenuItem<int>(
                      value: _meteringValues.indexOf(value),
                      child: Text(value),
                    );
                  }).toList(),
                ),
              ),
              ListTile(
                title: const Text('Exposure'),
                subtitle: Slider(
                  value: _exposure,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: _exposure.toString(),
                  onChanged: (value) {
                    setState(() {
                      _exposure = value;
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('Exposure Speed'),
                subtitle: Slider(
                  value: _exposureSpeed,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: _exposureSpeed.toString(),
                  onChanged: (value) {
                    setState(() {
                      _exposureSpeed = value;
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
                title: const Text('Analog Gain Limit'),
                subtitle: Slider(
                  value: _analogGainLimit.toDouble(),
                  min: 0,
                  max: 248,
                  divisions: 8,
                  label: _analogGainLimit.toStringAsFixed(0),
                  onChanged: (value) {
                    setState(() {
                      _analogGainLimit = value.toInt();
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('White Balance Speed'),
                subtitle: Slider(
                  value: _whiteBalanceSpeed,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: _whiteBalanceSpeed.toString(),
                  onChanged: (value) {
                    setState(() {
                      _whiteBalanceSpeed = value;
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
                mainAxisSize: MainAxisSize.min,
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
            Expanded(
              child: ListView.builder(
                itemCount: _codesFound.length,
                itemBuilder:(context, index) {
                  if (_codesFound[index].type == BarcodeType.url) {
                    // url: display clickable link to open URL on phone in browser
                    var barcodeUrl = _codesFound[index].value! as BarcodeUrl;
                    return ListTile(
                      onTap: () {
                        launchUrl(Uri.parse(barcodeUrl.url!));
                      },
                      title: Text(barcodeUrl.url!, style: const TextStyle(decoration: TextDecoration.underline),),
                      subtitle: Text(_codesFound[index].type.name),
                    );
                  }
                  else {
                    return ListTile(
                      title: Text(_codesFound[index].displayValue ?? ''),
                      subtitle: Text(_codesFound[index].type.name)
                    );
                  }
                }
              ),
            ),
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
  final String metering;
  final double exposure;
  final double exposureSpeed;
  final int shutterLimit;
  final int analogGainLimit;
  final double whiteBalanceSpeed;

  ImageMetadata(this.quality, this.exposureRuns, this.metering, this.exposure, this.exposureSpeed, this.shutterLimit, this.analogGainLimit, this.whiteBalanceSpeed, {super.key});

  late int size;
  late int elapsedTimeMs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('Quality: $quality\nExposureRuns: $exposureRuns\nMetering: $metering\nExposure: $exposure'),
        const Spacer(),
        Text('ExposureSpeed: $exposureSpeed\nShutterLim: $shutterLimit\nAnalogGainLim: $analogGainLimit\nWBSpeed: $whiteBalanceSpeed'),
        const Spacer(),
        Text('Size: ${(size/1024).toStringAsFixed(1)} kb\nTime: $elapsedTimeMs ms'),
      ],
    );
  }
}