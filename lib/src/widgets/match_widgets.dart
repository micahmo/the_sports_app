import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api/models.dart';
import '../api/streamed_api.dart';
import '../theme.dart';

/// A mouse-and-keyboard platform, where sideways-swiping rows don't work.
bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// From this width, screens lay out for a desktop window rather than a phone.
const double kWideLayout = 900;

/// Material icon for an API sport id.
IconData sportIcon(String category) => switch (category) {
  'basketball' => Icons.sports_basketball,
  'football' => Icons.sports_soccer,
  'american-football' => Icons.sports_football,
  'hockey' => Icons.sports_hockey,
  'baseball' => Icons.sports_baseball,
  'motor-sports' => Icons.sports_motorsports,
  'fight' => Icons.sports_mma,
  'tennis' => Icons.sports_tennis,
  'rugby' || 'afl' => Icons.sports_rugby,
  'golf' => Icons.sports_golf,
  'cricket' => Icons.sports_cricket,
  'billiards' => Icons.adjust,
  'darts' => Icons.track_changes,
  _ => Icons.sports,
};

/// The two teams in the order the title names them — the API's home/away
/// does not always match the title. Null when the match has no teams (e.g. a
/// wrestling show or a race).
List<TeamInfo>? orderedTeams(ApiMatch m) {
  final TeamInfo? home = m.teams?.home;
  final TeamInfo? away = m.teams?.away;
  if (home == null || away == null) return null;
  final int ih = m.title.indexOf(home.name);
  final int ia = m.title.indexOf(away.name);
  return (ih >= 0 && ia >= 0 && ia < ih) ? <TeamInfo>[away, home] : <TeamInfo>[home, away];
}

/// Started, or starting within 15 minutes.
bool isLiveNow(ApiMatch m) => DateTime.fromMillisecondsSinceEpoch(m.date, isUtc: true).toLocal().isBefore(DateTime.now().add(const Duration(minutes: 15)));

/// "7:00 PM" today, otherwise "Oct 10 · 7:00 PM".
String matchTimeLabel(ApiMatch m) {
  final DateTime dt = DateTime.fromMillisecondsSinceEpoch(m.date, isUtc: true).toLocal();
  final DateTime now = DateTime.now();
  final bool today = dt.year == now.year && dt.month == now.month && dt.day == now.day;
  final String time = DateFormat('h:mm a').format(dt);
  return today ? time : '${DateFormat('MMM d').format(dt)} · $time';
}

/// A screen's name in the app bar, uppercase, with an optional live count.
/// Sized so its capitals match the back arrow, and nudged to centre on it.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.text, {super.key, this.count});
  final String text;
  final int? count;

  @override
  Widget build(BuildContext context) {
    const double size = 24;
    return Transform.translate(
      // Measured on the emulator: half the caps shift centres the capitals on
      // the back arrow; the app bar already absorbs the rest.
      offset: Offset(0, -capsCenterShift(size) / 2),
      // One paragraph, so the smaller count shares the title's baseline exactly.
      child: Text.rich(
        TextSpan(
          text: text.toUpperCase(),
          children: <InlineSpan>[
            if (count != null) ...<InlineSpan>[
              const WidgetSpan(child: SizedBox(width: 8)),
              TextSpan(text: '$count', style: condensed(17, FontWeight.w600, color: liveColor(context))),
            ],
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: condensed(size, FontWeight.w600, letterSpacing: 0.8),
      ),
    );
  }
}

/// Uppercase label heading a section of a screen.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(text.toUpperCase(), style: condensed(14, FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.4)),
    );
  }
}

/// Red dot and "LIVE".
class LiveTag extends StatelessWidget {
  const LiveTag({super.key, this.size = 14});
  final double size;

  @override
  Widget build(BuildContext context) {
    final Color c = liveColor(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Transform.translate(
          offset: Offset(0, capsCenterShift(size)),
          child: Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        ),
        const SizedBox(width: 5),
        Text('LIVE', style: condensed(size, FontWeight.w700, color: c, letterSpacing: size * 0.06)),
      ],
    );
  }
}

