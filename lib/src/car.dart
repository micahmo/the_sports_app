import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the app is on a car's screen (Android Auto), where it's always
/// dark. Android Auto runs the app's own screen on the car's display, and it
/// moves between the phone and the car without restarting.
final ValueNotifier<bool> onCarScreen = ValueNotifier<bool>(false);

const MethodChannel _channel = MethodChannel('car');

Future<void> loadCarScreen() async {
  if (!Platform.isAndroid) return;
  _channel.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'onCarChanged' || call.method == 'attached') onCarScreen.value = call.arguments == true;
  });
  try {
    onCarScreen.value = await _channel.invokeMethod<bool>('isOnCar') ?? false;
  } on PlatformException {
    // Older builds without the channel: the phone.
  }
}
