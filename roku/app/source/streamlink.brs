' Shared by StreamTask and MintTask: a browser session on the WebDriver server
' that loads a stream's embed page and hands over its playlist link, and
' playlist fetches made by that page (only a Chrome handshake gets them). Both
' tasks have the fields these use: driver, embedUrl, quit.

' The page to load: the embed page, or for a nested source (golf) the real
' player page inside it (playerPageUrl). Worked out once per task.
function pageUrl() as String
    if m.pageUrl = invalid then m.pageUrl = playerPageUrl(m.top.embedUrl)
    return m.pageUrl
end function

' A nested source's real player page (the same steps as the phone app's
' StreamedApi.innerPlayerUrl): its embed page frames another site's page,
' which frames an ordinary embed.st player page, its address in base64
' (atob("...")). Opened directly, that page plays like any other source's. The
' embed URL itself for other sources, or if anything along the way doesn't
' match.
function playerPageUrl(embedUrl as String) as String
    at = Instr(1, embedUrl, "/embed/")
    if at = 0 then return embedUrl
    rest = Mid(embedUrl, at + 7)
    slash = Instr(1, rest, "/")
    source = rest
    if slash > 0 then source = Left(rest, slash - 1)
    if not appNestedSources().DoesExist(LCase(source)) then return embedUrl
    host = hostOf(embedUrl)
    middle = foreignFrame(pageText(embedUrl, ""), host)
    if middle = "" then return embedUrl
    html = pageText(middle, embedUrl)
    k = Instr(1, html, "atob(")
    if k = 0 then return embedUrl
    quote = Mid(html, k + 5, 1)
    e = Instr(k + 6, html, quote)
    if e = 0 then return embedUrl
    ba = CreateObject("roByteArray")
    ba.FromBase64String(Mid(html, k + 6, e - k - 6))
    inner = ba.ToAsciiString()
    prefix = "https://" + host + "/embed/"
    if Left(inner, Len(prefix)) <> prefix then return embedUrl
    print "[stream] nested source: playing "; inner
    return inner
end function

' "embed.st" from "https://embed.st/embed/...".
function hostOf(url as String) as String
    at = Instr(1, url, "://")
    if at = 0 then return ""
    rest = Mid(url, at + 3)
    slash = Instr(1, rest, "/")
    if slash > 0 then return Left(rest, slash - 1)
    return rest
end function

' The first frame on a page that comes from another site (the page's own
' /ad.html and the like don't count).
function foreignFrame(html as String, host as String) as String
    q = Chr(34)
    k = 1
    while true
        k = Instr(k, html, "<iframe")
        if k = 0 then return ""
        s = Instr(k, html, "src=" + q)
        if s = 0 then return ""
        e = Instr(s + 5, html, q)
        if e = 0 then return ""
        url = Mid(html, s + 5, e - s - 5)
        if Left(url, 4) = "http" and hostOf(url) <> host then return url
        k = e
    end while
    return ""
end function

' A page as a browser would ask for it (the sites answer a browser), or "".
function pageText(url as String, referer as String) as String
    x = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    x.SetMessagePort(port)
    x.SetUrl(url)
    x.SetCertificatesFile("common:/certs/ca-bundle.crt")
    x.InitClientCertificates()
    x.AddHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36")
    if referer <> "" then x.AddHeader("Referer", referer)
    if not x.AsyncGetToString() then return ""
    msg = wait(8000, port)
    if type(msg) = "roUrlEvent" and msg.GetResponseCode() = 200 then return msg.GetString()
    x.AsyncCancel()
    return ""
end function

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

' Loads the embed page and waits for it to request its playlist. The FIRST one
' it requests: the page's own player goes on to fetch the quality it picked,
' and taking the last pinned us to that pick instead of the master (which
' pickMedia reads for the best). The phone app had the same drift.
function findPlaylist() as Boolean
    wd(m.driver, "POST", "/session/" + m.sid + "/url", {url: pageUrl()})
    js = "var e=performance.getEntriesByType('resource');for(var i=0;i<e.length;i++)if(e[i].name.indexOf('.m3u8')!==-1)return e[i].name;return null;"
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

' The page fetches a URL (only its Chrome handshake gets the playlists) and
' hands back the status, a newline, and the text.
function fetchScript() as String
    return "var done=arguments[arguments.length-1];fetch(arguments[0]).then(function(r){return r.text().then(function(t){done(r.status+'\n'+t)})}).catch(function(e){done('0\n'+e)});"
end function

function fetchInPageOnce(url as String) as Dynamic
    js = fetchScript()
    ' They take ~130 ms; waiting longer holds up everything the proxy serves.
    v = wd(m.driver, "POST", "/session/" + m.sid + "/execute/async", {script: js, args: [url]}, 8000)
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