/// Eye icon and a compact viewer count.
class ViewerCount extends StatelessWidget {
  const ViewerCount(this.viewers, {super.key, this.size = 18, this.color});
  final int viewers;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Transform.translate(
          offset: Offset(0, capsCenterShift(size)),
          child: Icon(Icons.visibility, size: size - 2, color: color?.withValues(alpha: 0.7) ?? cs.outline),
        ),
        const SizedBox(width: 4),
        Text(
          formatViewers(viewers),
          style: condensed(size, FontWeight.w600, color: color ?? cs.onSurface).copyWith(fontFeatures: const <FontFeature>[FontFeature.tabularFigures()]),
        ),
      ],
    );
  }
}

/// A team's logo on a light disc. Falls back to the sport's icon.
class TeamBadge extends StatelessWidget {
  const TeamBadge({super.key, required this.badgeId, required this.category, this.size = 26});
  final String? badgeId;
  final String category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Widget fallback = Icon(sportIcon(category), size: size * 0.62, color: const Color(0xFF55585F));
    final String? id = badgeId;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.12),
      decoration: BoxDecoration(
        color: badgeDiscColor(context),
        shape: BoxShape.circle,
        border: dark ? null : Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: (id == null || id.isEmpty)
          ? Center(child: fallback)
          : CachedNetworkImage(
              imageUrl: StreamedApi.badgeUrl(id),
              fit: BoxFit.contain,
              placeholder: (_, __) => const SizedBox.shrink(),
              errorWidget: (_, __, ___) => Center(child: fallback),
            ),
    );
  }
}

/// An event's poster cropped into a disc, for events without teams.
class PosterDisc extends StatelessWidget {
  const PosterDisc({super.key, required this.match, this.size = 26});
  final ApiMatch match;
  final double size;

  @override
  Widget build(BuildContext context) {
    final String url = StreamedApi.posterUrlFromMatch(match);
    if (url.isEmpty) return TeamBadge(badgeId: null, category: match.category, size: size);
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => TeamBadge(badgeId: null, category: match.category, size: size),
      ),
    );
  }
}

/// One game: each team on its own line at full name, LIVE and viewers on the
/// right, sport and start time underneath.
class MatchRow extends StatelessWidget {
  const MatchRow({super.key, required this.match, required this.onTap, this.categoryLabel, this.selected = false});
  final ApiMatch match;
  final VoidCallback onTap;

  /// The match showing alongside the list, in the side-by-side layout.
  final bool selected;

  /// Sport name for the meta line; null leaves it out (e.g. inside a sport's own list).
  final String? categoryLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ApiMatch m = match;
    final List<TeamInfo>? teams = orderedTeams(m);
    final bool live = isLiveNow(m);
    final String meta = <String>[if (categoryLabel != null) categoryLabel!, matchTimeLabel(m)].join(' · ').toUpperCase();
    final TextStyle nameStyle = condensed(19, FontWeight.w500, color: cs.onSurface);

    Widget line(Widget lead, String text, {int maxLines = 1}) {
      return Row(
        children: <Widget>[
          lead,
          const SizedBox(width: 10),
          Expanded(child: Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: nameStyle)),
        ],
      );
    }

    final List<Widget> lines = teams != null
        ? <Widget>[
            line(TeamBadge(badgeId: teams[0].badge, category: m.category), teams[0].name),
            const SizedBox(height: 6),
            line(TeamBadge(badgeId: teams[1].badge, category: m.category), teams[1].name),
          ]
        : <Widget>[line(PosterDisc(match: m), m.title, maxLines: 2)];

    return Material(
      color: selected ? cs.surfaceContainerHighest : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines)),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      if (live) const LiveTag(),
                      if (live && m.viewers != null) const SizedBox(height: 8),
                      if (m.viewers != null) ViewerCount(m.viewers!),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 36),
                child: Text(meta, style: TextStyle(fontSize: 12, letterSpacing: 0.8, color: cs.outline)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One row of a rounded card, so long lists can still be built lazily: the
/// first row rounds the top corners, the last the bottom, the rest get a divider.
class CardSegment extends StatelessWidget {
  const CardSegment({super.key, required this.first, required this.last, required this.child, this.horizontalMargin = 16});
  final bool first;
  final bool last;
  final Widget child;
  final double horizontalMargin;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    const Radius r = Radius.circular(20);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalMargin),
      child: Material(
        color: cs.surfaceContainer,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.vertical(top: first ? r : Radius.zero, bottom: last ? r : Radius.zero),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (!first) Divider(height: 1, thickness: 1, color: cs.outlineVariant),
            child,
          ],
        ),
      ),
    );
  }
}
