' Minimal WebDriver client. The server is a Selenium standalone Chrome (see
' DESIGN_NOTES.md, "Roku"); its address lives in the registry (getDriver()).

' method: "GET" | "POST" | "DELETE". Returns the parsed "value", or invalid.
' body may be an object (sent as JSON) or a ready-made JSON string, for when key
' case matters ("alwaysMatch", "goog:chromeOptions").
function wd(driver as String, method as String, path as String, body = invalid as Dynamic, timeoutMs = 60000 as Integer) as Dynamic
    x = CreateObject("roUrlTransfer")
    p = CreateObject("roMessagePort")
    x.SetMessagePort(p)
    x.SetUrl(driver + path)
    x.AddHeader("Content-Type", "application/json")
    x.RetainBodyOnError(true)
    if method = "GET" then
        x.AsyncGetToString()
    else
        x.SetRequest(method)
        payload = "{}"
        if body <> invalid then
            if type(body) = "String" or type(body) = "roString" then payload = body else payload = FormatJson(body)
        end if
        x.AsyncPostFromString(payload)
    end if
    ev = wait(timeoutMs, p)
    if ev = invalid then
        x.AsyncCancel()
        return invalid
    end if
    json = ParseJson(ev.GetString())
    if json = invalid then return invalid
    return json.value
end function

' Is there a WebDriver server at this address that will take a session?
function driverReady(driver as String) as Boolean
    v = wd(driver, "GET", "/status", invalid, 3000)
    return v <> invalid and v.ready = true
end function

' Session ids are remembered so one left behind by a crash or the Home button
' can be closed on the next launch.
sub rememberSession(driver as String, sid as String)
    s = CreateObject("roRegistrySection", "session")
    s.Write("driver", driver)
    s.Write("sid", sid)
    s.Flush()
end sub

' A stream closing its own session. Forget it only if it's still the one
' remembered: a stream that takes a while to wind down finishes after the next
' has started, and must not close that one (it did: "invalid session id", then
' "no valid bitrates" a few seconds into the new stream).
sub closeSession(driver as String, sid as String)
    if sid = "" then return
    if not endSession(driver, sid, 5000) then closeLater(driver, sid)
    s = CreateObject("roRegistrySection", "session")
    if s.Exists("sid") and s.Read("sid") = sid then
        s.Delete("sid")
        s.Delete("driver")
        s.Flush()
    end if
end sub

' Whether the server closed it (or had no such session). The server runs one
' command at a time per session, so a close waits behind whatever the session
' is still doing.
function endSession(driver as String, sid as String, timeoutMs as Integer) as Boolean
    x = CreateObject("roUrlTransfer")
    p = CreateObject("roMessagePort")
    x.SetMessagePort(p)
    x.SetUrl(driver + "/session/" + sid)
    x.RetainBodyOnError(true)
    x.SetRequest("DELETE")
    if not x.AsyncPostFromString("{}") then return false
    ev = wait(timeoutMs, p)
    if ev = invalid then
        x.AsyncCancel()
        return false
    end if
    c = ev.GetResponseCode()
    return c = 200 or c = 404
end function

' A session that didn't close, closed again before the next one opens
' (closeLeftOpen). Its close had queued behind page fetches from a source
' server that had stopped answering, and the TV gave up on it: four left open
' filled the server's four slots, and the reconnect waited two minutes for a
' browser (2026-11-01, SNF).
sub closeLater(driver as String, sid as String)
    s = CreateObject("roRegistrySection", "session")
    l = invalid
    if s.Exists("toClose") then l = ParseJson(s.Read("toClose"))
    if type(l) <> "roArray" then l = []
    l.Push({d: driver, s: sid})
    while l.Count() > 8
        l.Shift()
    end while
    s.Write("toClose", FormatJson(l))
    s.Flush()
    print logTime(); "[stream] a browser session didn't close: closing it again before the next"
end sub

sub closeLeftOpen()
    s = CreateObject("roRegistrySection", "session")
    if not s.Exists("toClose") then return
    l = ParseJson(s.Read("toClose"))
    s.Delete("toClose")
    s.Flush()
    if type(l) <> "roArray" then return
    for each e in l
        ' By now whatever held it up has timed out (see openSession).
        if endSession(e.d, e.s, 12000) then print logTime(); "[stream] closed a browser session left open" else closeLater(e.d, e.s)
    end for
end sub

sub closeRememberedSession()
    closeLeftOpen()
    s = CreateObject("roRegistrySection", "session")
    if s.Exists("sid") and s.Exists("driver") then wd(s.Read("driver"), "DELETE", "/session/" + s.Read("sid"), invalid, 5000)
    s.Delete("sid")
    s.Delete("driver")
    s.Flush()
end sub
