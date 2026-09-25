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
    m.bitrates = []
    m.measured = 0
    m.height = 0
    m.fps = 0
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
    ' A stream that isn't broadcasting still hands over a playlist URL, which
    ' then answers "Not found" (with a 200). Say so, as the phone app does,
    ' rather than let the player fail with "an unexpected problem".
    if not pickMedia() then
        if not m.quitting then fail("This stream is unavailable. Try another stream or source.")
        cleanup()
        return
    end if
    serve()
    cleanup()
end sub

function openSession() as Boolean
    q = Chr(34)
    args = ["--headless=new", "--no-sandbox", "--disable-dev-shm-usage", "--mute-audio", "--window-size=1280,720"]
    ' Built by hand: WebDriver needs "alwaysMatch" and "goog:chromeOptions" exactly.
    caps = "{" + q + "capabilities" + q + ":{" + q + "alwaysMatch" + q + ":{" + q + "browserName" + q + ":" + q + "chrome" + q + "," + q + "goog:chromeOptions" + q + ":{" + q + "args" + q + ":" + FormatJson(args) + "}}}}"
    session = wd(m.driver, "POST", "/session", caps)
    if session = invalid or session.sessionId = invalid then return false
    m.sid = session.sessionId
    rememberSession(m.driver, m.sid)

    ' Headless Chrome announces itself in its user agent; present as the same
    ' Chrome version without the "Headless", whatever version the server runs.
    ua = exec("return navigator.userAgent")
    if isString(ua) and Instr(1, ua, "HeadlessChrome") > 0 then
        ua = ua.Replace("HeadlessChrome", "Chrome")
        cdp = "{" + q + "cmd" + q + ":" + q + "Network.setUserAgentOverride" + q + "," + q + "params" + q + ":{" + q + "userAgent" + q + ":" + FormatJson(ua) + "}}"
        wd(m.driver, "POST", "/session/" + m.sid + "/goog/cdp/execute", cdp)
    end if
    return true
end function

' Loads the embed page and waits for it to request its playlist.
function findPlaylist() as Boolean
    wd(m.driver, "POST", "/session/" + m.sid + "/url", {url: m.top.embedUrl})
    js = "var e=performance.getEntriesByType('resource');for(var i=e.length-1;i>=0;i--)if(e[i].name.indexOf('.m3u8')!==-1)return e[i].name;return null;"
    ' The current link stays until there's a new one: a failed refresh must
    ' not leave the proxy without one.
    found = invalid
    for i = 1 to 40
        v = exec(js)
        if isString(v) and v <> "" then
            found = v
            exit for
        end if
        ' Leaving the player while it loads: stop now rather than wait it out.
        if quitRequested() then return false
        sleep(500)
    end for
    if found = invalid then return false
    m.playlistUrl = found
    ' Only the page is needed now; its own player would keep decoding and
    ' downloading the stream on the server for nothing.
    exec("try{jwplayer().remove()}catch(e){}")
    m.lastMint = CreateObject("roTimespan")
    return true
end function

' If the page handed over a master playlist, serve its best rendition alone.
' Given the choice (1080p at 8 Mbps and 540p), the Roku starts low and stalls
' switching up through this proxy; one media playlist plays smoothly. False
' when the stream isn't actually there.
function pickMedia() as Boolean
    text = fetchInPage(m.playlistUrl)
    if text = invalid then return false
    if Instr(1, text, "#EXT-X-STREAM-INF") = 0 then return true
    best = ""
    bestBw = -1
    lines = text.Split(Chr(10))
    for i = 0 to lines.Count() - 2
        line = lines[i].Trim()
        if Left(line, 18) = "#EXT-X-STREAM-INF:" then
            bw = 0
            at = Instr(1, line, "BANDWIDTH=")
            if at > 0 then bw = Val(Mid(line, at + 10))
            uri = lines[i + 1].Trim()
            if uri <> "" and Left(uri, 1) <> "#" and bw > bestBw then
                best = uri
                bestBw = bw
            end if
        end if
    end for
    if best = "" then return false
    m.playlistUrl = resolve(m.playlistUrl, best)
    print "[stream] master playlist: using "; bestBw; " bps rendition"
    return fetchInPage(m.playlistUrl) <> invalid
