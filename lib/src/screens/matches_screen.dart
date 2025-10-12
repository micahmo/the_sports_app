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

  @override
  void initState() {
    super.initState();
    _future = _loadData();
  }

  Future<List<ApiMatch>> _loadData() {
    switch (widget.mode) {
      case Mode.live:
        return _api.fetchLiveMatches();
      case Mode.livePopular:
        return _api.fetchLivePopular();
      case Mode.bySport:
        return _api.fetchMatchesBySport(widget.sport!.id);
      case Mode.liveFavorites:
        return _loadLiveFavorites();
    }
  }

  Future<void> _refreshMatches() async {
    // reassign the future to trigger FutureBuilder
    setState(() {
      _future = _loadData();
    });
    // allow FutureBuilder to rebuild; awaiting is optional here
    await _future;
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

  @override
  Widget build(BuildContext context) {
    final String title = switch (widget.mode) {
      Mode.live => 'Live Matches',
      Mode.livePopular => 'Popular',
      Mode.bySport => widget.sport!.name,
      Mode.liveFavorites => 'Favorites',
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: <Widget>[IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refreshMatches)],
      ),
      body: FutureBuilder<List<ApiMatch>>(
        future: _future,
        builder: (BuildContext ctx, AsyncSnapshot<List<ApiMatch>> snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            // Keep pull-to-refresh usable while loading:
            return RefreshIndicator(
              onRefresh: _refreshMatches,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const <Widget>[
                  SizedBox(height: 240),
                  Center(child: CircularProgressIndicator()),
                  SizedBox(height: 240),
                ],
              ),
            );
          }
          if (snap.hasError) {
            return RefreshIndicator(
              onRefresh: _refreshMatches,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  const SizedBox(height: 120),
                  Center(child: Text('Error: ${snap.error}')),
                ],
              ),
            );
          }

          final List<ApiMatch> matches = snap.data ?? <ApiMatch>[];

          if (matches.isEmpty) {
            final Widget empty = widget.mode == Mode.liveFavorites
                ? const Text(
                    'No live matches for your favorites right now.\n'
                    'Add teams in Settings or check back later.',
                    textAlign: TextAlign.center,
                  )
                : const Text('No matches found');

            return RefreshIndicator(
              onRefresh: _refreshMatches,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  const SizedBox(height: 120),
                  Center(
                    child: Padding(padding: const EdgeInsets.all(24), child: empty),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: _refreshMatches,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: matches.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (BuildContext _, int i) {
                final ApiMatch m = matches[i];
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
