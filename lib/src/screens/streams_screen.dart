import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import '../api/models.dart';
import '../api/streamed_api.dart';
import '../desktop/window_state.dart';
import '../generated/app_data.dart';
import '../player/player_webview.dart';
import '../player/stream_quality.dart';
import '../theme.dart';
import '../widgets/match_widgets.dart';
import '../widgets/keep_fresh.dart';
import 'sports_screen.dart' show sportsNames;

const MethodChannel _nowPlaying = MethodChannel('nowplaying');

class StreamsScreen extends StatefulWidget {
  const StreamsScreen({super.key, required this.matchItem, this.embedded = false});
  final ApiMatch matchItem;

  /// Just the content, no app bar: shown beside the match list on wide windows.
  final bool embedded;

  @override
  State<StreamsScreen> createState() => _StreamsScreenState();
}

class _StreamsScreenState extends State<StreamsScreen> with KeepFresh {
  final StreamedApi _api = StreamedApi();
  late Future<List<_SourceGroup>> _future;

  // A background refresh: keep showing the current streams while they load.
  bool _quiet = false;

  // Remember last-picked stream (per list view instance)
  String? _lastPlayedUrl;

  // What streams measured when they were played (see StreamQuality).
  Map<String, StreamQuality> _qualities = <String, StreamQuality>{};

  @override
  void initState() {
    super.initState();
    _future = _loadAllStreams();
    _loadQualities();

    // Ask, then show once granted
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _ensureNotifPermission();
      if (!mounted) return;
      await _showNowPlaying();
    });
  }

  @override
  void refreshInBackground() {
    final Future<List<_SourceGroup>> current = _future;
    setState(() {
      _quiet = true;
      _future = _loadAllStreams().catchError((Object _) => current);
    });
  }

  Future<List<_SourceGroup>> _loadAllStreams() async {
    // Best sources first, the way the website presents them. List.sort is not
    // stable, so tie-break on the original index to keep unranked sources in
    // the order the API gave them.
    final List<int> order = List<int>.generate(widget.matchItem.sources.length, (int i) => i)
      ..sort((int a, int b) {
        final List<MatchSourceRef> src = widget.matchItem.sources;
        final int byRank = _sourceRank(src[a].source).compareTo(_sourceRank(src[b].source));
        return byRank != 0 ? byRank : a.compareTo(b);
      });
    final List<MatchSourceRef> sources = <MatchSourceRef>[for (final int i in order) widget.matchItem.sources[i]];
    // Fetch all sources in parallel
    final List<List<StreamInfo>> results = await Future.wait(sources.map((s) => _api.fetchStreams(s.source, s.id)), eagerError: true);

    return <_SourceGroup>[
      for (int i = 0; i < sources.length; i++)
        if (results[i].isNotEmpty) _SourceGroup(sources[i].source, results[i]),
    ];
  }

  Future<void> _play(StreamInfo s) async {
    // Set before navigating so it shows even if user backs out
    setState(() => _lastPlayedUrl = s.embedUrl);
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StreamPlayerScreen(stream: s, title: widget.matchItem.title)));
    // The player measured it; show that on its row.
    _loadQualities();
  }

  Future<void> _loadQualities() async {
    final Map<String, StreamQuality> q = await StreamQuality.all();
    if (mounted) setState(() => _qualities = q);
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = FutureBuilder<List<_SourceGroup>>(
      future: _future,
      builder: (BuildContext ctx, AsyncSnapshot<List<_SourceGroup>> snap) {
        final List<_SourceGroup> groups = snap.data ?? <_SourceGroup>[];
        // Prefer the site's own match total, so the number matches the row you
        // tapped. Summing the streams undercounts: sources that return nothing
        // right now still have viewers in that total.
        final int? watching =
            widget.matchItem.viewers ?? (snap.hasData ? groups.expand((_SourceGroup g) => g.streams).fold<int>(0, (int sum, StreamInfo s) => sum + (s.viewers ?? 0)) : null);
        final Widget header = _MatchHeader(match: widget.matchItem, watching: watching);

        if (snap.connectionState == ConnectionState.waiting && !(_quiet && snap.hasData)) {
          return ListView(children: <Widget>[header, const SizedBox(height: 120), const Center(child: CircularProgressIndicator())]);
        }
        if (snap.hasError) {
          return ListView(children: <Widget>[header, const SizedBox(height: 80), Center(child: Text('Error: ${snap.error}'))]);
        }
        if (groups.isEmpty) {
          return ListView(children: <Widget>[header, const SizedBox(height: 80), const Center(child: Text('No streams available.'))]);
        }

        return ListView(
          padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
          children: <Widget>[
            header,
            for (final _SourceGroup g in groups) ...<Widget>[
              _SourceHeading(source: g.source, description: sourceDescriptions[g.source]),
              for (int i = 0; i < g.streams.length; i++)
                CardSegment(
                  first: i == 0,
                  last: i == g.streams.length - 1,
                  child: _StreamRow(
                    stream: g.streams[i],
                    lastPlayed: g.streams[i].embedUrl == _lastPlayedUrl,
                    quality: _qualities[g.streams[i].embedUrl],
                    onTap: () => _play(g.streams[i]),
                  ),
                ),
            ],
          ],
        );
      },
    );

    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Streams')),
      // Clear of a landscape phone's camera cutout, as the app bar is.
      body: SafeArea(top: false, bottom: false, child: body),
    );
  }

  @override
  void dispose() {
    _hideNowPlaying();
    super.dispose();
  }

  Future<void> _showNowPlaying() async {
    try {
      await _nowPlaying.invokeMethod('show', <String, dynamic>{'title': widget.matchItem.title});
    } catch (_) {}
  }

  Future<void> _hideNowPlaying() async {
    try {
      await _nowPlaying.invokeMethod('hide');
    } catch (_) {}
  }

  Future<void> _ensureNotifPermission() async {
    if (Platform.isAndroid) {
      // Android 13+ only (notification runtime permission)
      final status = await Permission.notification.status;
      if (!status.isGranted) {
        await Permission.notification.request();
      }
    }
  }
}

