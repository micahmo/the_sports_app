import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/models.dart';
import '../api/streamed_api.dart';
import 'streams_screen.dart';

class MatchesScreen extends StatefulWidget {
  const MatchesScreen.forSport(this.sport, {super.key}) : mode = Mode.bySport;
  const MatchesScreen.live({super.key}) : sport = null, mode = Mode.live;
  const MatchesScreen.livePopular({super.key}) : sport = null, mode = Mode.livePopular;
  const MatchesScreen.liveFavorites({super.key}) : sport = null, mode = Mode.liveFavorites;

  final Sport? sport;
  final Mode mode;

  @override
  State<MatchesScreen> createState() => _MatchesScreenState();
}

class _MatchesScreenState extends State<MatchesScreen> {
  final StreamedApi _api = StreamedApi();
  late Future<List<ApiMatch>> _future;

  // Filters
  bool _popularOnly = false; // only used in bySport mode
  bool _todayOnly = false; // used in bySport + liveFavorites
  bool _showToggles = false; // AppBar "Filters" button controls this

  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _future = _loadData();
    _searchCtrl.addListener(() {
      final String q = _searchCtrl.text;
      if (q != _searchQuery) setState(() => _searchQuery = q);
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<List<ApiMatch>> _loadData() {
    switch (widget.mode) {
      case Mode.live:
        return _api.fetchLiveMatches();
      case Mode.livePopular:
        return _api.fetchLivePopular();
      case Mode.bySport:
        return _loadBySportFor(widget.sport!.id, popularOnly: _popularOnly);
      case Mode.liveFavorites:
        return _loadLiveFavorites();
    }
  }

  Future<List<ApiMatch>> _loadBySportFor(String sportId, {required bool popularOnly}) async {
    // Always fetch the sport list
    final List<ApiMatch> sportMatches = await _api.fetchMatchesBySport(sportId);

    if (!popularOnly) return sportMatches;

    // Fetch popular and intersect by match id
    final List<ApiMatch> popular = await _api.fetchLivePopular();
    final Set<String> popularIds = popular.map((m) => m.id).toSet();

    return sportMatches.where((m) => popularIds.contains(m.id)).toList();
  }

  /// Normal refresh (awaits completion). Good for the AppBar button.
  Future<void> _refreshMatches() async {
    // reassign the future to trigger FutureBuilder
    setState(() {
      _future = _loadData();
    });
    // allow FutureBuilder to rebuild; awaiting is optional here
    await _future;
  }

  /// Quiet refresh for pull-to-refresh: dismisses the indicator immediately.
  Future<void> _refreshMatchesQuiet() {
    setState(() {
      _future = _loadData(); // start loading but don't await here
    });
    return Future<void>.value();
  }

  // Load favorites from SharedPreferences and filter live matches accordingly.
  Future<List<ApiMatch>> _loadLiveFavorites() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> favorites = prefs.getStringList('favoriteTeams') ?? <String>[];

    if (favorites.isEmpty) return <ApiMatch>[];

    // Normalize favorites
    final List<String> favsLower = favorites.map((String s) => s.trim()).where((String s) => s.isNotEmpty).map((String s) => s.toLowerCase()).toList();

    // Fetch all live matches
    final List<ApiMatch> live = await _api.fetchLiveMatches();
    final List<ApiMatch> football = await _api.fetchMatchesBySport('american-football');
    final List<ApiMatch> basketball = await _api.fetchMatchesBySport('basketball');

    // Combine them, de-duping by match ID
    final Map<String, ApiMatch> unique = <String, ApiMatch>{};

    for (final ApiMatch match in [...live, ...football, ...basketball]) {
      unique[match.id] = match; // overwrites duplicates automatically
    }

    final List<ApiMatch> all = unique.values.toList();

    bool matchContainsFavorite(ApiMatch m) {
      // Collect all searchable strings
      final String? home = m.teams?.home?.name;
      final String? away = m.teams?.away?.name;
      final String channel = m.title;
      final String title = m.title;

      final List<String> haystacks = <String>[if (home != null) home, if (away != null) away, channel, title].map((String s) => s.toLowerCase()).toList();

      for (final String fav in favsLower) {
        for (final String h in haystacks) {
          if (h.contains(fav)) return true;
        }
      }
      return false;
    }

    return all.where(matchContainsFavorite).toList();
  }

  // ——— Filtering helpers ———

  List<ApiMatch> _applyTodayOnlyFilter(List<ApiMatch> input) {
    if (!_todayOnly) return input;

    final DateTime now = DateTime.now();
    final DateTime start = DateTime(now.year, now.month, now.day); // local midnight
    final DateTime end = start.add(const Duration(days: 1));

    bool isToday(ApiMatch m) {
      final DateTime dt = DateTime.fromMillisecondsSinceEpoch(m.date, isUtc: true).toLocal();
      return (dt.isAtSameMomentAs(start) || dt.isAfter(start)) && dt.isBefore(end);
    }

    return input.where(isToday).toList();
  }

  List<ApiMatch> _applyRealtimeFilter(List<ApiMatch> input) {
    final String q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return input;

    bool matchesQuery(ApiMatch m) {
      final String title = m.title.toLowerCase();
      final String category = (m.category).toLowerCase();
      final String home = (m.teams?.home?.name ?? '').toLowerCase();
      final String away = (m.teams?.away?.name ?? '').toLowerCase();
      return title.contains(q) || category.contains(q) || home.contains(q) || away.contains(q);
    }

    return input.where(matchesQuery).toList();
  }

  void _togglePopularOnly(bool value) {
    setState(() {
      _popularOnly = value;
      // Only affects bySport mode; other modes ignore this.
      if (widget.mode == Mode.bySport) {
        _future = _loadData();
      }
    });
  }

  void _toggleTodayOnly(bool value) {
    setState(() {
      _todayOnly = value;
      // today-only is client-side, so no need to refetch
    });
  }

  @override
  Widget build(BuildContext context) {
    final String title = switch (widget.mode) {
      Mode.live => 'Live Matches',
      Mode.livePopular => 'Popular',
      Mode.bySport => widget.sport!.name,
      Mode.liveFavorites => 'Favorites',
    };

    // We show the header (search + optional toggles) on By Sport and Favorites.
    final bool showHeader = widget.mode == Mode.bySport || widget.mode == Mode.liveFavorites;
    // Which toggles should appear (when header is visible)?
    final bool showPopularToggle = widget.mode == Mode.bySport;
    final bool showTodayToggle = widget.mode == Mode.bySport || widget.mode == Mode.liveFavorites;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: <Widget>[
          if (showHeader)
            IconButton(
              tooltip: _showToggles ? 'Hide filters' : 'Show filters',
              icon: _showToggles ? const Icon(Icons.filter_list_off) : const Icon(Icons.filter_list),
              onPressed: () => setState(() => _showToggles = !_showToggles),
            ),
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refreshMatches),
        ],
      ),
      body: FutureBuilder<List<ApiMatch>>(
        future: _future,
        builder: (BuildContext ctx, AsyncSnapshot<List<ApiMatch>> snap) {
          // Header widget used in loading/error/empty/success to keep UX consistent
          final Widget? header = showHeader
              ? _FiltersHeader(
                  controller: _searchCtrl,
                  showToggles: _showToggles,
                  // Today
                  showTodayToggle: showTodayToggle,
                  todayOnly: _todayOnly,
                  onTodayChanged: _toggleTodayOnly,
                  // Popular
                  showPopularToggle: showPopularToggle,
                  popularOnly: _popularOnly,
                  onPopularChanged: _togglePopularOnly,
                )
              : null;

          if (snap.connectionState == ConnectionState.waiting) {
            // Keep pull-to-refresh usable while loading, but dismiss immediately:
            return RefreshIndicator(
              onRefresh: _refreshMatchesQuiet,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  if (header != null) header,
                  const SizedBox(height: 240),
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 240),
                ],
              ),
            );
          }
          if (snap.hasError) {
            return RefreshIndicator(
              onRefresh: _refreshMatchesQuiet,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  if (header != null) header,
                  const SizedBox(height: 120),
                  Center(child: Text('Error: ${snap.error}')),
                ],
              ),
            );
          }

          // Base list from backend (already popular-filtered if bySport+popularOnly).
          List<ApiMatch> base = snap.data ?? <ApiMatch>[];

          // Client-side filters in order: today-only → realtime text
          base = _applyTodayOnlyFilter(base);
          final List<ApiMatch> matches = _applyRealtimeFilter(base);

          if (matches.isEmpty) {
            final bool hasQuery = _searchQuery.trim().isNotEmpty;
            final Widget empty = hasQuery
                ? const Text('No matches match your filters')
                : (widget.mode == Mode.liveFavorites
                      ? const Text(
                          'No live matches for your favorites right now\n'
                          'Add teams in Settings or check back later',
                          textAlign: TextAlign.center,
                        )
                      : const Text('No matches found'));

            return RefreshIndicator(
              onRefresh: _refreshMatchesQuiet,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  if (header != null) header,
                  const SizedBox(height: 120),
                  Center(
                    child: Padding(padding: const EdgeInsets.all(24), child: empty),
                  ),
                ],
              ),
            );
          }

          // List with optional header row at index 0.
          final int headerCount = showHeader ? 1 : 0;
          return RefreshIndicator(
            onRefresh: _refreshMatchesQuiet,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: matches.length + headerCount,
              separatorBuilder: (BuildContext _, int i) {
                if (showHeader && i == 0) return const Divider(height: 1);
                return const Divider(height: 1);
              },
              itemBuilder: (BuildContext _, int i) {
                if (showHeader && i == 0) {
                  return header!;
                }

                final ApiMatch m = matches[i - headerCount];
                final String poster = StreamedApi.posterUrlFromMatch(m);

                final DateTime dt = DateTime.fromMillisecondsSinceEpoch(m.date, isUtc: true).toLocal();
                final DateTime now = DateTime.now();

                final DateFormat timeFmt = DateFormat('h:mm a');
                final DateFormat dateFmt = DateFormat('MMM d'); // e.g. "Oct 10"

                // Determine if it's today
                final bool isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
                final String timeDisplay = isToday ? timeFmt.format(dt) : '${dateFmt.format(dt)} • ${timeFmt.format(dt)}';

                final bool isLive = dt.isBefore(DateTime.now().add(const Duration(minutes: 15)));

                return ListTile(
                  leading: SizedBox(
                    width: 56,
                    child: poster.isNotEmpty ? CachedNetworkImage(imageUrl: poster, fit: BoxFit.cover) : _TeamsBadgesRow(m: m),
                  ),
                  title: Row(
                    children: <Widget>[
                      if (isLive) ...<Widget>[
                        const Icon(Icons.circle, color: Colors.red, size: 8),
                        const SizedBox(width: 4),
                        const Text(
                          'LIVE',
                          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(child: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                  ),

                  subtitle: Text('${widget.mode == Mode.bySport ? '' : '${m.category} • '}$timeDisplay'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute<Widget>(builder: (_) => StreamsScreen(matchItem: m))),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _FiltersHeader extends StatelessWidget {
  const _FiltersHeader({
    required this.controller,
    required this.showToggles,
    // Today
    required this.showTodayToggle,
    required this.todayOnly,
    required this.onTodayChanged,
    // Popular
    required this.showPopularToggle,
    required this.popularOnly,
    required this.onPopularChanged,
  });

  final TextEditingController controller;

  final bool showToggles;

  final bool showTodayToggle;
  final bool todayOnly;
  final ValueChanged<bool> onTodayChanged;

  final bool showPopularToggle;
  final bool popularOnly;
  final ValueChanged<bool> onPopularChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final List<Widget> toggleRows = <Widget>[
      if (showTodayToggle)
        InkWell(
          onTap: () => onTodayChanged(!todayOnly),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                const Icon(Icons.today),
                const SizedBox(width: 8),
                const Text('Today only'),
                const Spacer(),
                Switch(value: todayOnly, onChanged: onTodayChanged),
              ],
            ),
          ),
        ),
      if (showPopularToggle)
        InkWell(
          onTap: () => onPopularChanged(!popularOnly),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                const Icon(Icons.trending_up),
                const SizedBox(width: 8),
                const Text('Popular only'),
                const Spacer(),
                Switch(value: popularOnly, onChanged: onPopularChanged),
              ],
            ),
          ),
        ),
    ];

    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          children: <Widget>[
            // Search — always visible
            TextField(
              controller: controller,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                filled: true,
                fillColor: scheme.surfaceVariant.withOpacity(0.4),
                prefixIcon: const Icon(Icons.search),
                hintText: 'Filter by team, title, or category',
                suffixIcon: controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          controller.clear();
                          // listener on controller will trigger setState in parent
                        },
                      ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
              ),
            ),
            // Toggles — collapsible via AppBar "Filters" button
            TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              tween: Tween<double>(begin: showToggles ? 1 : 0, end: showToggles ? 1 : 0),
              builder: (BuildContext context, double factor, Widget? child) {
                return ClipRect(
                  child: Align(alignment: Alignment.topCenter, heightFactor: factor, child: child),
                );
              },
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  children: [
                    for (final w in toggleRows) ...[w, const SizedBox(height: 8)],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeamsBadgesRow extends StatelessWidget {
  const _TeamsBadgesRow({required this.m});
  final ApiMatch m;

  @override
  Widget build(BuildContext context) {
    final String? home = m.teams?.home?.badge;
    final String? away = m.teams?.away?.badge;
    if (home == null && away == null) {
      return const Icon(Icons.sports);
    }
    return Row(
      children: <Widget>[
        if (home != null) Expanded(child: Image.network(StreamedApi.badgeUrl(home), height: 32, fit: BoxFit.contain)),
        if (home != null && away != null) const SizedBox(width: 4),
        if (away != null) Expanded(child: Image.network(StreamedApi.badgeUrl(away), height: 32, fit: BoxFit.contain)),
      ],
    );
  }
}
