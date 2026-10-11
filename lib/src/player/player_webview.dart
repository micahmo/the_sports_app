import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_win_floating/webview_win_floating.dart';

/// The one web view the stream player needs, on whichever platform we are,
/// through `webview_flutter`: Android's own, and on Windows WebView2 through
/// `webview_win_floating`.
///
/// On Windows that's a real WebView2 window floating over the app rather than
/// one copied into a Flutter texture (`webview_windows`, until 1.0.115): the
/// copy wasn't in step with the video, so 60 fps never looked smooth (the same
/// game in Firefox was "night and day", 2026-10-11). The cost: Flutter can't
/// draw over it, so the player's overlays are drawn by the page itself on
/// Windows (see the player's _overlay()).
///
/// Pages talk back through a JavaScript channel named `AppPlayer`, with a
/// `postMessage(String)` method.
abstract class PlayerWebView {
  factory PlayerWebView({
    required Uri url,
    required bool Function(Uri) isAllowed,
    required void Function(String) onMessage,
    required VoidCallback onPageStarted,
    required VoidCallback onPageFinished,
  }) {
    return _FlutterPlayerWebView(_Callbacks(url, isAllowed, onMessage, onPageStarted, onPageFinished));
  }

  Widget build(BuildContext context);

  Future<void> runJavaScript(String js);

  /// The script's result: a bool, number or string (strings may still carry
  /// their JSON quotes on Android).
  Future<Object?> runJavaScriptReturningResult(String js);

  Future<void> reload();

  /// Play another page in the same view (switching streams in place).
  Future<void> load(Uri url);

  void dispose();
}

class _Callbacks {
  _Callbacks(this.url, this.isAllowed, this.onMessage, this.onPageStarted, this.onPageFinished);
  // The page being shown: where an off-site navigation is sent back to.
  Uri url;
  final bool Function(Uri) isAllowed;
  final void Function(String) onMessage;
  final VoidCallback onPageStarted;
  final VoidCallback onPageFinished;
}

class _FlutterPlayerWebView implements PlayerWebView {
  _FlutterPlayerWebView(this._cb) {
    const PlatformWebViewControllerCreationParams params = PlatformWebViewControllerCreationParams();
    _controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('AppPlayer', onMessageReceived: (JavaScriptMessage m) => _cb.onMessage(m.message))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => _cb.onPageStarted(),
          onPageFinished: (_) => _cb.onPageFinished(),
          // Ads open new windows and leave the site; nothing we want does.
          onNavigationRequest: (NavigationRequest req) => _cb.isAllowed(Uri.parse(req.url)) ? NavigationDecision.navigate : NavigationDecision.prevent,
          onUrlChange: (UrlChange change) {
            final String? u = change.url;
            if (u != null && !_cb.isAllowed(Uri.parse(u))) _controller.loadRequest(_cb.url);
          },
        ),
      );

    if (_controller.platform is AndroidWebViewController) {
      (_controller.platform as AndroidWebViewController).setMediaPlaybackRequiresUserGesture(false);
    }

    // WebView2's status bubble (a link's address, bottom left) has nothing to
    // say over a video.
    _win?.setStatusBar(false);

    _controller.loadRequest(_cb.url);
  }

  final _Callbacks _cb;
  late final WebViewController _controller;

  // The native window on Windows; null elsewhere.
  WinWebViewController? get _win {
    final Object p = _controller.platform;
    return p is WindowsPlatformWebViewController ? p.controller : null;
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);

  @override
  Future<void> runJavaScript(String js) => _controller.runJavaScript(js);

  @override
  Future<Object?> runJavaScriptReturningResult(String js) => _controller.runJavaScriptReturningResult(js);

  @override
  Future<void> reload() => _controller.reload();

  @override
  Future<void> load(Uri url) {
    _cb.url = url;
    return _controller.loadRequest(url);
  }

  @override
  void dispose() {
    // Leaving the player only hides a native window: close it, or the stream
    // plays on, sound and all, until it's garbage-collected.
    _win?.dispose();
  }
}
