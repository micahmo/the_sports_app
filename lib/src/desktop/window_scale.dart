import 'package:flutter/widgets.dart';

import '../widgets/match_widgets.dart' show kFrameWidth;

/// Desktop windows wider than the frame scale the whole app up rather than
/// leaving space around it, the way the Roku fills a TV: screens lay out at
/// the frame's width and everything (text, cards, spacing) grows to the
/// window's. Narrower windows lay out as before. Flutter draws at the final
/// size, so text stays sharp.
class WindowScale extends StatelessWidget {
  const WindowScale({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final double s = mq.size.width / kFrameWidth;
    if (s <= 1) return child;
    final Size logical = mq.size / s;
    return FittedBox(
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
      child: SizedBox.fromSize(
        size: logical,
        child: MediaQuery(
          // Everything below sees the smaller logical window, with more device
          // pixels to each logical one (so images and the player's web view
          // render at the window's real resolution).
          data: mq.copyWith(
            size: logical,
            devicePixelRatio: mq.devicePixelRatio * s,
            padding: mq.padding / s,
            viewPadding: mq.viewPadding / s,
            viewInsets: mq.viewInsets / s,
          ),
          child: child,
        ),
      ),
    );
  }
}
