import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sports/src/screens/sports_screen.dart';
import '../api/models.dart';
import '../api/streamed_api.dart';
import '../theme.dart';
import '../widgets/match_widgets.dart';
import '../widgets/refresh_on_resume.dart';
import 'streams_screen.dart';

class MatchesScreen extends StatefulWidget {
  const MatchesScreen.forSport(this.sport, {super.key}) : mode = Mode.bySport, initialMatchId = null;
  const MatchesScreen.live({super.key, this.initialMatchId}) : sport = null, mode = Mode.live;
  const MatchesScreen.livePopular({super.key}) : sport = null, mode = Mode.livePopular, initialMatchId = null;
  const MatchesScreen.liveFavorites({super.key}) : sport = null, mode = Mode.liveFavorites, initialMatchId = null;

  final Sport? sport;
  final Mode mode;

  /// In the side-by-side layout, the match to show first (e.g. one picked on Home).
  final String? initialMatchId;

  @override
  State<MatchesScreen> createState() => _MatchesScreenState();
}

// Width of the list when it sits beside the chosen match's streams.
const double _kListWidth = 460;

class _MatchesScreenState extends State<MatchesScreen> with RefreshOnResume {
  final StreamedApi _api = StreamedApi();

  // Side-by-side layout only: the match whose streams are showing, and the
  // matches the list is currently showing (after filters).
  late String? _selectedId = widget.initialMatchId;
  List<ApiMatch> _shown = <ApiMatch>[];
  late Future<List<ApiMatch>> _future;

  // Filters
  bool _popularOnly = false; // only used in bySport mode
  bool _todayOnly = false; // used in bySport + liveFavorites
  bool _showToggles = false; // AppBar "Filters" button controls this
  bool _showSearch = false; // AppBar search button controls this