end function

' Reads the field rather than the message port: the port also carries the
' stream server's socket events, and draining it mid-stream (a link refresh)
' threw those away.
function quitRequested() as Boolean
    if m.top.quit = true then m.quitting = true
    return m.quitting = true
end function

function exec(js as String) as Dynamic
    return wd(m.driver, "POST", "/session/" + m.sid + "/execute/sync", {script: js, args: []})
end function

function isString(v as Dynamic) as Boolean
    return type(v) = "String" or type(v) = "roString"
end function

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
' If the signed URL has stopped working (token expired), load the page again
' for a fresh one, at most every 30 seconds.
function playlist(url as String) as Dynamic
    text = fetchInPage(url)
    if text = invalid and url = m.playlistUrl and m.lastMint.TotalMilliseconds() > 30000 and not quitRequested() then
        say("Refreshing the stream link...")
        if findPlaylist() and pickMedia() then
            url = m.playlistUrl
            text = fetchInPage(url)
        end if
    end if
    if text = invalid then return invalid
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
    return out.Join(Chr(10)) + Chr(10)
end function

' One retry straight away: a single slow or failed round trip (seen once after
' a 12s segment download) shouldn't cost the player its playlist.
function fetchInPage(url as String) as Dynamic
    text = fetchInPageOnce(url)
    if text = invalid and not m.quitting then
        print "[stream] retrying playlist fetch"
        text = fetchInPageOnce(url)
    end if
    return text
end function

function fetchInPageOnce(url as String) as Dynamic
    js = "var done=arguments[arguments.length-1];fetch(arguments[0]).then(function(r){return r.text().then(function(t){done(r.status+'\n'+t)})}).catch(function(e){done('0\n'+e)});"
    v = wd(m.driver, "POST", "/session/" + m.sid + "/execute/async", {script: js, args: [url]}, 20000)
    if not isString(v) then
        ' Log what the server said (e.g. the page navigated away, session gone).
        if v = invalid then print "[stream] playlist fetch: no reply from the server" else print "[stream] playlist fetch: "; Left(FormatJson(v), 200)
        return invalid
    end if
    nl = Instr(1, v, Chr(10))
    body = Mid(v, nl + 1)
    if nl = 0 or Left(v, nl - 1) <> "200" or Left(body, 7) <> "#EXTM3U" then
        print "[stream] playlist fetch: "; Left(v, 60)
        return invalid
    end if
    return body
end function

function resolve(base as String, ref as String) as String
    if Left(ref, 4) = "http" then return ref
    schemeEnd = Instr(1, base, "://")
    if Left(ref, 1) = "/" then
        hostEnd = Instr(schemeEnd + 3, base, "/")
        return Left(base, hostEnd - 1) + ref
    end if
    q = Instr(1, base, "?")
    if q > 0 then base = Left(base, q - 1)
    slash = 0
    i = Instr(1, base, "/")
    while i > 0
        slash = i
        i = Instr(i + 1, base, "/")
    end while
    return Left(base, slash) + ref
end function

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
        if not d.done and not d.hedged and d.started.TotalMilliseconds() > 4000 then
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
        if ev = invalid then
            tick()
        else if type(ev) = "roSGNodeEvent" and ev.getField() = "quit" then
            exit while
        else if type(ev) = "roUrlEvent" then
            onDownload(ev)
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
    cancelDownloads()
    srv.Close()
end sub

' True if the request was answered; a segment still downloading is answered
' when it arrives.
function handle(sock as Object, req as String) as Boolean
    path = req.Split(" ")[1]
    esc = CreateObject("roUrlTransfer")
    t = CreateObject("roTimespan")
    if path = "/live.m3u8" or Left(path, 6) = "/pl?u=" then
        url = m.playlistUrl
        if Left(path, 6) = "/pl?u=" then url = esc.Unescape(Mid(path, 7))
        text = playlist(url)
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
