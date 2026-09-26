' Shared by StreamTask and MintTask: a browser session on the WebDriver server
' that loads a stream's embed page and hands over its playlist link, and
' playlist fetches made by that page (only a Chrome handshake gets them). Both
' tasks have the fields these use: driver, embedUrl, quit.

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

function fetchInPageOnce(url as String) as Dynamic
    js = "var done=arguments[arguments.length-1];fetch(arguments[0]).then(function(r){return r.text().then(function(t){done(r.status+'\n'+t)})}).catch(function(e){done('0\n'+e)});"
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