class _SourceGroup {
  _SourceGroup(this.source, this.streams);
  final String source;
  final List<StreamInfo> streams;
}

/// Both teams large with their badges, then LIVE, sport, start time and how
/// many are watching across every source.
class _MatchHeader extends StatelessWidget {
  const _MatchHeader({required this.match, required this.watching});
  final ApiMatch match;
  final int? watching;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final List<TeamInfo>? teams = orderedTeams(match);
    final TextStyle nameStyle = condensed(25, FontWeight.w600, color: cs.onSurface);
    final int total = watching ?? 0;
    final String meta = <String>[
      sportsNames[match.category] ?? match.category,
      matchTimeLabel(match),
      if (total > 0) '${formatViewers(total)} watching',
    ].join(' · ').toUpperCase();

    Widget line(Widget lead, String text, int maxLines) {
      return Row(
        children: <Widget>[
          lead,
          const SizedBox(width: 12),
          Expanded(child: Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: nameStyle)),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (teams != null) ...<Widget>[
            line(TeamBadge(badgeId: teams[0].badge, category: match.category, size: 36), teams[0].name, 2),
            const SizedBox(height: 10),
            line(TeamBadge(badgeId: teams[1].badge, category: match.category, size: 36), teams[1].name, 2),
          ] else
            line(PosterDisc(match: match, size: 44), match.title, 3),
          const SizedBox(height: 12),
          // On one baseline: LIVE and the smaller meta text are different faces,
          // and centring their boxes leaves the capitals at different heights.
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              if (isLiveNow(match)) ...<Widget>[const LiveTag(size: 15), const SizedBox(width: 10)],
              Expanded(child: Text(meta, style: TextStyle(fontSize: 12, letterSpacing: 0.8, color: cs.onSurfaceVariant))),
            ],
          ),
        ],
      ),
    );
  }
}

/// A source's name, with the site's description of it alongside.
class _SourceHeading extends StatelessWidget {
  const _SourceHeading({required this.source, this.description});
  final String source;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Text(source.toUpperCase(), style: condensed(17, FontWeight.w700, color: cs.onSurface, letterSpacing: 1.7)),
          const SizedBox(width: 12),
          if (description != null)
            Expanded(
              child: Text(description!, textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: cs.outline)),
            ),
        ],
      ),
    );
  }
}

class _StreamRow extends StatelessWidget {
  const _StreamRow({required this.stream, required this.lastPlayed, required this.quality, required this.onTap});
  final StreamInfo stream;
  final bool lastPlayed;
  final VoidCallback onTap;

  /// What it measured when played, on a quiet second line; null if never played.
  final StreamQuality? quality;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    // The last-played stream picks up the accent and goes bold, viewer count
    // included, so nothing on its line is left in the old colour.
    final Color? accent = lastPlayed ? cs.primary : null;
    return Semantics(
      selected: lastPlayed,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: <Widget>[
              // HD and SD differ by one letter, so colour carries the difference.
              Container(
                width: 40,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: stream.hd ? hdColor(context) : sdColor(context), borderRadius: BorderRadius.circular(7)),
                child: Text(stream.hd ? 'HD' : 'SD', style: condensed(15, FontWeight.w700, color: theme.scaffoldBackgroundColor, letterSpacing: 0.6)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: <Widget>[
                        Text('Stream ${stream.streamNo}', style: condensed(19, lastPlayed ? FontWeight.w700 : FontWeight.w500, color: accent ?? cs.onSurface)),
                        if (stream.language.isNotEmpty) ...<Widget>[
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(stream.language, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: accent ?? cs.onSurfaceVariant)),
                          ),
                        ],
                      ],
                    ),
                    if (quality != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(quality!.label, style: TextStyle(fontSize: 12, color: cs.outline)),
                      ),
                  ],
                ),
              ),
              if (stream.viewers != null) ...<Widget>[const SizedBox(width: 12), ViewerCount(stream.viewers!, color: accent)],
            ],
          ),
        ),
      ),
    );
  }
}

