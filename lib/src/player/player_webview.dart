import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_windows/webview_windows.dart' as win;

/// The one web view the stream player needs, on whichever platform we are.
/// `webview_flutter` has no Windows implementation, so Windows gets WebView2
/// through `webview_windows`; everything else keeps `webview_flutter`.
///
/// Pages talk back through a JavaScript object named `AppPlayer` with a
/// `postMessage(String)` method, the way `webview_flutter` channels work.
abstract class PlayerWebView {
  factory PlayerWebView({
    required Uri url,
    required bool Function(Uri) isAllowed,
    required void Function(String) onMessage,
    required VoidCallback onPageStarted,
    required VoidCallback onPageFinished,
  }) {
    final _Callbacks cb = _Callbacks(url, isAllowed, onMessage, onPageStarted, onPageFinished);
    return Platform.isWindows ? _WindowsPlayerWebView(cb) : _FlutterPlayerWebView(cb);
  }

  Widget build(BuildContext context);

  Future<void> runJavaScript(String js);

  /// The script's result: a bool, number or string (strings may still carry
  /// their JSON quotes on Android).
  Future<Object?> runJavaScriptReturningResult(String js);

  Future<void> reload();

  void dispose();
}

class _Callbacks {
  _Callbacks(this.url, this.isAllowed, this.onMessage, this.onPageStarted, this.onPageFinished);
  final Uri url;
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

    _controller.loadRequest(_cb.url);
  }

  final _Callbacks _cb;
  late final WebViewController _controller;

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);

  @override
  Future<void> runJavaScript(String js) => _controller.runJavaScript(js);

  @override
  Future<Object?> runJavaScriptReturningResult(String js) => _controller.runJavaScriptReturningResult(js);

  @override
  Future<void> reload() => _controller.reload();

  @override
  void dispose() {}
}

class _WindowsPlayerWebView implements PlayerWebView {
  _WindowsPlayerWebView(this._cb) {
    _init();
  }

  final _Callbacks _cb;
  final win.WebviewController _controller = win.WebviewController();
  final ValueNotifier<bool> _initialized = ValueNotifier<bool>(false);
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];
  bool _disposed = false;

  // WebView2's environment is per process and can only be set up once.
  static Future<void>? _environment;

  // Gives every document the same `AppPlayer.postMessage` that webview_flutter's
  // channel provides, backed by WebView2's own message port.
  static const String _bridgeJs = '''
window.AppPlayer = { postMessage: function (m) { try { window.chrome.webview.postMessage(String(m)); } catch (e) {} } };
''';

  Future<void> _init() async {
    // Chromium refuses to autoplay with sound until the page itself is
    // clicked, and the user's click lands on Flutter rather than the page.
    _environment ??= win.WebviewController.initializeEnvironment(additionalArguments: '--autoplay-policy=no-user-gesture-required').catchError((_) {});
    await _environment;
    await _controller.initialize();
    if (_disposed) return;

    await _controller.setBackgroundColor(Colors.black);
    // Ads open new windows; nothing we want lives in one.
    await _controller.setPopupWindowPolicy(win.WebviewPopupWindowPolicy.deny);
    await _controller.addScriptToExecuteOnDocumentCreated(_bridgeJs);

    _subs.add(_controller.webMessage.listen((dynamic m) => _cb.onMessage('$m'), onError: (_) {}));
    _subs.add(
      _controller.loadingState.listen((win.LoadingState s) {
        if (s == win.LoadingState.loading) _cb.onPageStarted();
        if (s == win.LoadingState.navigationCompleted) _cb.onPageFinished();
      }),
    );
    // WebView2 navigations cannot be vetoed from here, so undo them instead,
    // as onUrlChange does on Android.
    _subs.add(
      _controller.url.listen((String u) {
        final Uri? dest = Uri.tryParse(u);
        // about:blank and the like come and go while loading; only real pages count.
        final bool web = dest != null && (dest.isScheme('http') || dest.isScheme('https'));
        if (web && !_cb.isAllowed(dest)) _controller.loadUrl(_cb.url.toString());
      }),
    );

    await _controller.loadUrl(_cb.url.toString());
    if (!_disposed) _initialized.value = true;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _initialized,
      builder: (BuildContext _, bool ready, Widget? __) => ready ? win.Webview(_controller) : const SizedBox.expand(),
    );
  }

  @override
  Future<void> runJavaScript(String js) async {
    if (_initialized.value) await _controller.executeScript(js);
  }

  @override
  Future<Object?> runJavaScriptReturningResult(String js) async {
    return _initialized.value ? await _controller.executeScript(js) : null;
  }

  @override
  Future<void> reload() async {
    if (_initialized.value) await _controller.reload();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final StreamSubscription<dynamic> s in _subs) {
      s.cancel();
    }
    _controller.dispose();
    _initialized.dispose();
  }
}
