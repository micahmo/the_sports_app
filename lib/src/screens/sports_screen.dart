import 'package:flutter/material.dart';
import '../api/models.dart';
import '../api/streamed_api.dart';
import 'matches_screen.dart';

class SportsScreen extends StatefulWidget {
  const SportsScreen({super.key});
  @override
  State<SportsScreen> createState() => _SportsScreenState();
}

class _SportsScreenState extends State<SportsScreen> {
  final StreamedApi _api = StreamedApi();
  late Future<List<Sport>> _future;

  @override
  void initState() {
    super.initState();
    _future = _api.fetchSports();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sports')),
      body: FutureBuilder<List<Sport>>(
        future: _future,
        builder: (BuildContext ctx, AsyncSnapshot<List<Sport>> snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final List<Sport> sports = snap.data ?? <Sport>[];
          if (sports.isEmpty) {
            return const Center(child: Text('No sports available'));
          }
          return ListView.separated(
            itemCount: sports.length + 2, // +2 for Live and Popular
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (BuildContext _, int i) {
              if (i == 0) {
                return ListTile(
                  leading: const Icon(Icons.live_tv),
                  title: const Text('Live now'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MatchesScreen.live())),
                );
              }
              if (i == 1) {
                return ListTile(
                  leading: const Icon(Icons.local_fire_department),
                  title: const Text('Popular'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MatchesScreen.livePopular())),
                );
              }
              final Sport s = sports[i - 2]; // shift by 2 now
              return ListTile(
                title: Text(s.name),
                subtitle: Text(s.id),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MatchesScreen.forSport(s))),
              );
            },
          );
        },
      ),
    );
  }
}
