import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:image/image.dart' as img;
import 'package:image_mlkit_converter/image_mlkit_converter.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/text_utils.dart';
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

class MainAppState extends State<MainApp> with SimpleFrameAppState, FrameVisionAppState {
  // the Google ML Kit barcode scanner
  late BarcodeScanner _barcodeScanner;

  // the image and metadata to show
  Image? _image;
  ImageMetadata? _imageMeta;
  bool _processing = false;
  List<Barcode> _codesFound = [];

  final Stopwatch _stopwatch = Stopwatch();

  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });

    // initialize the BarcodeScanner
    _barcodeScanner = BarcodeScanner(formats: [BarcodeFormat.all]);
  }

  @override
  void dispose() async {
    // clean up the barcode Scanner resources
    await _barcodeScanner.close();

    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    // kick off the connection to Frame and start the app if possible
    tryScanAndConnectAndStart(andRun: true);
  }

  @override
  Future<void> printInstructions() async {
    await frame!.sendMessage(
      TxPlainText(
        msgCode: 0x0a,
        text: '3-Tap: take photo'
      )
    );
  }

  @override
  Future<void> tapHandler(int taps) async {
    switch (taps) {
      case 1:
        // next
        break;
      case 2:
        // prev
        break;
      case 3:
        // check if there's processing in progress already and drop the request if so
        if (!_processing) {
          _processing = true;
          // start new vision capture
          // asynchronously kick off the capture/processing pipeline
          capture().then(process);
        }
        break;
      default:
    }
  }

  /// The vision pipeline to run when a photo is captured
  FutureOr<void> process((Uint8List, ImageMetadata) photo) async {
    var imageData = photo.$1;
    var meta = photo.$2;

    try {
      // update Widget UI
      // For the widget we rotate it upon display with a transform, not changing the source image
      Image im = Image.memory(imageData, gaplessPlayback: true,);

      setState(() {
        _image = im;
        _imageMeta = meta;
      });

      // Perform vision processing pipeline on the current image
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

        // run the text recognizer
        _stopwatch.reset();
        _stopwatch.start();
        _codesFound = await _barcodeScanner.processImage(mlkitImage);
        _stopwatch.stop();
        _log.fine(() => 'Barcode scanning took: ${_stopwatch.elapsedMilliseconds} ms');

        // display to Frame if a barcode has been found
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
              msgCode: 0x0a,
              text: TextUtils.wrapText(frameText.join('\n'), 640, 4).join('\n')
            )
          );
        }

      } catch (e) {
        _log.severe('Error converting bytes to image: $e');
      }

      // indicate that we're done processing
      _processing = false;

    } catch (e) {
      _log.severe('Error processing photo: $e');
      // TODO rethrow;?
    }
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
        drawer: getCameraDrawer(),
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