// embed.st hands the WebView a valid HLS url, then its own player bootstrap
// bails out and paints "Remove sandbox attributes on the iframe tag" over the
// page. That url is bound to the page session, so it cannot be fetched from
// Dart -- but it plays fine inside this WebView. So we let the page fetch the
// url, then throw its player away and run our own <video> + hls.js on it.
const String _takeoverJs = r'''
(function () {
  if (window.__appPlayer) return;
  window.__appPlayer = { url: null, built: false, revealed: false };

  var HLS_SRC = "https://cdn.jsdelivr.net/npm/hls.js@1.5.17/dist/hls.min.js";
  var hls = null;
  var video = null;
  // Our own pinned hls.js. Where the page's player still runs (WebView2 on
  // Windows), it has put its own P2P-patched hls.js on window.Hls; built on
  // that one, fragment timings come out wrong and the live edge lands hours
  // past the buffer. So never use whatever window.Hls happens to be.
  var OurHls = null;
  var lastTime = -1;
  var stalledFor = 0;
  // When the video last played on (or was paused on purpose); see watch().
  var lastProgressAt = Date.now();
  // For measure(): the last few segments' sizes and lengths, and the frame
  // count at the start of the current window.
  var fragStats = [];
  var frames0 = null;
  var fpsMax = 0;
  // The stream's own frame rate, from the frames in each segment (see build()).
  var streamFps = 0;
  // Whether we have told the app to lift its spinner.
  var announced = false;
  var waitingFor = 0;
  // When we last recovered from a media error, pushed playback past a stuck
  // spot, and caught up with live (the error handler, watch(), catchUp()).
  var mediaRecoveredAt = 0;
  var forcedAt = 0;
  var caughtUpAt = 0;

  // Lift the app's spinner once, when there is something to see.
  function announce() {
    if (announced) return;
    announced = true;
    post("playing");
  }

  function post(msg) {
    try { AppPlayer.postMessage(msg); } catch (e) {}
  }

  // What the player does about trouble, for the app's log (adb logcat).
  function log(msg) {
    post("log:" + msg);
  }

  // The Flutter-side cover is composited over a platform view, which lets the
  // page through for about a frame. Blanking it from inside the page as well
  // means the notice is never painted at all.
  function hidePage() {
    try {
      if (document.getElementById("appHide")) return;
      var st = document.createElement("style");
      st.id = "appHide";
      st.textContent = "html{visibility:hidden!important;background:#000!important}";
      (document.head || document.documentElement).appendChild(st);
    } catch (e) {}
  }

  function showPage() {
    try {
      var st = document.getElementById("appHide");
      if (st && st.parentNode) st.parentNode.removeChild(st);
    } catch (e) {}
  }

  // The mouse moving over the video, or a tap on it: the app shows its title
  // bar for a moment. (The page, not the app, gets these over the video.)
  var lastPointer = 0;
  function pointer() {
    var now = Date.now();
    if (now - lastPointer < 300) return;
    lastPointer = now;
    post("pointer");
  }
  window.addEventListener("pointermove", function (e) { if (e.pointerType === "mouse") pointer(); }, true);
  window.addEventListener("pointerdown", pointer, true);

  // On desktop the web view keeps keyboard focus once clicked, so the app
  // never sees its shortcuts; pass them on.
  window.addEventListener("keydown", function (e) {
    if (e.repeat || e.ctrlKey || e.altKey || e.metaKey) return;
    var k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    if (k === "Escape" || k === "m" || k === "f") { e.preventDefault(); post("key:" + k); }
  }, true);

  // Back online after a dead zone: the app reloads straight away rather than
  // waiting for its next retry.
  window.addEventListener("online", function () { post("online"); });

  hidePage();
  // The page can replace its own <head>; keep the blanking in place until we
  // decide what to do.
  setInterval(function () { if (!window.__appPlayer.built && !window.__appPlayer.revealed) hidePage(); }, 100);

  // The page requests the playlist itself; we read it back off the resource
  // timeline, which works however late we are injected. The first one: where
  // the page's own player runs (WebView2), it goes on to fetch the quality it
  // picked, and taking that last one pinned us to its choice (see build()).
  function findUrl() {
    try {
      var e = performance.getEntriesByType("resource");
      for (var i = 0; i < e.length; i++) {
        if (e[i].name.indexOf(".m3u8") !== -1) return e[i].name;
      }
    } catch (err) {}
    return null;
  }

  function loadHls() {
    return new Promise(function (res, rej) {
      if (OurHls) return res();
      var el = document.createElement("script");
      el.src = HLS_SRC;
      el.onload = function () { OurHls = window.Hls; res(); };
      el.onerror = function () { rej(new Error("hls.js failed to load")); };
      (document.head || document.documentElement).appendChild(el);
    });
  }

  function isBuffered(t) {
    for (var i = 0; i < video.buffered.length; i++) {
      if (t >= video.buffered.start(i) && t <= video.buffered.end(i)) return true;
    }
    return false;
  }

  // Start of the first buffered stretch after t, or -1.
  function nextBufferedStart(t) {
    for (var i = 0; i < video.buffered.length; i++) {
      if (video.buffered.start(i) > t) return video.buffered.start(i);
    }
    return -1;
  }

  // These are live feeds, so being anywhere but the live edge is a bug. Only
  // ever forward: a jump back replays what was just seen, and a stream stuck at
  // one spot would then play the same seconds over and over. True if it moved.
  function toLiveEdge() {
    if (!video) return false;
    try {
      var now = video.currentTime;
      var b = video.buffered;
      var to = -1;
      // Some feeds carry timestamps that throw hls.js's live position off (it
      // has pointed hours past the buffer, or back into stale data), so only
      // trust it once there is a buffer to check it against.
      if (hls && hls.liveSyncPosition > 0 && (b.length === 0 || isBuffered(hls.liveSyncPosition))) {
        to = hls.liveSyncPosition;
      } else if (b.length) {
        var last = b.length - 1;
        to = Math.max(b.start(last), b.end(last) - 3);
      } else if (video.seekable.length) {
        to = Math.max(0, video.seekable.end(video.seekable.length - 1) - 1);
      }
      if (to > now + 0.5) {
        video.currentTime = to;
        return true;
      }
    } catch (e) {}
    return false;
  }

  // Fallen well behind live while playing on (a network blip it got over by
  // itself, or the app coming back from the background): rejoin live.
  // hls.latency is how far behind the playlist's edge we are; on feeds whose
  // timestamps throw that off it reads absurd values, so only act on a
  // plausible one.
  function catchUp() {
    if (!hls || !hls.targetLatency || Date.now() - caughtUpAt < 10000) return;
    var behind = hls.latency - hls.targetLatency;
    if (behind > 12 && behind < 120 && hls.liveSyncPosition > video.currentTime) {
      caughtUpAt = Date.now();
      log("behind live by " + Math.round(behind) + "s, catching up");
      video.currentTime = hls.liveSyncPosition;
    }
  }

  // For the app, when it comes back from the background.
  window.__appPlayer.toLive = function () {
    if (!video) return false;
    toLiveEdge();
    catchUp();
    video.play().catch(function () {});
    return true;
  };

  function play() {
    video.muted = false;
    video.play().catch(function () {
      // Autoplay with sound refused: fall back to muted so something shows.
      video.muted = true;
      video.play().catch(function () {});
    });
  }

  // Where the page's own player did start, it keeps streaming into a detached
  // video after we replace the page, doubling the download. Shut it down.
  function stopPagePlayer() {
    try { if (typeof jwplayer === "function") jwplayer().remove(); } catch (e) {}
  }

  function build(url) {
    stopPagePlayer();
    document.documentElement.innerHTML =
      "<head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body></body>";
    document.body.style.cssText = "margin:0;padding:0;background:#000;overflow:hidden";

    video = document.createElement("video");
    video.id = "appPlayer";
    video.autoplay = true;
    video.playsInline = true;
    video.setAttribute("playsinline", "");
    video.style.cssText = "width:100vw;height:100vh;object-fit:contain;background:#000";
    // Without a poster, Android's WebView paints a big grey play button until
    // the first frame arrives. A transparent one leaves the black background.
    video.poster = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7";
    video.addEventListener("playing", announce);
    document.body.appendChild(video);
    video.addEventListener("volumechange", function () {
      post(video.muted ? "muted" : "unmuted");
    });

    if (hls) { try { hls.destroy(); } catch (e) {} }
    // Not low-latency HLS, and these feeds carry ad discontinuities, so keep a
    // real buffer rather than hugging the edge.
    // Where a source offers several qualities, start at the best and only step
    // down if the connection can't keep up. hls.js otherwise starts from a
    // cautious 0.5 Mbps guess (the lowest quality), and the playlists overstate
    // their bitrates (a "1080p, 8 Mbps" that is really 720p at ~4), so it
    // rarely climbed back: judge by what segments really weigh instead.
    hls = new OurHls({
      liveSyncDurationCount: 3,
      backBufferLength: 30,
      abrEwmaDefaultEstimate: 20e6,
      abrMaxWithRealBitrate: true,
    });
    hls.loadSource(url);
    hls.attachMedia(video);
    hls.on(OurHls.Events.MANIFEST_PARSED, function () { toLiveEdge(); play(); });
    fragStats = [];
    frames0 = null;
    fpsMax = 0;
    streamFps = 0;
    // Frames in a segment over its length: the stream's real frame rate, however
    // fast this device decodes (a slow one drops frames and would read low).
    hls.on(OurHls.Events.FRAG_PARSING_DATA, function (_, d) {
      try {
        var secs = d.endDTS - d.startDTS;
        if (d.type === "video" && d.nb > 0 && secs > 0) streamFps = d.nb / secs;
      } catch (e) {}
    });
    hls.on(OurHls.Events.FRAG_LOADED, function (_, d) {
      try {
        var bytes = (d.payload && d.payload.byteLength) || (d.frag.stats && d.frag.stats.loaded) || 0;
        if (bytes > 0 && d.frag.duration > 0) {
          fragStats.push([bytes, d.frag.duration]);
          if (fragStats.length > 5) fragStats.shift();
        }
        // A segment that took longer to fetch than to play: the player is
        // falling behind the feed, and will pause for it.
        var ms = d.frag.stats.loading.end - d.frag.stats.loading.start;
        if (ms > d.frag.duration * 1000) log("slow segment: " + Math.round(ms) + "ms for " + d.frag.duration.toFixed(1) + "s");
      } catch (e) {}
    });
    hls.on(OurHls.Events.ERROR, function (_, d) {
      log((d.fatal ? "fatal " : "") + d.type + " " + d.details);
      if (!d.fatal) return;
      if (d.type === OurHls.ErrorTypes.NETWORK_ERROR) { try { hls.startLoad(); } catch (e) {} }
      else if (d.type === OurHls.ErrorTypes.MEDIA_ERROR) {
        // Once, this clears a decoding hiccup. Again soon after, it's the same
        // spot failing each time: recovering reloads from where it was, so it
        // would play the same segment over and over. Have the app start
        // afresh at live instead.
        if (Date.now() - mediaRecoveredAt < 30000) { post("fatal"); return; }
        mediaRecoveredAt = Date.now();
        try { hls.recoverMediaError(); } catch (e) {}
      }
      else { post("fatal"); }
    });
    lastTime = -1;
    stalledFor = 0;
    lastProgressAt = Date.now();
    play();
    window.__appPlayer.built = true;
  }

  function takeOver(url) {
    window.__appPlayer.url = url;
    loadHls().then(function () {
      if (!OurHls || !OurHls.isSupported()) return post("unsupported");
      build(url);
    }, function () { post("hls-load-failed"); });
  }

  // What's actually playing, for the app to show and remember: resolution from
  // the video, frame rate from the stream's segments (or, failing that, the
  // frames it decodes over ~4s of playback), bitrate from the recent segments'
  // sizes over their lengths. Nothing extra is downloaded.
  function measure() {
    if (!video || video.paused || !video.videoHeight || !video.getVideoPlaybackQuality) return;
    // Only while it's actually playing on; a stall would read as a low frame rate.
    if (Date.now() - lastProgressAt > 1500) { frames0 = null; return; }
    var n = video.getVideoPlaybackQuality().totalVideoFrames;
    var t = performance.now();
    if (!frames0 || n < frames0.n) { frames0 = { n: n, t: t }; return; }
    if (t - frames0.t < 4000) return;
    // A slow decoder drops frames, so a window can read low but never high:
    // the stream's frame rate is the highest seen.
    fpsMax = Math.max(fpsMax, (n - frames0.n) * 1000 / (t - frames0.t));
    frames0 = { n: n, t: t };
    var fps = streamFps > 0 ? streamFps : fpsMax;
    var best = Math.round(fps);
    var std = [24, 25, 30, 50, 60];
    for (var i = 0; i < std.length; i++) if (Math.abs(fps - std[i]) / std[i] < 0.1) best = std[i];
    var bytes = 0, secs = 0;
    for (var j = 0; j < fragStats.length; j++) { bytes += fragStats[j][0]; secs += fragStats[j][1]; }
    if (!secs) return;
    // Every window, changed or not: the app averages the bitrate over them.
    // Adaptive: the source offers several qualities and hls.js moves between them.
    var adaptive = !!(hls && hls.levels && hls.levels.length > 1);
    post("quality:" + JSON.stringify({ h: video.videoHeight, fps: best, mbps: Math.round(bytes * 8 / secs / 1e5) / 10, a: adaptive }));
  }

  function watch() {
    // The page script may still wipe the body; put our player back if so.
    if (!document.getElementById("appPlayer")) { build(window.__appPlayer.url); return; }
    if (video.paused) { lastProgressAt = Date.now(); return; }
    // Progress is the video playing on at normal speed: about half a second
    // per check (more if timers run late). Our own seeks don't count, and
    // since the jump to live below never jumps back with nothing ahead, a
    // stream that has run dry can't replay its last seconds as "progress".
    var moved = video.currentTime - lastTime;
    if (lastTime >= 0 && moved > 0 && moved < 3) lastProgressAt = Date.now();
    if (video.currentTime === lastTime) {
      stalledFor += 1;
      // Nothing for 20s, beyond what the retries and hops below fix: the
      // stream link has likely expired, or the network is gone. The app loads
      // the page again for a fresh link, once the network is back.
      if (announced && Date.now() - lastProgressAt > 20000) {
        lastProgressAt = Date.now();
        post("stalled");
      }
      // Stuck at a hole in the buffer with newer data past it: hop over it.
      var next = nextBufferedStart(video.currentTime);
      if (stalledFor >= 2 && next >= 0) { stalledFor = 0; video.currentTime = next + 0.1; return; }
      // ~4s without progress: skip whatever we are stuck on and rejoin live --
      // if there is newer video to rejoin. With nothing buffered ahead (no
      // network), jumping would only replay the last seconds over and over.
      var b = video.buffered;
      var ahead = b.length ? b.end(b.length - 1) - video.currentTime : 0;
      if (stalledFor >= 8 && ahead > 1) {
        stalledFor = 0;
        // Stuck again soon after the last push: this stretch won't play (a
        // bad segment). Have the app load the stream afresh, at live.
        if (Date.now() - forcedAt < 15000) {
          forcedAt = 0;
          log("stuck again at " + video.currentTime.toFixed(1) + ", starting afresh");
          post("stalled");
          return;
        }
        forcedAt = Date.now();
        log("stuck at " + video.currentTime.toFixed(1) + " with " + ahead.toFixed(1) + "s buffered ahead");
        // Rejoin live if that's ahead, otherwise just step past the spot.
        if (!toLiveEdge()) video.currentTime = Math.min(video.currentTime + 1, b.end(b.length - 1) - 0.5);
        video.play().catch(function () {});
      }
    } else {
      stalledFor = 0;
      lastTime = video.currentTime;
      catchUp();
    }
  }

  // Some sources (e.g. golf) put the real player in a nested cross-origin
  // iframe, which we can neither read nor take over. The page's own 1x1
  // /ad.html iframe does not count.
  function hasForeignPlayer() {
    var f = document.querySelectorAll("iframe[src]");
    for (var i = 0; i < f.length; i++) {
      if (f[i].src.indexOf("/ad.html") !== -1) continue;
      if (f[i].clientWidth > 100 && f[i].clientHeight > 100) return true;
    }
    return false;
  }

  // The page replaces itself with this notice when its own player gives up.
  // It can appear before we find the playlist, so it only counts once we have
  // waited a while without one.
  function pageGaveUp() {
    // textContent, not innerText: we blank the page with visibility:hidden,
    // and innerText is layout-aware so it comes back empty.
    var t = (document.body && document.body.textContent) || "";
    return t.indexOf("Remove sandbox") !== -1;
  }

  var tries = 0;
  var settled = false;
  var deadFor = 0;
  setInterval(function () {
    if (window.__appPlayer.built) {
      watch();
      measure();
      // Took over, but the feed never actually started: say so rather than
      // leave a black screen up.
      if (video && video.readyState === 0 && !settled) {
        if (++deadFor > 30) { settled = true; post("fatal"); }
      } else {
        deadFor = 0;
      }
      // Frames are loaded but it has not started (e.g. autoplay refused):
      // after ~5s show it anyway rather than spin forever.
      if (!announced && video && video.readyState >= 2 && ++waitingFor > 10) announce();
      return;
    }
    var u = findUrl();
    if (u) { takeOver(u); return; }
    if (settled) return;
    // Give the page ~10s to produce a playlist before judging it.
    if (++tries < 20) return;
    // Nothing watchable: the Flutter side puts its own message up, so leave
    // the page blanked rather than flashing the notice.
    if (pageGaveUp()) { settled = true; post("blocked"); return; }
    // A big cross-origin iframe means the real player is nested somewhere we
    // cannot reach (e.g. the golf source, which goes embed.st -> rockystream.st
    // -> embed.st again). Those inner pages are gated too and render the same
    // red notice, which we cannot read or hide from out here -- so stay blanked
    // and show our own message instead. If a nested source ever does work, this
    // is the branch to relax.
    if (hasForeignPlayer()) { settled = true; post("blocked"); return; }
    if (tries > 40) { settled = true; post("no-stream"); }
  }, 500);
})();
''';
// Native channel for Android PiP
const MethodChannel _pip = MethodChannel('pip');
// The Windows runner's fullscreen (windows/runner/flutter_window.cpp).
const MethodChannel _window = MethodChannel('sports/window');

