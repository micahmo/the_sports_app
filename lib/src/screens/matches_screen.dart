import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api/models.dart';
import '../api/streamed_api.dart';
import 'streams_screen.dart';

class MatchesScreen extends StatefulWidget {
  const MatchesScreen.forSport(this.sport, {super.key}) : mode = Mode.bySport;
  const MatchesScreen.live({super.key}) : sport = null, mode = Mode.live;

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
    _future = widget.mode == Mode.live ? _api.fetchLiveMatches() : _api.fetchMatchesBySport(widget.sport!.id);
  }

  @override
  Widget build(BuildContext context) {
    final String title = widget.mode == Mode.live ? 'Live Matches' : widget.sport!.name;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<List<ApiMatch>>(
        future: _future,
        builder: (BuildContext ctx, AsyncSnapshot<List<ApiMatch>> snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final List<ApiMatch> matches = snap.data ?? <ApiMatch>[];
          if (matches.isEmpty) {
            return const Center(child: Text('No matches found'));
          }
          return ListView.separated(
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
                  children: [
                    if (isLive) ...[
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

                subtitle: Text('${widget.mode == Mode.live ? '${m.category} • ' : ''}$timeDisplay'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => StreamsScreen(matchItem: m))),
              );
            },
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
