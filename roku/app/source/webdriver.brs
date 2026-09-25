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
    wd(driver, "DELETE", "/session/" + sid, invalid, 5000)
    s = CreateObject("roRegistrySection", "session")
    if s.Exists("sid") and s.Read("sid") = sid then
        s.Delete("sid")
        s.Delete("driver")
        s.Flush()
    end if
end sub

sub closeRememberedSession()
    s = CreateObject("roRegistrySection", "session")
    if s.Exists("sid") and s.Exists("driver") then wd(s.Read("driver"), "DELETE", "/session/" + s.Read("sid"), invalid, 5000)
    s.Delete("sid")
    s.Delete("driver")
    s.Flush()
end sub