class StreamPlayerScreen extends StatefulWidget {
  const StreamPlayerScreen({super.key, required this.stream, required this.title});
  final StreamInfo stream;
  final String title;

  @override
  State<StreamPlayerScreen> createState() => _StreamPlayerScreenState();
}

class _StreamPlayerScreenState extends State<StreamPlayerScreen> with WidgetsBindingObserver {
  late final Uri _allowedUri;
  late final PlayerWebView _web;

  bool _inPip = false;
  bool _muted = false;
  // Desktop only: the window itself is fullscreen (no title bar or taskbar).
  bool _fullscreen = false;
  // The embed page shows its own broken-player message before we take over,
  // so keep it covered until our player reports back.
  bool _ready = false;
  // Takeover failed and the page has nothing watchable of its own, so it is
  // just showing its red notice. Cover that with something presentable.
  bool _failed = false;

  // Healing: once the stream has played, a stall or failure (a dead zone on
  // mobile, an expired link) doesn't end it. While streamed.pk can't be
  // reached the app waits, checking every 10s (and at once when the page sees
  // the network return), then loads the page again for a fresh link, which
  // starts at the live edge. With the network fine, three reloads that don't
  // get it playing mean the stream itself is gone: say so, as for a stream
  // that never started.
  // What's playing (from the page), for the title bar.
  StreamQuality? _quality;
  // What the streams list keeps: the best resolution and frame rate this
  // viewing reached, with the average bitrate while at it (see _onQuality).
  int _bestHeight = 0;
  int _bestFps = 0;
  double _mbpsSum = 0;
  int _mbpsCount = 0;
  DateTime? _savedAt;
  // The title bar shows from the start until the first quality reading (so
  // what's playing gets seen), while the menu is open, and for a few seconds
  // after the mouse moves or the video is tapped (_peek), fullscreen included.
  bool _holdTitle = true;
  bool _menuOpen = false;
  bool _peek = false;
  Timer? _peekTimer;

