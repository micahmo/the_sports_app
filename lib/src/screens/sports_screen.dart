import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../api/models.dart';
import '../api/streamed_api.dart';
import '../theme.dart';
import '../widgets/match_widgets.dart';
import '../widgets/keep_fresh.dart';
import 'matches_screen.dart';
import 'settings_screen.dart';
import 'streams_screen.dart';

class SportsScreen extends StatefulWidget {
  const SportsScreen({super.key});
  @override
  State<SportsScreen> createState() => _SportsScreenState();
}

class _HomeData {
  _HomeData({required this.sports, required this.liveByCategory, required this.liveTotal, required this.top});
  final List<Sport> sports;
  final Map<String, int> liveByCategory;

  /// Null when the live list could not be loaded.
  final int? liveTotal;

  /// The most-watched live matches, biggest first.
  final List<ApiMatch> top;
}

class _SportsScreenState extends State<SportsScreen> with KeepFresh {
  final StreamedApi _api = StreamedApi();
  late Future<_HomeData> _future;

  // A background refresh: keep showing the current data while it loads.
  bool _quiet = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_HomeData> _load() async {
    // The sports list is what Home cannot do without. Live counts and the
    // most-watched list are extras, so if those fail they are simply left out.
    final Future<List<Sport>> sportsF = _api.fetchSports();
    final Future<List<ApiMatch>?> liveF = _api.fetchLiveMatches().then<List<ApiMatch>?>((List<ApiMatch> l) => l).catchError((Object _) => null);
    final Future<List<ApiMatch>> topF = _api.fetchLiveViewCounts().catchError((Object _) => <ApiMatch>[]);

    final List<Sport> sports = await sportsF;
    final List<ApiMatch>? live = await liveF;
    final List<ApiMatch> counted = await topF;

    for (final Sport s in sports) {
      sportsNames[s.id] = s.name;
    }

    final Map<String, int> byCategory = <String, int>{};
    for (final ApiMatch m in live ?? const <ApiMatch>[]) {
      byCategory[m.category] = (byCategory[m.category] ?? 0) + 1;
    }

    final List<ApiMatch> top = counted.where((ApiMatch m) => m.viewers != null).toList()..sort((ApiMatch a, ApiMatch b) => b.viewers!.compareTo(a.viewers!));

    return _HomeData(sports: sports, liveByCategory: byCategory, liveTotal: live?.length, top: top.take(3).toList());
  }

