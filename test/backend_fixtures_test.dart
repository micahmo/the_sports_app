// The backend adapters against recorded answers (see DESIGN_NOTES, Backends):
// shared/fixtures/<backend>/ holds a site's answer and the app's models it
// must turn into (expected.json), which the TV's adapter must match too. Run
// with UPDATE_FIXTURES=1 to rewrite expected.json after a deliberate change.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sports/src/api/models.dart';
import 'package:sports/src/api/ppv_backend.dart';

Map<String, dynamic> canonical(PpvSnapshot s) => <String, dynamic>{
  'sports': <Map<String, dynamic>>[for (final Sport x in s.sports) <String, dynamic>{'id': x.id, 'name': x.name}],
  'matches': <Map<String, dynamic>>[
    for (final ApiMatch m in s.matches)
      <String, dynamic>{
        'id': m.id,
        'title': m.title,
        'category': m.category,
        'date': m.date,
        'poster': m.poster,
        'backdrop': m.backdrop,
        'teams': m.teams == null
            ? null
            : <List<String?>>[
                <String?>[m.teams!.home?.name, m.teams!.home?.badge],
                <String?>[m.teams!.away?.name, m.teams!.away?.badge],
              ],
        'sources': <String>[for (final MatchSourceRef r in m.sources) '${r.source}/${r.id}'],
        'viewers': m.viewers,
        'live': s.live.contains(m.id),
      },
  ],
  'streams': <String, dynamic>{
    for (final MapEntry<String, List<StreamInfo>> e in s.streams.entries)
      e.key: <Map<String, dynamic>>[
        for (final StreamInfo st in e.value)
          <String, dynamic>{'id': st.id, 'streamNo': st.streamNo, 'language': st.language, 'hd': st.hd, 'embedUrl': st.embedUrl, 'source': st.source, 'viewers': st.viewers},
      ],
  },
};

void main() {
  test('ppv.st answer -> the app\'s models', () {
    final Map<String, dynamic> body = jsonDecode(File('shared/fixtures/ppv/streams.json').readAsStringSync()) as Map<String, dynamic>;
    final Map<String, dynamic> got = canonical(PpvBackend.parse(body));
    final File expected = File('shared/fixtures/ppv/expected.json');
    if (Platform.environment['UPDATE_FIXTURES'] == '1' || !expected.existsSync()) {
      expected.writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(got)}\n');
    }
    expect(got, jsonDecode(expected.readAsStringSync()));
  });
}