  // Sport chip filter; null shows every sport. Only used when a list spans sports.
  String? _category;

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
        return _withViewCounts(_api.fetchLiveMatches());
      case Mode.livePopular:
        return _withViewCounts(_api.fetchLivePopular());
      case Mode.bySport:
        return _loadBySportFor(widget.sport!.id, popularOnly: _popularOnly);
      case Mode.liveFavorites:
        return _loadLiveFavorites();
    }
  }

  /// Attach match-level viewer totals where the API has them. Only the biggest
  /// live matches are covered, so most rows stay null and simply show no count.
  /// A failure here must not cost us the match list.
  Future<List<ApiMatch>> _withViewCounts(Future<List<ApiMatch>> matches) async {
    final List<ApiMatch> list = await matches;
    try {
      final List<ApiMatch> counted = await _api.fetchLiveViewCounts();
      final Map<String, int> byId = <String, int>{
        for (final ApiMatch m in counted)
          if (m.viewers != null) m.id: m.viewers!,
      };
      if (byId.isEmpty) return list;
      final List<ApiMatch> withCounts = list.map((ApiMatch m) => byId.containsKey(m.id) ? m.withViewers(byId[m.id]) : m).toList();

      // Float the matches we have counts for to the top, most-watched first.
      // The endpoint only covers the biggest few, but they are the biggest by a
      // wide margin (hundreds/thousands vs tens), so nothing notable is buried.
      // Everything else keeps the order the API gave us — List.sort is not
      // stable, hence the index tie-break.
      final List<int> order = List<int>.generate(withCounts.length, (int i) => i)
        ..sort((int a, int b) {
          final int? va = withCounts[a].viewers;
          final int? vb = withCounts[b].viewers;
          if (va != null && vb != null) return vb.compareTo(va);
          if (va != null) return -1;
          if (vb != null) return 1;
          return a.compareTo(b);
        });
      return <ApiMatch>[for (final int i in order) withCounts[i]];
    } catch (_) {
      return list;
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
  @override
  void onResumeRefresh() => _refreshMatchesQuiet();

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

    // Live, plus every scheduled match across all sports. This used to fetch
    // american-football and basketball specifically, which silently missed
    // favorites in any other sport.
    final List<List<ApiMatch>> fetched = await Future.wait(<Future<List<ApiMatch>>>[_api.fetchLiveMatches(), _api.fetchAllMatches()]);

    // Combine them, de-duping by match ID
    final Map<String, ApiMatch> unique = <String, ApiMatch>{};

    for (final ApiMatch match in fetched.expand((List<ApiMatch> l) => l)) {
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

  /// Drop-in label for a sport chip: the sport's name without its aside, so
  /// "Fight (UFC, Boxing)" fits as "Fight".
  static String _chipName(String category) => (sportsNames[category] ?? category).replaceAll(RegExp(r'\s*\(.*\)'), '');

  /// Sport chips for lists that span sports (live, popular, favorites), with a
  /// count per sport. Null when there is only one sport to choose from.
  Widget? _buildSportChips(List<ApiMatch> base, String? selectedCategory) {
    if (widget.mode == Mode.bySport) return null;
    final Map<String, int> counts = <String, int>{};
    for (final ApiMatch m in base) {
      counts[m.category] = (counts[m.category] ?? 0) + 1;
    }
    if (counts.length < 2) return null;
    final List<MapEntry<String, int>> cats = counts.entries.toList()..sort((MapEntry<String, int> a, MapEntry<String, int> b) => b.value.compareTo(a.value));

    final List<Widget> chips = <Widget>[
      _SportChip(label: 'All', count: base.length, selected: selectedCategory == null, onTap: () => setState(() => _category = null)),
      for (final MapEntry<String, int> e in cats)
        _SportChip(label: _chipName(e.key), count: e.value, selected: selectedCategory == e.key, onTap: () => setState(() => _category = e.key)),
    ];

    // A mouse wheel can't scroll a sideways row, so on desktop every chip
    // stays in view and they wrap onto more lines instead.
    if (isDesktop) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[for (final Widget c in chips) SizedBox(height: 36, child: c)],
        ),
      );
    }
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: chips.length,
        separatorBuilder: (BuildContext _, int __) => const SizedBox(width: 8),
        itemBuilder: (BuildContext _, int i) => chips[i],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String title = switch (widget.mode) {
      Mode.live => 'Live',
      Mode.livePopular => 'Popular',
      Mode.bySport => widget.sport!.name,
      Mode.liveFavorites => 'Favorites',
    };

    // Lists of what's on now show how many next to the title.
    final bool showCount = widget.mode == Mode.live || widget.mode == Mode.livePopular;

    final bool showAnyToggles = _showPopularToggle || _showTodayToggle;

    return Scaffold(
      appBar: AppBar(
        title: FutureBuilder<List<ApiMatch>>(
          future: _future,
          builder: (BuildContext _, AsyncSnapshot<List<ApiMatch>> s) {
            return ScreenTitle(title, count: showCount && s.hasData ? s.data!.length : null);
          },
        ),
        actions: <Widget>[
          IconButton(
            tooltip: _showSearch ? 'Close search' : 'Search',
            icon: Icon(_showSearch ? Icons.search_off : Icons.search),
            onPressed: () => setState(() {
              _showSearch = !_showSearch;
              // A hidden search that still filters the list would be confusing.
              if (!_showSearch) _searchCtrl.clear();
            }),
          ),
          if (showAnyToggles)
            IconButton(
              tooltip: _showToggles ? 'Hide filters' : 'Show filters',
              icon: _showToggles ? const Icon(Icons.filter_list_off) : const Icon(Icons.filter_list),
              onPressed: () => setState(() => _showToggles = !_showToggles),
            ),
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refreshMatches),
        ],
      ),
      // Wide windows (desktop) show the list and the chosen match's streams
      // side by side; narrow ones keep the phone layout.
      body: LayoutBuilder(
        builder: (BuildContext _, BoxConstraints box) {
          final bool wide = box.maxWidth >= kWideLayout;
          return FutureBuilder<List<ApiMatch>>(
            future: _future,
            builder: (BuildContext ctx, AsyncSnapshot<List<ApiMatch>> snap) {
              final Widget list = _buildList(ctx, snap, wide);
              if (!wide) return list;
              final ApiMatch? selected = _selectedMatch();
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(width: _kListWidth, child: list),
                  VerticalDivider(width: 1, thickness: 1, color: Theme.of(context).colorScheme.outlineVariant),
                  Expanded(
                    child: selected == null
                        ? const SizedBox.shrink()
                        // Capped so stream rows don't stretch across a big monitor.
                        : Align(
                            alignment: Alignment.topLeft,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 900),
                              // Keyed by match so switching matches starts a fresh load.
                              child: StreamsScreen(key: ValueKey<String>(selected.id), matchItem: selected, embedded: true),
                            ),
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  // Which toggles should appear (when header is visible)?
  bool get _showPopularToggle => widget.mode == Mode.bySport;
  bool get _showTodayToggle => widget.mode == Mode.bySport || widget.mode == Mode.liveFavorites;

  // The chosen match if it is still listed, otherwise the first one, so the
  // streams side is never empty.
  ApiMatch? _selectedMatch() {
    for (final ApiMatch m in _shown) {
      if (m.id == _selectedId) return m;
    }
    return _shown.isEmpty ? null : _shown.first;
  }

  Widget _buildList(BuildContext ctx, AsyncSnapshot<List<ApiMatch>> snap, bool wide) {
    _shown = <ApiMatch>[];
    // Base list from backend (already popular-filtered if bySport+popularOnly),
    // then today-only, which the sport chips count against.
    final List<ApiMatch> base = _applyTodayOnlyFilter(snap.data ?? <ApiMatch>[]);

    // Forget a chip selection that no longer matches anything, e.g. after a refresh.
    final String? category = (_category != null && base.any((ApiMatch m) => m.category == _category)) ? _category : null;

    // Header widget used in loading/error/empty/success to keep UX consistent
    final Widget header = _FiltersHeader(
      controller: _searchCtrl,
      showSearch: _showSearch,
      showToggles: _showToggles,
      // Today
      showTodayToggle: _showTodayToggle,
      todayOnly: _todayOnly,
      onTodayChanged: _toggleTodayOnly,
      // Popular
      showPopularToggle: _showPopularToggle,
      popularOnly: _popularOnly,
      onPopularChanged: _togglePopularOnly,
      // Sports
      chips: snap.hasData ? _buildSportChips(base, category) : null,
    );

    if (snap.connectionState == ConnectionState.waiting) {
      // Keep pull-to-refresh usable while loading, but dismiss immediately:
      return RefreshIndicator(
        onRefresh: _refreshMatchesQuiet,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: <Widget>[
            header,
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
            header,
            const SizedBox(height: 120),
            Center(child: Text('Error: ${snap.error}')),
          ],
        ),
      );
    }

    // Client-side filters in order: today-only → sport chip → realtime text
    final List<ApiMatch> inCategory = category == null ? base : base.where((ApiMatch m) => m.category == category).toList();
    final List<ApiMatch> matches = _applyRealtimeFilter(inCategory);
    _shown = matches;
    final String? selectedId = wide ? _selectedMatch()?.id : null;

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
            header,
            const SizedBox(height: 120),
            Center(
              child: Padding(padding: const EdgeInsets.all(24), child: empty),
            ),
          ],
        ),
      );
    }

    // Header, then the games as one rounded card built row by row.
    return RefreshIndicator(
      onRefresh: _refreshMatchesQuiet,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
        itemCount: matches.length + 1,
        itemBuilder: (BuildContext _, int i) {
          if (i == 0) return header;
          final ApiMatch m = matches[i - 1];
          return CardSegment(
            first: i == 1,
            last: i == matches.length,
            child: MatchRow(
              match: m,
              // A sport's own list doesn't need the sport on every row.
              categoryLabel: widget.mode == Mode.bySport ? null : (sportsNames[m.category] ?? m.category),
              selected: m.id == selectedId,
              onTap: wide
                  ? () => setState(() => _selectedId = m.id)
                  : () => Navigator.push(context, MaterialPageRoute<Widget>(builder: (_) => StreamsScreen(matchItem: m))),
            ),
          );
        },
      ),
    );
  }
}

