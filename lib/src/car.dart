import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the app is on a car's screen (Android Auto), where it's always
/// dark and fullscreen. Android Auto runs the app's own screen on the car's
/// display, and it moves between the phone and the car without restarting.
final ValueNotifier<bool> onCarScreen = ValueNotifier<bool>(false);

const MethodChannel _channel = MethodChannel('car');

Future<void> loadCarScreen() async {
  if (!Platform.isAndroid) return;
  _channel.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'onCarChanged' || call.method == 'attached') _set(call.arguments == true);
  });
  try {
    _set(await _channel.invokeMethod<bool>('isOnCar') ?? false);
  } on PlatformException {
    // Older builds without the channel: the phone.
  }
}

void _set(bool car) {
  onCarScreen.value = car;
  applySystemUi();
}

/// On a car's screen, fullscreen: Android Auto's own bar (back, apps) sat over
/// the bottom of the video, and doubled the app's back buttons. Each screen
/// has the app's own back instead (Home's leaves the app); a swipe from the
/// edge still shows Android Auto's bar. On the phone, edge to edge as before.
/// Applied again whenever the app moves, since each move is a new window.
void applySystemUi() {
  if (!Platform.isAndroid) return;
  SystemChrome.setEnabledSystemUIMode(onCarScreen.value ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
}