  bool _everPlayed = false;
  bool _healing = false;
  bool _offline = false;
  int _healTries = 0;
  Timer? _healTimer;

  // Rotation/PiP resume heuristics
  DateTime? _lastPipExitAt;
  bool _wentBackground = false;

  AppLifecycleState _appState = AppLifecycleState.resumed;
  bool _suppressOrientationMarking = false;

  Orientation? _lastOrientation;
  DateTime? _lastOrientationChangeAt;

  @override
  void initState() {
    super.initState();

    // Do NOT auto-enter PiP when user leaves (Home/Recents, etc.)
    _pip.invokeMethod('setAutoPipOnUserLeave', <String, dynamic>{'enabled': false}).catchError((_) {});

    // PiP state updates
    _pip.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'pipChanged') {
        final Object? args = call.arguments;
        final bool inPip = (args is Map && args['inPip'] is bool) ? args['inPip'] as bool : false;
        if (mounted) setState(() => _inPip = inPip);

        if (inPip) {
          // Do not record orientation changes while in PiP
          _suppressOrientationMarking = true;
        } else {
          _lastPipExitAt = DateTime.now();
          // Re-enable marking on next frame after we’re out of PiP.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _suppressOrientationMarking = false;
          });
        }
      }
      return null;
    });

    // Initial PiP state
    _pip
        .invokeMethod('isInPip')
        .then((dynamic v) {
          if (mounted) setState(() => _inPip = (v == true));
        })
        .catchError((_) {});

    _allowedUri = Uri.parse(widget.stream.embedUrl);

    _web = PlayerWebView(
      url: _allowedUri,
      isAllowed: _isAllowedDestination,
      onMessage: _onPlayerMessage,
      onPageStarted: () {
        _cover();
        _inject();
      },
      onPageFinished: _inject,
    );

    // Always light status bar (icons) over black
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark, // iOS
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    // Go edge-to-edge but keep bars visible
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    WidgetsBinding.instance.addObserver(this);
  }

  void _onPlayerMessage(String message) {
    if (!mounted) return;
    if (message.startsWith('key:')) {
      _onKey(message.substring(4));
      return;
    }
    if (message.startsWith('log:')) {
      debugPrint('[player] ${message.substring(4)}');
      return;
    }
    if (message.startsWith('quality:')) {
      try {
        final Map<String, dynamic> j = jsonDecode(message.substring(8)) as Map<String, dynamic>;
        final StreamQuality q = StreamQuality(height: j['h'] as int, fps: j['fps'] as int, mbps: (j['mbps'] as num).toDouble(), adaptive: j['a'] == true);
        if (q != _quality) setState(() => _quality = q);
        // The title bar has stayed up since the start; now it has what's
        // playing to show, let it go after the usual few seconds.
        if (_holdTitle) {
          _holdTitle = false;
          _peekTitle();
        }
        _onQuality(q);
      } catch (_) {}
      return;
    }
    if (message == 'pointer') {
      _peekTitle();
      return;
    }
    if (message == 'stalled') {
      _heal();
      return;
    }
    if (message == 'online') {
      if (_healing) _healNow();
      return;
    }
    setState(() {
      // Anything other than success means we cannot do better than
      // showing the page itself, so stop covering it either way.
      if (message == 'playing' || message == 'passthrough') {
        _ready = true;
        _failed = false;
        _everPlayed = true;
        _healing = false;
        _offline = false;
        _healTries = 0;
        _healTimer?.cancel();
      } else if (message == 'muted') {
        _muted = true;
      } else if (message == 'unmuted') {
        _muted = false;
      } else if (_everPlayed) {
        // Stopped after playing, or a healing reload that didn't get a stream
        // (the next try is already scheduled).
        if (!_healing) WidgetsBinding.instance.addPostFrameCallback((_) => _heal());
      } else {
        // no-stream / fatal / unsupported / hls-load-failed
        _failed = true;
      }
    });
  }

  // The list keeps the best resolution and frame rate this viewing reached (an
  // adaptive player climbs as it measures the connection, and a dip just before
  // leaving shouldn't stick), with the average bitrate while at that level: the
  // stream's typical rate, not whatever the last few seconds happened to be.
  // Each viewing starts afresh, in case the site swaps the feed behind a stream.
  void _onQuality(StreamQuality q) {
    final bool better = q.height > _bestHeight || (q.height == _bestHeight && q.fps > _bestFps);
    if (better) {
      _bestHeight = q.height;
      _bestFps = q.fps;
      _mbpsSum = 0;
      _mbpsCount = 0;
    }
    if (q.height != _bestHeight || q.fps != _bestFps) return;
    _mbpsSum += q.mbps;
    _mbpsCount++;
    // Readings come every few seconds; save when the level changes and every
    // half minute, and once more on leaving (dispose).
    if (better || _savedAt == null || DateTime.now().difference(_savedAt!) > const Duration(seconds: 30)) _saveQuality();
  }

  void _saveQuality() {
    if (_mbpsCount == 0) return;
    _savedAt = DateTime.now();
    StreamQuality(height: _bestHeight, fps: _bestFps, mbps: (_mbpsSum / _mbpsCount * 10).round() / 10, adaptive: _quality?.adaptive ?? false).save(widget.stream.embedUrl);
  }

  void _peekTitle() {
    if (!mounted) return;
    if (!_peek) setState(() => _peek = true);
    _peekTimer?.cancel();
    _peekTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _peek = false);
    });
  }

  void _heal() {
    if (!mounted || _healing) return;
    setState(() => _healing = true);
    _healNow();
  }

  Future<void> _healNow() async {
    _healTimer?.cancel();
    final bool online = await _siteReachable();
    if (!mounted || !_healing) return;
    if (online && _healTries >= 3) {
      setState(() {
        _healing = false;
        _offline = false;
        _failed = true;
      });
      return;
    }
    setState(() => _offline = !online);
    if (online) {
      _healTries++;
      _refresh();
    }
    // Offline: look again in 10s. Online: give the reload time to start,
    // longer each time (20s, 40s, 60s).
    final Duration wait = online ? Duration(seconds: 20 * _healTries) : const Duration(seconds: 10);
    _healTimer = Timer(wait, () {
      if (mounted && _healing) _healNow();
    });
  }

  // Whether the stream site answers at all (any status will do).
  Future<bool> _siteReachable() async {
    try {
      await http.head(Uri.parse('https://streamed.pk/')).timeout(const Duration(seconds: 6));
      return true;
    } catch (_) {
      return false;
    }
  }

  // Keyboard shortcuts, whether they reach Flutter or come from the page.
  void _onKey(String key) {
    switch (key.toLowerCase()) {
      case 'escape':
        _escape();
      case 'm':
        _toggleMute();
      case 'f':
        _setFullscreen(!_fullscreen);
    }
  }

  // Esc leaves fullscreen first, then the player.
  void _escape() {
    if (_fullscreen) {
      _setFullscreen(false);
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _setFullscreen(bool on) async {
    if (!Platform.isWindows) return;
    try {
      if (on) {
        WindowState.playerFullscreen = true;
        // Done by the runner in one step (see flutter_window.cpp): window_manager
        // leaves the title bar and taskbar up on a maximized window.
        await _window.invokeMethod<void>('setFullScreen', true);
      } else {
        await _leaveFullscreen();
      }
      if (mounted) setState(() => _fullscreen = on);
    } catch (_) {}
  }

  Future<void> _leaveFullscreen() async {
    await _window.invokeMethod<void>('setFullScreen', false);
    // Let the resize events from giving the window back settle first.
    Future<void>.delayed(const Duration(seconds: 1), () => WindowState.playerFullscreen = false);
  }

  void _inject() {
    _web.runJavaScript(_takeoverJs).catchError((_) {});
  }

  void _cover() {
    if (!mounted) return;
    if (!_ready && !_failed) return;
    setState(() {
      _ready = false;
      _failed = false;
    });
  }

  Future<void> _toggleMute() async {
    const String js = '(function(){var v=document.getElementById("appPlayer");if(!v)return "none";v.muted=!v.muted;if(!v.muted)v.play().catch(function(){});return v.muted?"muted":"unmuted";})();';
    try {
      final Object? res = await _web.runJavaScriptReturningResult(js);
      final String r = res.toString().replaceAll('"', '');
      if (mounted && r != 'none') setState(() => _muted = r == 'muted');
    } catch (_) {}
  }

  Future<void> _enterPip() async {
    try {
      final dynamic ok = await _pip.invokeMethod('enterPip');
      if (mounted && ok == true) {
        setState(() => _inPip = true);
      }
    } catch (_) {
      // Swallow; PiP might not be supported or OS denied it.
    }
  }

  Future<void> _refresh() async {
    _cover();
    try {
      await _web.reload();
    } catch (_) {}
  }

  bool _isAllowedDestination(Uri dest) {
    // Allow only the exact same URL (hash changes ok), same origin required.
    if (dest.scheme != _allowedUri.scheme || dest.host != _allowedUri.host || dest.port != _allowedUri.port) {
      return false; // different origin
    }
    final String baseAllowed = _allowedUri.replace(fragment: null).toString();
    final String baseDest = dest.replace(fragment: null).toString();
    return baseDest == baseAllowed;
  }

  @override
  void dispose() {
    // Disable auto-PiP when leaving this screen
    _pip.invokeMethod('setAutoPipOnUserLeave', <String, dynamic>{'enabled': false}).catchError((_) {});
    WidgetsBinding.instance.removeObserver(this);
    _healTimer?.cancel();
    _peekTimer?.cancel();
    _saveQuality();
    // Leaving the player gives the window back its title bar.
    if (_fullscreen) _leaveFullscreen().catchError((_) {});
    _web.dispose();
    super.dispose();
  }

  // ——— Lifecycle: jump-to-live only for true app-resume, not rotation or PiP restore.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appState = state; // track current
    if (state == AppLifecycleState.paused) {
      _wentBackground = true;
    }
    if (state == AppLifecycleState.resumed && mounted) {
      if (!_wentBackground) return; // not a real background-resume
      _wentBackground = false;

      final DateTime now = DateTime.now();

      // Rotation heuristic: only true if we very recently *changed orientation*.
      final bool likelyRotation = _lastOrientationChangeAt != null && now.difference(_lastOrientationChangeAt!).inMilliseconds <= 900;

      // Heuristic: if resume is very close to exiting PiP, it's PiP restore
      final bool justLeftPip = _lastPipExitAt != null && now.difference(_lastPipExitAt!).inMilliseconds <= 1000;

      if (likelyRotation || justLeftPip || _inPip) return;

      _jumpToLive();
    }
  }

  Future<void> _jumpToLive() async {
    // Our player's own way back to live (see toLiveEdge and catchUp in the
    // takeover script), which knows which feeds' live positions to trust.
    const String js = '(function(){var p=window.__appPlayer;return !!(p&&p.built&&p.toLive&&p.toLive());})();';

    try {
      final Object? res = await _web.runJavaScriptReturningResult(js);
      final bool jumped = res == true;
      if (!jumped) {
        // If the page didn't expose seekable ranges, refresh to reattach at live
        await _web.reload();
      }
    } catch (_) {
      // If JS failed (cross-origin restrictions, etc.), just reload
      try {
        await _web.reload();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only record orientation changes when we're truly resumed and not in PiP,
    // and not currently suppressing due to a PiP transition.
    if (_appState == AppLifecycleState.resumed && !_inPip && !_suppressOrientationMarking) {
      final Orientation current = MediaQuery.of(context).orientation;
      if (_lastOrientation == null) {
        _lastOrientation = current;
      } else if (_lastOrientation != current) {
        _lastOrientation = current;
        _lastOrientationChangeAt = DateTime.now();
      }
    }

    // The title bar and the menu: up together, or hidden together.
    final bool chrome = _holdTitle || _menuOpen || _peek;

    // Desktop has no system back button: Esc leaves the player, M mutes and F
    // goes fullscreen. (The page forwards these too, for when the web view has
    // keyboard focus.)
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _escape,
        const SingleActivator(LogicalKeyboardKey.keyM): _toggleMute,
        const SingleActivator(LogicalKeyboardKey.keyF): () => _setFullscreen(!_fullscreen),
      },
      child: Focus(
        autofocus: true,
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.dark,
            systemNavigationBarColor: Colors.black,
            systemNavigationBarIconBrightness: Brightness.light,
          ),
          child: Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              top: false,
              bottom: false,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  const SizedBox.expand(child: _WebViewHolder()),
                  if (_failed)
                    ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const Icon(Icons.videocam_off, color: Colors.white54, size: 40),
                            const SizedBox(height: 12),
                            const Text(
                              'This stream is unavailable.',
                              style: TextStyle(color: Colors.white),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Try another stream or source.',
                              style: TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                            const SizedBox(height: 16),
                            TextButton(onPressed: _refresh, child: const Text('Retry')),
                          ],
                        ),
                      ),
                    )
                  else if (!_ready || _healing)
                    ColoredBox(
                      color: Colors.black,
                      child: Center(
                        // The spinner in the true centre whether or not there's
                        // text; the text goes under it without moving it.
                        child: Stack(
                          alignment: Alignment.center,
                          clipBehavior: Clip.none,
                          children: <Widget>[
                            const CircularProgressIndicator(color: Colors.white),
                            if (_healing)
                              Transform.translate(
                                offset: const Offset(0, 44),
                                child: Text(
                                  _offline ? 'Waiting for connection…' : 'Reconnecting…',
                                  style: const TextStyle(color: Colors.white70),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  // Desktop fullscreen: the pointer hides with the title bar, so
                  // it isn't left sitting on the picture. Over the page it's the
                  // page's cursor, and webview_windows shows any it doesn't know
                  // (CSS cursor: none included) as the arrow, so a layer of our
                  // own covers the video meanwhile; moving the mouse over it
                  // brings everything back.
                  if (_fullscreen && !chrome)
                    Positioned.fill(
                      child: MouseRegion(
                        cursor: SystemMouseCursors.none,
                        onHover: (_) => _peekTitle(),
                      ),
                    ),
                  // The game and what's playing, while the menu is open or for a
                  // moment after the mouse moves or the video is tapped. In
                  // fullscreen too, where it's the only way to see them.
                  if (!_inPip)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        ignoring: !chrome,
                        child: AnimatedOpacity(
                          opacity: chrome ? 1 : 0,
                          duration: const Duration(milliseconds: 150),
                          // The page can't see the mouse over the bar itself, so resting on
                          // it keeps it up.
                          child: MouseRegion(
                            onHover: (_) => _peekTitle(),
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.7),
                              padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 10, 16, 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: condensed(19, FontWeight.w600, color: Colors.white)),
                                  if (_quality != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(_quality!.label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // The menu comes and goes with the title bar (a tap or the mouse
            // brings both back), fullscreen included, so nothing sits on the
            // picture meanwhile. None in PiP.
            floatingActionButton: _inPip
                ? null
                : IgnorePointer(
                    ignoring: !chrome,
                    child: AnimatedOpacity(
                      opacity: chrome ? 1 : 0,
                      duration: const Duration(milliseconds: 150),
                      // The page can't see the mouse over the button, so resting
                      // on it keeps it up.
                      child: MouseRegion(
                        onHover: (_) => _peekTitle(),
                        child: SpeedDial(
                          icon: Icons.menu,
                          foregroundColor: Colors.white,
                          backgroundColor: Colors.black,
                          overlayOpacity: 0.0,
                          onOpen: () => setState(() => _menuOpen = true),
                          onClose: () {
                            setState(() => _menuOpen = false);
                            // Linger a moment rather than vanish as it closes.
                            _peekTitle();
                          },
                          buttonSize: const Size(40, 40),
                          childrenButtonSize: const Size(40, 40),
                          childPadding: const EdgeInsets.all(0),
                          spaceBetweenChildren: 5,
                          children: [
                            SpeedDialChild(
                              shape: const CircleBorder(),
                              child: Center(
                                child: Icon(_muted ? Icons.volume_off : Icons.volume_up, color: Colors.white, size: 18),
                              ),
                              backgroundColor: Colors.black,
                              onTap: _toggleMute,
                            ),
                            // Picture-in-picture is Android's; a desktop window can just be resized.
                            if (Platform.isAndroid)
                              SpeedDialChild(
                                shape: const CircleBorder(),
                                child: const Center(child: Icon(Icons.picture_in_picture, color: Colors.white, size: 15)),
                                backgroundColor: Colors.black,
                                onTap: _enterPip,
                              ),
                            SpeedDialChild(
                              shape: const CircleBorder(),
                              child: const Center(child: Icon(Icons.refresh, color: Colors.white, size: 18)),
                              backgroundColor: Colors.black,
                              onTap: () async {
                                await _refresh();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// Simple holder so Scaffold rebuilds don’t recreate controller widget unnecessarily
class _WebViewHolder extends StatelessWidget {
  const _WebViewHolder();

  @override
  Widget build(BuildContext context) {
    // This widget is intentionally empty; the actual WebView is inserted by the parent state.
    // But WebViewWidget must still be in the tree, so we find the state's controller via context.
    final _StreamPlayerScreenState? s = context.findAncestorStateOfType<_StreamPlayerScreenState>();
    return s == null ? const SizedBox.shrink() : s._web.build(context);
  }
}

// streamed.pk orders sources best-first rather than however the API returns
// them, and demotes the weaker ones. Mirror that order (sourceOrder, from
// shared/app_data.json; we show them all, since scrolling is cheaper than
// hiding). Anything unknown sorts to the end, keeping its relative order.
int _sourceRank(String source) {
  final int i = sourceOrder.indexOf(source.toLowerCase());
  return i == -1 ? sourceOrder.length : i;
}