  @override
  void refreshInBackground() {
    final Future<_HomeData> current = _future;
    setState(() {
      _quiet = true;
      _future = _load().catchError((Object _) => current);
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _quiet = false;
      _future = _load();
    });
    try {
      await _future;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // On wide windows the title and settings line up with the centred content.
    final double width = MediaQuery.sizeOf(context).width;
    final bool wide = width >= kWideLayout;
    final double side = wide ? math.max(16, (width - _kMaxContentWidth) / 2) : 16;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: side,
        actionsPadding: wide ? EdgeInsets.only(right: math.max(0, side - 12)) : null,
        title: const ScreenTitle('Sports'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
            },
          ),
        ],
      ),
      body: FutureBuilder<_HomeData>(
        future: _future,
        builder: (BuildContext ctx, AsyncSnapshot<_HomeData> snap) {
          if (snap.connectionState == ConnectionState.waiting && !(_quiet && snap.hasData)) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('Error: ${snap.error}'),
                  const SizedBox(height: 12),
                  TextButton(onPressed: _refresh, child: const Text('Retry')),
                ],
              ),
            );
          }

          final _HomeData d = snap.data!;
          return LayoutBuilder(
            builder: (BuildContext _, BoxConstraints box) {
              // Desktop windows: keep the content to a readable width and use
              // the room for more columns rather than longer rows.
              final bool wide = box.maxWidth >= kWideLayout;
              final double side = wide ? math.max(16, (box.maxWidth - _kMaxContentWidth) / 2) : 16;
              final double content = box.maxWidth - 2 * side;
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(side, 4, side, 24 + MediaQuery.paddingOf(context).bottom),
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _ShortcutTile(
                            icon: Icons.live_tv,
                            color: liveColor(context),
                            label: 'Live now',
                            count: d.liveTotal,
                            onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MatchesScreen.live())),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ShortcutTile(
                            icon: Icons.local_fire_department,
                            color: popularColor(context),
                            label: 'Popular',
                            onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MatchesScreen.livePopular())),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ShortcutTile(
                            icon: Icons.favorite,
                            color: favoriteColor(context),
                            label: 'Favorites',
                            onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MatchesScreen.liveFavorites())),
                          ),
                        ),
                      ],
                    ),
                    if (d.top.isNotEmpty) ...<Widget>[
                      const SectionLabel('Most watched now'),
                      if (wide)
                        // Side by side as separate cards; each opens the live
                        // list with that match's streams alongside.
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              for (int i = 0; i < d.top.length; i++) ...<Widget>[
                                if (i > 0) const SizedBox(width: 8),
                                Expanded(
                                  child: CardSegment(
                                    first: true,
                                    last: true,
                                    horizontalMargin: 0,
                                    child: MatchRow(
                                      match: d.top[i],
                                      categoryLabel: sportsNames[d.top[i].category] ?? d.top[i].category,
                                      onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => MatchesScreen.live(initialMatchId: d.top[i].id))),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        )
                      else
                        for (int i = 0; i < d.top.length; i++)
                          CardSegment(
                            first: i == 0,
                            last: i == d.top.length - 1,
                            horizontalMargin: 0,
                            child: MatchRow(
                              match: d.top[i],
                              categoryLabel: sportsNames[d.top[i].category] ?? d.top[i].category,
                              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StreamsScreen(matchItem: d.top[i]))),
                            ),
                          ),
                    ],
                    const SectionLabel('All sports'),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: EdgeInsets.zero,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        // Two on a phone; on desktop as many ~260px tiles as fit.
                        crossAxisCount: wide ? (content / 260).floor().clamp(2, 6) : 2,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        mainAxisExtent: 56,
                      ),
                      itemCount: d.sports.length,
                      itemBuilder: (BuildContext _, int i) {
                        final Sport s = d.sports[i];
                        return _SportTile(
                          sport: s,
                          live: d.liveByCategory[s.id] ?? 0,
                          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => MatchesScreen.forSport(s))),
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ShortcutTile extends StatelessWidget {
  const _ShortcutTile({required this.icon, required this.color, required this.label, required this.onTap, this.count});
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color live = liveColor(context);
    return Material(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 72,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(icon, size: 24, color: color),
                    const Spacer(),
                    if (count != null) ...<Widget>[
                      Transform.translate(
                        offset: Offset(0, capsCenterShift(17)),
                        child: Container(width: 6, height: 6, decoration: BoxDecoration(color: live, shape: BoxShape.circle)),
                      ),
                      const SizedBox(width: 4),
                      Text('$count', style: condensed(17, FontWeight.w700, color: live)),
                    ],
                  ],
                ),
                Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: cs.onSurface)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SportTile extends StatelessWidget {
  const _SportTile({required this.sport, required this.live, required this.onTap});
  final Sport sport;
  final int live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color liveC = liveColor(context);
    return Material(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: <Widget>[
              Icon(sportIcon(sport.id), size: 20, color: cs.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(sport.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, height: 1.2, color: cs.onSurface)),
              ),
              if (live > 0) ...<Widget>[
                const SizedBox(width: 6),
                Transform.translate(
                  offset: Offset(0, capsCenterShift(16)),
                  child: Container(width: 6, height: 6, decoration: BoxDecoration(color: liveC, shape: BoxShape.circle)),
                ),
                const SizedBox(width: 4),
                Text('$live', style: condensed(16, FontWeight.w700, color: liveC)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// Home's content stops widening past this on desktop windows.
const double _kMaxContentWidth = 1100;

Map<String, String> sportsNames = {};
