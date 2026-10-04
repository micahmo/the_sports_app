sub init()
    m.top.functionName = "work"
end sub

sub say(s as String)
    print "[stream] "; s
    m.top.status = s
end sub

sub fail(s as String)
    print "[stream] error: "; s
    m.top.error = s
end sub

sub work()
    m.driver = m.top.driver
    m.sid = ""
    m.quitting = false
    ' For measure(): segment lengths from the playlists, recent bitrates, and
    ' what the first segments showed.
    m.segDur = {}
    ' Segment downloads (see "segments" below): by URL, which transfer belongs to
    ' which URL, what's already been served, and a counter for file names.
    m.dl = {}
    m.xferOf = {}
    m.served = {}
    m.fileSeq = 0
    ' A download still running this long gets a second copy (shared with the
    ' phone and desktop apps, shared/app_data.json).
    m.stuckMs = appPlayer().stuckDownloadMs
    m.bitrates = []
    m.measured = 0
    m.height = 0
    m.fps = 0
    ' The last good playlist, and a new link being found (see playlist()).
    m.lastPlaylist = invalid
    ' The segments the player is offered, kept longer than the source lists
    ' them (see longerWindow()).
    m.win = invalid
    ' The playlist fetch under way (see askPlaylist) and the player's requests
    ' waiting on it.
    m.plFetch = invalid
    m.plWaiters = []
    m.minter = invalid
    m.mintTry = invalid
    m.port = CreateObject("roMessagePort")
    m.top.observeField("quit", m.port)

    ' Anything a previous run of the app left open (Home kills it mid-stream).
    ' Only the first stream of a run does this: after that, the remembered
    ' session can belong to a stream that's still winding down (a reconnect
    ' overlapping a slow fetch), and closing it under that stream crashed it.
    ' Streams close their own sessions when they finish.
    if not m.global.sessionsTidied then
        m.global.sessionsTidied = true
        closeRememberedSession()
    end if

    ' No internet (the server on the LAN may still answer): the player waits
    ' and tries again rather than counting this as the stream failing.
    if not siteReachable() then
        print "[stream] streamed.pk unreachable"
        m.top.error = "offline"
        return
    end if

    ' A link that doesn't answer may just be on one of the source's servers
    ' that has dropped the stream; a fresh session usually gets another. Three
    ' tries before calling the stream unavailable.
    for try = 1 to 3
        say("Starting a browser on the server...")
        if not openSession() then
            fail("Couldn't start a browser on " + m.driver + ".")
            return
        end if
        say("Loading the stream...")
        if not findPlaylist() then
            if not m.quitting then fail("The stream page didn't provide a playlist. Try another stream.")
            cleanup()
            return
        end if
        if pickMedia() then exit for
        cleanup()
        ' A stream that isn't broadcasting still hands over a playlist URL, which
        ' then answers "Not found". Say so, as the phone app does, rather than
        ' let the player fail with "an unexpected problem".
        if try = 3 or quitRequested() then
            if not m.quitting then fail("This stream is unavailable. Try another stream or source.")
            return
        end if
        print "[stream] the link didn't answer: trying a fresh session"
    end for
    serve()
    cleanup()
end sub

function siteReachable() as Boolean
    x = CreateObject("roUrlTransfer")
    x.SetUrl("https://streamed.pk/")   ' apiBase() in common.brs, which tasks don't load
    x.SetCertificatesFile("common:/certs/ca-bundle.crt")
    x.InitClientCertificates()
    port = CreateObject("roMessagePort")
    x.SetMessagePort(port)
    if not x.AsyncHead() then return false
    ev = wait(6000, port)
    if type(ev) <> "roUrlEvent" then
        x.AsyncCancel()
        return false
    end if
    ' Any HTTP status means it answered; negative codes are connection failures.
    return ev.GetResponseCode() > 0
end function

sub cleanup()
    if m.sid <> "" then closeSession(m.driver, m.sid)
    m.sid = ""
end sub

' ---- playlists --------------------------------------------------------------

' A playlist fetched by the page itself, with its entries pointed at this proxy.
' When the link stops working, a fresh one is found in the background
' (startMint) and the player gets the last good playlist meanwhile: it plays on
' through what it has, and carries on from the new link, which lists the same
' segments, without noticing. (Some sources' servers drop a stream every few
' minutes; reloading the page in the same session only gave the dead link back.)
function playlist(url as String) as Dynamic
    text = fetchInPage(url)
    if text = invalid then return invalid
    return rewritePlaylist(url, text)
end function

' The source's playlist with its entries pointed at this proxy.
function rewritePlaylist(url as String, text as String) as String
    main = (url = m.playlistUrl)
    esc = CreateObject("roUrlTransfer")
    out = []
    ' Each segment's length (its #EXTINF), for measure().
    if m.segDur.Count() > 100 then m.segDur = {}
    dur = 0
    segs = []
    for each line in text.Split(Chr(10))
        line = line.Trim()
        if Left(line, 8) = "#EXTINF:" then dur = Val(Mid(line, 9))
        if line <> "" and Left(line, 1) <> "#" then
            target = resolve(url, line)
            if Instr(1, LCase(target), ".m3u8") > 0 then
                line = "/pl?u=" + esc.Escape(target)
            else
                line = "/seg?u=" + esc.Escape(target)
                m.segDur[target] = dur
                segs.Push(target)
            end if
        end if
        out.Push(line)
    end for
    prefetch(segs)
    if main then out = longerWindow(out)
    result = out.Join(Chr(10)) + Chr(10)
    if main then m.lastPlaylist = result
    return result
end function

' The playlist the player gets lists the last 45 s of segments, not just the
' few the source lists (some list only 12 s). With a high-bitrate stream the
' player's buffer fills before it holds that many seconds, so it asks for its
' next segment late; by then the source had dropped it from the list, and the
' player skipped ahead and froze the picture for as long, once a minute (a
' 12.5 Mbps admin stream, 2026-10-04). The source's servers still have the
' segments, so a late one is fetched as usual. Starts over when the link
' changes or the numbering jumps, and leaves alone playlists with anything
' this doesn't follow (discontinuities, an end).
'
' It also keeps the cushion a flaky stream earns: after a hang the player
' carries on from where it paused, behind live by the hang, and the segments
' it hasn't played stay listed, so the next hang plays through. (45 s leaves
' room for that and the player's own ~12 s; see PlayerScreen's holdBack for
' the cushion after a reconnect.)
function longerWindow(lines as Object) as Object
    keepSeconds = 45
    header = []
    items = []
    tags = []
    seq = -1
    for each line in lines
        if Left(line, 22) = "#EXT-X-MEDIA-SEQUENCE:" then seq = Mid(line, 23).Trim().ToInt()
        if Instr(1, line, "DISCONTINUITY") > 0 or line = "#EXT-X-ENDLIST" then
            m.win = invalid
            return lines
        end if
        if line = "" then
            ' (blank lines carry nothing)
        else if Left(line, 1) <> "#" then
            tags.Push(line)
            items.Push({lines: tags, dur: m.segDur[segTarget(line)]})
            tags = []
        else if items.Count() = 0 and Left(line, 8) <> "#EXTINF:" and Left(line, 25) <> "#EXT-X-PROGRAM-DATE-TIME:" then
            header.Push(line)
        else
            tags.Push(line)
        end if
    end for
    if seq < 0 or items.Count() = 0 then
        m.win = invalid
        return lines
    end if
    ' Carry on from what's kept. The player gets our own numbering, one after
    ' another, so a jump in the source's never empties the list: when a slow
    ' answer meant we missed a segment or two, the player loses just those, not
    ' the older ones it's still playing (an emptied list made it skip, then again
    ' a minute later, 2026-10-04). Starts over only if the numbering restarts.
    w = m.win
    if w <> invalid then
        last = w.lastSrc
        if seq + items.Count() - 1 < last - 100 or seq > last + 100 then
            print "[stream] playlist numbering restarted: starting the list over"
            w = invalid
        else if seq > last + 1 then
            missed = seq - last - 1
            print "[stream] playlist: missed "; missed; " segment(s) while the source was slow"
            w.offset = w.offset - missed
        end if
    end if
    if w = invalid then w = {offset: 0, lastSrc: seq - 1, items: []}
    for i = 0 to items.Count() - 1
        src = seq + i
        if src > w.lastSrc then
            it = items[i]
            it.seq = src + w.offset
            w.items.Push(it)
            w.lastSrc = src
        end if
    end for
    total = 0
    for each it in w.items
        if it.dur <> invalid then total = total + it.dur
    end for
    while w.items.Count() > 1 and w.items[0].dur <> invalid and total - w.items[0].dur >= keepSeconds
        total = total - w.items[0].dur
        w.items.Shift()
    end while
    m.win = w
    out = []
    for each line in header
        if Left(line, 22) = "#EXT-X-MEDIA-SEQUENCE:" then line = "#EXT-X-MEDIA-SEQUENCE:" + w.items[0].seq.ToStr()
        out.Push(line)
    end for
    for each it in w.items
        out.Append(it.lines)
    end for
    return out
end function

' The source's address in one of our /seg?u= lines.
function segTarget(line as String) as String
    return CreateObject("roUrlTransfer").Unescape(Mid(line, 8))
end function

' The player asked for the playlist. It gets the source's newest if that comes
' within a moment (it takes ~100 ms), else the last good one: the source is
' sometimes slow to answer (17 s, several times on 2026-10-04), and waiting
' held up the whole proxy, so the player couldn't get even the segments it had
' in hand and showed the spinner. Now it plays on through what it has. A fetch
' that fails twice finds a new link, as before. Starting, it waits for the
' first.
function askPlaylist(sock as Object) as Boolean
    if m.plFetch = invalid then startPlaylistFetch(false)
    at = invalid
    if m.lastPlaylist <> invalid then at = CreateObject("roTimespan")
    m.plWaiters.Push({sock: sock, at: at})
    return false
end function

sub startPlaylistFetch(retry as Boolean)
    js = fetchScript()
    x = CreateObject("roUrlTransfer")
    x.SetMessagePort(m.port)
    x.SetUrl(m.driver + "/session/" + m.sid + "/execute/async")
    x.AddHeader("Content-Type", "application/json")
    x.RetainBodyOnError(true)
    x.SetRequest("POST")
    f = {x: x, id: x.GetIdentity().ToStr(), url: m.playlistUrl, started: CreateObject("roTimespan"), retry: retry, slow: false}
    m.plFetch = f
    if not x.AsyncPostFromString(FormatJson({script: js, args: [m.playlistUrl]})) then playlistFetched(f, invalid)
end sub

' Every turn of the loop: a fetch with no answer in 8 s has failed, and a
' player that has waited 1.5 s gets the last playlist.
sub checkPlaylist()
    f = m.plFetch
    if f <> invalid and f.started.TotalMilliseconds() > 8000 then
        f.x.AsyncCancel()
        print "[stream] playlist fetch: no reply from the server"
        playlistFetched(f, invalid)
        return
    end if
    if m.lastPlaylist = invalid then return
    keep = []
    for each w in m.plWaiters
        if w.at <> invalid and w.at.TotalMilliseconds() > 1500 then
            if f <> invalid and not f.slow then
                f.slow = true
                print "[stream] playlist slow: serving the last one meanwhile"
            end if
            answerPlaylist(w.sock, m.lastPlaylist)
        else
            keep.Push(w)
        end if
    end for
    m.plWaiters = keep
end sub

' The page's answer (from the loop's roUrlEvent): the playlist's text or invalid.
sub onPlaylistEvent(ev as Object)
    if ev.GetInt() <> 1 then return
    f = m.plFetch
    text = invalid
    json = ParseJson(ev.GetString())
    v = invalid
    if json <> invalid then v = json.value
    if not isString(v) then
        if v = invalid then print "[stream] playlist fetch: no reply from the server" else print "[stream] playlist fetch: "; Left(FormatJson(v), 200)
    else
        nl = Instr(1, v, Chr(10))
        body = Mid(v, nl + 1)
        if nl = 0 or Left(v, nl - 1) <> "200" or Left(body, 7) <> "#EXTM3U" then
            print "[stream] playlist fetch: "; Left(v, 60)
        else
            text = body
        end if
    end if
    playlistFetched(f, text)
end sub

sub playlistFetched(f as Object, text as Dynamic)
    m.plFetch = invalid
    if quitRequested() then return
    ' The link changed meanwhile: ask the new one.
    if f.url <> m.playlistUrl then
        if m.plWaiters.Count() > 0 then startPlaylistFetch(false)
        return
    end if
    if text = invalid then
        if not f.retry then
            print "[stream] retrying playlist fetch"
            startPlaylistFetch(true)
            return
        end if
        startMint()
        if m.lastPlaylist <> invalid then print "[stream] serving the last playlist while a new link is found"
        result = m.lastPlaylist
    else
        result = rewritePlaylist(f.url, text)
        print "[stream] playlist "; f.started.TotalMilliseconds(); " ms"
    end if
    for each w in m.plWaiters
        answerPlaylist(w.sock, result)
    end for
    m.plWaiters = []
end sub

sub answerPlaylist(sock as Object, text as Dynamic)
    if text = invalid then
        respond(sock, "502 Bad Gateway", "text/plain", invalid)
    else
        ba = CreateObject("roByteArray")
        ba.FromAsciiString(text)
        respond(sock, "200 OK", "application/vnd.apple.mpegurl", ba)
    end if
    sock.Close()
end sub

' A new link from a fresh browser session (MintTask), while this one keeps
' serving. One at a time, and not more often than every 10 seconds.
sub startMint()
    if m.minter <> invalid or quitRequested() then return
    if m.mintTry <> invalid and m.mintTry.TotalSeconds() < 10 then return
    m.mintTry = CreateObject("roTimespan")
    print "[stream] the link stopped working: finding a new one"
    m.minter = CreateObject("roSGNode", "MintTask")
    m.minter.driver = m.driver
    ' The page this session plays (for a nested source, the inner one already
    ' found), so the minter doesn't look it up again.
    m.minter.embedUrl = pageUrl()
    m.minter.observeField("result", m.port)
    m.minter.control = "run"
end sub

' The new link, if there is one: use it and its session from here on.
sub onMinted(r as Object)
    m.minter = invalid
    if r = invalid or r.sid = invalid then
        print "[stream] couldn't find a new link"
        return
    end if
    old = m.sid
    m.sid = r.sid
    m.playlistUrl = r.url
    rememberSession(m.driver, m.sid)
    closeSession(m.driver, old)
    print "[stream] switched to a new link after "; m.mintTry.TotalMilliseconds(); " ms: "; Left(m.playlistUrl, 40)
end sub

' ---- segments ---------------------------------------------------------------

' Segments download in the background, so the proxy can serve other requests
' meanwhile. The newest few start as soon as a playlist lists them, before the
' player asks: a live stream plays near its newest segment, so the player holds
' only a segment or two, and one slow download (the 1080p sources' servers
' sometimes take ~11 s over a 6 s segment) was enough to run it dry. A download
' that takes longer than 4 s gets a second copy running alongside, and whichever
' finishes first is served: those slow downloads look like a request stuck on
' the server, not a slow network.

' The newest few of a playlist's segments: start any not already downloading.
sub prefetch(segs as Object)
    first = segs.Count() - 3
    if first < 0 then first = 0
    for i = first to segs.Count() - 1
        u = segs[i]
        if m.dl[u] = invalid and m.served[u] = invalid then startDownload(u)
    end for
end sub

function startDownload(u as String) as Object
    ' asked: when the player asked, if it had to wait; active: copies running.
    d = {url: u, xfers: [], started: CreateObject("roTimespan"), done: false, file: "", took: 0, waiters: [], asked: invalid, hedged: false, active: 0, retries: 0}
    m.dl[u] = d
    addTransfer(d)
    return d
end function

' Another copy of a segment's download, into its own file.
sub addTransfer(d as Object)
    m.fileSeq = m.fileSeq + 1
    path = "tmp:/seg" + m.fileSeq.ToStr() + ".bin"
    x = CreateObject("roUrlTransfer")
    x.SetUrl(d.url)
    x.SetCertificatesFile("common:/certs/ca-bundle.crt")
    x.InitClientCertificates()
    x.SetMessagePort(m.port)
    if x.AsyncGetToFile(path) then
        id = x.GetIdentity().ToStr()
        d.xfers.Push({x: x, path: path, id: id})
        d.active = d.active + 1
        m.xferOf[id] = d.url
    end if
end sub

' A download finished (or failed).
sub onDownload(ev as Object)
    if ev.GetInt() <> 1 then return
    id = ev.GetSourceIdentity().ToStr()
    u = m.xferOf[id]
    if u = invalid then return
    m.xferOf.Delete(id)
    d = m.dl[u]
    if d <> invalid then d.active = d.active - 1
    mine = invalid
    if d <> invalid then
        for each t in d.xfers
            if t.id = id then mine = t
        end for
    end if
    if mine = invalid then return
    if d.done then
        ' The other copy won.
        DeleteFile(mine.path)
        return
    end if
    if ev.GetResponseCode() = 200 then
        d.done = true
        d.file = mine.path
        d.took = d.started.TotalMilliseconds()
        for each t in d.xfers
            if t.id <> id then
                t.x.AsyncCancel()
                m.xferOf.Delete(t.id)
                DeleteFile(t.path)
            end if
        end for
        if d.hedged then
            which = "first"
            if mine.id <> d.xfers[0].id then which = "second"
            print "[stream] segment: the "; which; " copy won"
        end if
        if d.waiters.Count() > 0 then serveSegment(u)
        return
    end if
    DeleteFile(mine.path)
    if d.active > 0 then return   ' another copy is still going
    if d.retries < 2 then
        d.retries = d.retries + 1
        addTransfer(d)
        return
    end if
    print "[stream] segment FAILED after "; d.started.TotalMilliseconds(); " ms"
    for each sock in d.waiters
        respond(sock, "502 Bad Gateway", "text/plain", invalid)
        sock.Close()
    end for
    m.dl.Delete(u)
end sub

' Send a downloaded segment to whoever asked for it, then forget it.
sub serveSegment(u as String)
    d = m.dl[u]
    ba = strippedSegment(d.file)
    for each sock in d.waiters
        if ba = invalid then
            respond(sock, "502 Bad Gateway", "text/plain", invalid)
        else
            respond(sock, "200 OK", "video/mp2t", ba)
        end if
        sock.Close()
    end for
    if ba = invalid then
        print "[stream] segment FAILED (not MPEG-TS)"
    else
        ' How long the download took, and whether it was ready when the player
        ' asked (prefetched) or the player waited for it.
        how = "ready"
        if d.asked <> invalid then how = "waited " + d.asked.TotalMilliseconds().ToStr() + " ms"
        print "[stream] segment  "; ba.Count(); " bytes  "; d.took; " ms ("; how; ")"
        measure(u, ba)
    end if
    DeleteFile(d.file)
    m.dl.Delete(u)
    m.served[u] = true
    if m.served.Count() > 60 then m.served = {}
end sub

' The player asked for a segment: serve it now if it's here, else when it is.
' True if the request was answered (so the connection can close).
function askSegment(sock as Object, u as String) as Boolean
    d = m.dl[u]
    if d = invalid then d = startDownload(u)
    if d.done then
        d.waiters = [sock]
        serveSegment(u)
        return true
    end if
    d.asked = CreateObject("roTimespan")
    d.waiters.Push(sock)
    return false
end function

' Every half second: second copies for slow downloads, and cleanup.
sub tick()
    stale = []
    for each u in m.dl
        d = m.dl[u]
        if not d.done and not d.hedged and d.started.TotalMilliseconds() > m.stuckMs then
            d.hedged = true
            print "[stream] segment slow after "; d.started.TotalMilliseconds(); " ms: starting a second copy"
            addTransfer(d)
        end if
        ' Prefetched but never asked for (the player moved on): drop it.
        if d.done and d.waiters.Count() = 0 and d.started.TotalSeconds() > 90 then stale.Push(u)
    end for
    for each u in stale
        DeleteFile(m.dl[u].file)
        m.dl.Delete(u)
    end for
end sub

' A downloaded segment minus its fake WebP header: plain MPEG-TS.
function strippedSegment(path as String) as Dynamic
    size = CreateObject("roFileSystem").Stat(path).size
    if size = invalid then return invalid
    head = CreateObject("roByteArray")
    head.ReadFile(path, 0, 2048)
    off = -1
    for i = 0 to head.Count() - 377
        if head[i] = &h47 and head[i + 188] = &h47 and head[i + 376] = &h47 then
            off = i
            exit for
        end if
    end for
    if off < 0 then return invalid
    ba = CreateObject("roByteArray")
    ba.ReadFile(path, off, size - off)
    return ba
end function

sub cancelDownloads()
    for each u in m.dl
        for each t in m.dl[u].xfers
            t.x.AsyncCancel()
            DeleteFile(t.path)
        end for
        for each sock in m.dl[u].waiters
            sock.Close()
        end for
    end for
    m.dl = {}
    m.xferOf = {}
end sub

' ---- local HTTP server --------------------------------------------------------

sub serve()
    ' The first free port from a small range: the previous stream's server can
    ' still be finishing a request on its port when the next stream starts, and
    ' sharing one port would hand the player the old stream.
    srv = invalid
    for portNum = 8888 to 8911
        addr = CreateObject("roSocketAddress")
        addr.SetPort(portNum)
        s = CreateObject("roStreamSocket")
        s.SetReuseAddr(true)
        if s.SetAddress(addr) and s.Listen(8) then
            srv = s
            exit for
        end if
        s.Close()
    end for
    if srv = invalid then
        fail("Couldn't start the local stream server.")
        return
    end if
    srv.SetMessagePort(m.port)
    srv.NotifyReadable(true)
    print "[stream] serving on port "; portNum
    m.top.streamUrl = "http://127.0.0.1:" + portNum.ToStr() + "/live.m3u8"
    conns = {}
    while true
        ev = wait(500, m.port)
        checkPlaylist()
        if ev = invalid then
            tick()
        else if type(ev) = "roSGNodeEvent" and ev.getField() = "quit" then
            exit while
        else if type(ev) = "roSGNodeEvent" and ev.getField() = "result" then
            onMinted(ev.getData())
        else if type(ev) = "roUrlEvent" then
            if m.plFetch <> invalid and ev.GetSourceIdentity().ToStr() = m.plFetch.id then onPlaylistEvent(ev) else onDownload(ev)
        else if type(ev) = "roSocketEvent" then
            id = ev.getSocketID()
            if id = srv.GetID() then
                if srv.IsReadable() then
                    c = srv.Accept()
                    if c <> invalid then
                        c.SetMessagePort(m.port)
                        c.NotifyReadable(true)
                        conns[c.GetID().ToStr()] = {sock: c, buf: ""}
                    end if
                end if
            else
                k = id.ToStr()
                cn = conns[k]
                if cn <> invalid and cn.sock.IsReadable() then
                    s = cn.sock.ReceiveStr(8192)
                    if s = "" then
                        cn.sock.Close()
                        conns.Delete(k)
                    else
                        cn.buf = cn.buf + s
                        if Instr(1, cn.buf, Chr(13) + Chr(10) + Chr(13) + Chr(10)) > 0 then
                            ' A segment that's still downloading is answered later
                            ' (onDownload), which also closes the connection.
                            cn.sock.NotifyReadable(false)
                            if handle(cn.sock, cn.buf) then cn.sock.Close()
                            conns.Delete(k)
                        end if
                    end if
                end if
            end if
        end if
    end while
    for each k in conns
        conns[k].sock.Close()
    end for
    if m.plFetch <> invalid then m.plFetch.x.AsyncCancel()
    for each w in m.plWaiters
        w.sock.Close()
    end for
    cancelDownloads()
    srv.Close()
    ' A new link still being found: stop it, or close its session if it's done.
    if m.minter <> invalid then
        m.minter.quit = true
        r = m.minter.result
        if r <> invalid and r.sid <> invalid then closeSession(m.driver, r.sid)
    end if
end sub

' True if the request was answered; a segment still downloading is answered
' when it arrives.
function handle(sock as Object, req as String) as Boolean
    path = req.Split(" ")[1]
    esc = CreateObject("roUrlTransfer")
    t = CreateObject("roTimespan")
    if path = "/live.m3u8" then
        return askPlaylist(sock)
    else if Left(path, 6) = "/pl?u=" then
        text = playlist(esc.Unescape(Mid(path, 7)))
        if text = invalid then
            respond(sock, "502 Bad Gateway", "text/plain", invalid)
        else
            ba = CreateObject("roByteArray")
            ba.FromAsciiString(text)
            respond(sock, "200 OK", "application/vnd.apple.mpegurl", ba)
        end if
        print "[stream] playlist "; t.TotalMilliseconds(); " ms"
    else if Left(path, 7) = "/seg?u=" then
        return askSegment(sock, esc.Unescape(Mid(path, 8)))
    else
        respond(sock, "404 Not Found", "text/plain", invalid)
    end if
    return true
end function

' What's playing, for the player to show and remember. Bitrate from the last
' few segments' sizes over their lengths; resolution and frame rate read from
' the first few segments' video (tsinfo.brs), keeping the highest frame rate
' seen. Nothing extra is downloaded.
sub measure(u as String, ba as Object)
    d = m.segDur[u]
    if d = invalid or d <= 0 then return
    m.bitrates.Push(ba.Count() * 8 / d)
    if m.bitrates.Count() > 5 then m.bitrates.Shift()
    total = 0
    for each b in m.bitrates
        total = total + b
    end for
    if m.measured < 3 then
        m.measured = m.measured + 1
        took = CreateObject("roTimespan")
        info = tsVideoInfo(ba)
        if info.height > 0 then m.height = info.height
        if info.fps > m.fps then m.fps = info.fps
        print "[stream] video "; info.width; "x"; info.height; " @ "; info.fps; " fps (read in "; took.TotalMilliseconds(); " ms)"
    end if
    m.top.quality = {height: m.height, fps: m.fps, mbps: total / m.bitrates.Count() / 1000000}
end sub

sub respond(sock as Object, status as String, ctype as String, payload as Dynamic)
    n = 0
    if payload <> invalid then n = payload.Count()
    crlf = Chr(13) + Chr(10)
    head = CreateObject("roByteArray")
    head.FromAsciiString("HTTP/1.1 " + status + crlf + "Content-Type: " + ctype + crlf + "Content-Length: " + n.ToStr() + crlf + "Connection: close" + crlf + crlf)
    sendAll(sock, head)
    if payload <> invalid then sendAll(sock, payload)
end sub

sub sendAll(sock as Object, ba as Object)
    total = ba.Count()
    sent = 0
    idle = 0
    while sent < total
        chunk = total - sent
        if chunk > 65536 then chunk = 65536
        n = sock.Send(ba, sent, chunk)
        if n > 0 then
            sent = sent + n
            idle = 0
        else
            if not sock.IsConnected() then return
            idle = idle + 1
            if idle > 5000 then return
            sleep(2)
        end if
    end while
end sub
