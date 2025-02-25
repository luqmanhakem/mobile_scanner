import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'mobile_scanner_arguments.dart';
import 'objects/barcode_utility.dart';

/// The facing of a camera.
enum CameraFacing {
  /// Front facing camera.
  front,

  /// Back facing camera.
  back,
}

enum MobileScannerState { undetermined, authorized, denied }

/// The state of torch.
enum TorchState {
  /// Torch is off.
  off,

  /// Torch is on.
  on,
}

enum AnalyzeMode { none, barcode }

class MobileScannerController {
  MethodChannel methodChannel =
      const MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
  EventChannel eventChannel =
      const EventChannel('dev.steenbakker.mobile_scanner/scanner/event');

  int? _controllerHashcode;
  StreamSubscription? events;

  final ValueNotifier<MobileScannerArguments?> args = ValueNotifier(null);
  final ValueNotifier<TorchState> torchState = ValueNotifier(TorchState.off);
  late final ValueNotifier<CameraFacing> cameraFacingState;
  final Ratio? ratio;
  final bool? torchEnabled;

  CameraFacing facing;
  bool hasTorch = false;
  late StreamController<Barcode> barcodesController;

  Stream<Barcode> get barcodes => barcodesController.stream;

  MobileScannerController(
      {this.facing = CameraFacing.back, this.ratio, this.torchEnabled}) {
    // In case a new instance is created before calling dispose()
    if (_controllerHashcode != null) {
      stop();
    }
    _controllerHashcode = hashCode;

    cameraFacingState = ValueNotifier(facing);

    // Sets analyze mode and barcode stream
    barcodesController = StreamController.broadcast(
      onListen: () => setAnalyzeMode(AnalyzeMode.barcode.index),
      onCancel: () => setAnalyzeMode(AnalyzeMode.none.index),
    );

    start();

    // Listen to events from the platform specific code
    events = eventChannel
        .receiveBroadcastStream()
        .listen((data) => handleEvent(data));
  }

  void handleEvent(Map<dynamic, dynamic> event) {
    final name = event['name'];
    final data = event['data'];
    switch (name) {
      case 'torchState':
        final state = TorchState.values[data];
        torchState.value = state;
        break;
      case 'barcode':
        final barcode = Barcode.fromNative(data);
        barcodesController.add(barcode);
        break;
      case 'barcodeMac':
        barcodesController.add(Barcode(rawValue: data['payload']));
        break;
      default:
        throw UnimplementedError();
    }
  }

  void setAnalyzeMode(int mode) {
    if (hashCode != _controllerHashcode) {
      return;
    }
    methodChannel.invokeMethod('analyze', mode);
  }

  // List<BarcodeFormats>? formats = _defaultBarcodeFormats,
  /// Start barcode scanning. This will first check if the required permissions
  /// are set.
  Future<void> start() async {
    ensure('startAsync');

    setAnalyzeMode(AnalyzeMode.barcode.index);
    // Check authorization status
    MobileScannerState state =
        MobileScannerState.values[await methodChannel.invokeMethod('state')];
    switch (state) {
      case MobileScannerState.undetermined:
        final bool result = await methodChannel.invokeMethod('request');
        state =
            result ? MobileScannerState.authorized : MobileScannerState.denied;
        break;
      case MobileScannerState.denied:
        throw PlatformException(code: 'NO ACCESS');
      case MobileScannerState.authorized:
        break;
    }

    cameraFacingState.value = facing;

    // Set the starting arguments for the camera
    Map arguments = {};
    arguments['facing'] = facing.index;
    if (ratio != null) arguments['ratio'] = ratio;
    if (torchEnabled != null) arguments['torch'] = torchEnabled;

    // Start the camera with arguments
    final Map<String, dynamic>? startResult = await methodChannel
        .invokeMapMethod<String, dynamic>('start', arguments);

    if (startResult == null) {
      throw PlatformException(code: 'INITIALIZATION ERROR');
    }

    hasTorch = startResult['torchable'];
    args.value = MobileScannerArguments(
        textureId: startResult['textureId'],
        size: toSize(startResult['size']),
        hasTorch: hasTorch);
  }

  Future<void> stop() async => await methodChannel.invokeMethod('stop');

  /// Switches the torch on or off.
  ///
  /// Only works if torch is available.
  void toggleTorch() {
    ensure('toggleTorch');
    if (!hasTorch) return;
    TorchState state =
        torchState.value == TorchState.off ? TorchState.on : TorchState.off;
    methodChannel.invokeMethod('torch', state.index);
  }

  /// Switches the torch on or off.
  ///
  /// Only works if torch is available.
  Future<void> switchCamera() async {
    ensure('switchCamera');
    await stop();
    facing =
        facing == CameraFacing.back ? CameraFacing.front : CameraFacing.back;
    start();
  }

  /// Disposes the controller and closes all listeners.
  void dispose() {
    if (hashCode == _controllerHashcode) {
      stop();
      events?.cancel();
      events = null;
      _controllerHashcode = null;
    }
    barcodesController.close();
  }

  /// Checks if the controller is bound to the correct MobileScanner object.
  void ensure(String name) {
    final message =
        'CameraController.$name called after CameraController.dispose\n'
        'CameraController methods should not be used after calling dispose.';
    assert(hashCode == _controllerHashcode, message);
  }
}
