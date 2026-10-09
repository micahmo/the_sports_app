import 'package:flutter/material.dart';

import '../api/models.dart';
import '../generated/app_data.dart' show AppPalette, PlayerIcons, PlayerText, PlayerTuning;
import '../theme.dart';
import '../widgets/match_widgets.dart';
import 'recents.dart';
import 'stream_quality.dart';

// The player's streams row: this game's other streams on the left, recent games
// on the right, opened from the Streams pill (see DESIGN_NOTES, "Streams row").
// Always drawn over video, so always in the dark theme's colours.

const double _cardWidth = 150;
const double _cardHeight = 96;

/// The small pill that opens the row: tapped or clicked (never just hovered,
/// which opened a big bar by accident; the Roku takes a press too).
class StreamsPill extends StatelessWidget {
  const StreamsPill({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: PlayerTuning.overlayPercent / 100),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: const Padding(
          padding: EdgeInsets.fromLTRB(12, 7, 16, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(PlayerIcons.streamsPill, color: Colors.white, size: 17),
              SizedBox(width: 6),
              Text(PlayerText.streamsPill, style: TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

class StreamsRow extends StatelessWidget {
  const StreamsRow({super.key, required this.thisGame, required this.recent, required this.qualities, required this.failures, required this.onStream, required this.onRecent, required this.onActivity});

  /// This game's other streams, in the order to show them.
  final List<StreamInfo> thisGame;

  /// Other games, newest first.
  final List<RecentGame> recent;

  /// What streams measured when played, by embed URL.
  final Map<String, StreamQuality> qualities;

  /// Streams that recently failed, and when (see StreamFailures).
  final Map<String, DateTime> failures;

  final void Function(StreamInfo) onStream;
  final void Function(RecentGame) onRecent;

  /// The mouse or a finger is on the row: keep it up.
  final VoidCallback onActivity;

  @override
  Widget build(BuildContext context) {
    final List<Widget> sections = <Widget>[
      if (thisGame.isNotEmpty) _Section(label: PlayerText.thisGame, cards: <Widget>[for (final StreamInfo s in thisGame) _streamCard(context, s)]),
      if (thisGame.isNotEmpty && recent.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 0),
          child: Container(width: 1, height: _cardHeight, color: Colors.white24),
        ),
      if (recent.isNotEmpty) _Section(label: PlayerText.recent, cards: <Widget>[for (final RecentGame r in recent) _recentCard(context, r)]),
    ];
    return Theme(
      data: buildDarkTheme(),
      child: MouseRegion(
        onHover: (_) => onActivity(),
        child: Listener(
          onPointerDown: (_) => onActivity(),
          onPointerMove: (_) => onActivity(),
          child: Container(
            color: Colors.black.withValues(alpha: PlayerTuning.overlayPercent / 100),
            padding: EdgeInsets.fromLTRB(0, 10, 0, 12 + MediaQuery.paddingOf(context).bottom),
            // Sideways when a narrow screen can't fit them all.
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.only(left: 12 + MediaQuery.paddingOf(context).left, right: 12 + MediaQuery.paddingOf(context).right),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: sections),
            ),
          ),
        ),
      ),
    );
  }

  Widget _streamCard(BuildContext context, StreamInfo s) {
    final StreamQuality? q = qualities[s.embedUrl];
    final Color tagColor = s.hd ? hdColor(context) : sdColor(context);
    return _Card(
      onTap: () => onStream(s),
      top: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: tagColor, borderRadius: BorderRadius.circular(5)),
        child: Text(s.hd ? 'HD' : 'SD', style: condensed(14, FontWeight.w700, color: Colors.black, letterSpacing: 0.5)),
      ),
      title: s.name,
      // A recent failure takes the quality's place, in its own colour.
      warning: failures[s.embedUrl] == null ? null : StreamFailures.note(failures[s.embedUrl]!),
      detail: <String>[if (failures[s.embedUrl] == null) q?.label ?? PlayerText.notPlayed, if (s.language.isNotEmpty) s.language].join(' · '),
      // The name is one line here, so the details can have two ("English -
      // NBC" and the like).
      detailLines: 2,
    );
  }

  Widget _recentCard(BuildContext context, RecentGame r) {
    final StreamQuality? q = qualities[r.stream.embedUrl];
    final List<TeamInfo>? teams = orderedTeams(r.match);
    return _Card(
      onTap: () => onRecent(r),
      top: teams == null
          ? PosterDisc(match: r.match, size: 24)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TeamBadge(badgeId: teams[0].badge, category: r.match.category, size: 24),
                Transform.translate(offset: const Offset(-6, 0), child: TeamBadge(badgeId: teams[1].badge, category: r.match.category, size: 24)),
              ],
            ),
      title: r.match.title,
      // Quality first (what you glance for), then which stream.
      detail: q == null ? r.stream.name : '${q.resolution} · ${r.stream.name}',
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.label, required this.cards});
  final String label;
  final List<Widget> cards;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: SizedBox(height: 14, child: Text(label, style: const TextStyle(fontSize: 11, letterSpacing: 0.8, color: Colors.white60))),
        ),
        Row(children: <Widget>[for (int i = 0; i < cards.length; i++) ...<Widget>[if (i > 0) const SizedBox(width: 8), cards[i]]]),
      ],
    );
  }
}

/// Every card the same size, with the same slots at the same heights: the
/// top row (HD/SD, or badges), the name (up to two lines), the details.
class _Card extends StatefulWidget {
  const _Card({required this.onTap, required this.top, required this.title, required this.detail, this.warning, this.detailLines = 1});
  final VoidCallback onTap;
  final Widget top;
  final String title;
  final String detail;
  final String? warning;
  final int detailLines;

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _cardWidth,
      height: _cardHeight,
      child: Material(
        color: AppPalette.card.withValues(alpha: 0.94),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: _hover ? Colors.white : Colors.transparent, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          onHover: (bool h) => setState(() => _hover = h),
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(height: 24, child: Align(alignment: Alignment.centerLeft, child: widget.top)),
                const SizedBox(height: 5),
                Text(widget.title, maxLines: widget.detailLines > 1 ? 1 : 2, overflow: TextOverflow.ellipsis, style: condensed(15, FontWeight.w600, color: Colors.white)),
                const Spacer(),
                Text.rich(
                  TextSpan(children: <InlineSpan>[
                    if (widget.warning != null) TextSpan(text: widget.warning, style: TextStyle(color: failedColor(context))),
                    if (widget.warning != null && widget.detail.isNotEmpty) const TextSpan(text: ' · '),
                    TextSpan(text: widget.detail),
                  ]),
                  maxLines: widget.detailLines,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, height: 1.3, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
