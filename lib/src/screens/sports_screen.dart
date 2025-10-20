import 'package:flutter/material.dart';
import '../api/models.dart';
import '../api/streamed_api.dart';
import 'matches_screen.dart';
import 'settings_screen.dart';

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
      appBar: AppBar(
        title: const Text('Sports'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
              // If you want to react to favorites changing, do a setState() here.
              // setState(() {});
            },
          ),
        ],
      ),
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
            itemCount: sports.length + 3, // +3 for Live, Popular, Favorites
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (BuildContext _, int i) {
              if (i == 0) {
                return ListTile(
                  leading: const Icon(Icons.live_tv),
                  title: const Text('Live now'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MatchesScreen.live())),
                );
              }
              if (i == 1) {
                return ListTile(
                  leading: const Icon(Icons.local_fire_department),
                  title: const Text('Popular'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MatchesScreen.livePopular())),
                );
              }
              if (i == 2) {
                return ListTile(
                  leading: const Icon(Icons.favorite),
                  title: const Text('Favorites'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MatchesScreen.liveFavorites())),
                );
              }

              final Sport s = sports[i - 3]; // shift by 3 now
              return ListTile(
                title: Text(s.name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => MatchesScreen.forSport(s))),
              );
            },
          );
        },
      ),
    );
  }
}