class _SportChip extends StatelessWidget {
  const _SportChip({required this.label, required this.count, required this.selected, required this.onTap});
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color fg = selected ? cs.surface : cs.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? cs.onSurface : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(label.toUpperCase(), style: condensed(15, FontWeight.w600, color: fg, letterSpacing: 0.6)),
                const SizedBox(width: 6),
                Text('$count', style: condensed(15, FontWeight.w600, color: selected ? fg.withValues(alpha: 0.7) : liveColor(context))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FiltersHeader extends StatelessWidget {
  const _FiltersHeader({
    required this.controller,
    required this.showSearch,
    required this.showToggles,
    // Today
    required this.showTodayToggle,
    required this.todayOnly,
    required this.onTodayChanged,
    // Popular
    required this.showPopularToggle,
    required this.popularOnly,
    required this.onPopularChanged,
    // Sports
    this.chips,
  });

  final TextEditingController controller;

  final bool showSearch;
  final bool showToggles;

  final Widget? chips;

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

    // Nothing to show (search closed, no toggles, one sport): just a little air.
    final bool hasToggles = showTodayToggle || showPopularToggle;
    if (!showSearch && !hasToggles && chips == null) return const SizedBox(height: 4);

    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 10),
        child: Column(
          children: <Widget>[
            // Search and toggles keep the gutter; the chip row scrolls edge to edge.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: <Widget>[
                  // Search — opened from the AppBar, so it doesn't cost a row by default
                  if (showSearch)
                    TextField(
                      controller: controller,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
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
                  if (hasToggles)
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
            // Sport chips
            if (chips != null)
              Padding(
                padding: EdgeInsets.only(top: showSearch ? 10 : 2),
                child: chips,
              ),
          ],
        ),
      ),
    );
  }
}
