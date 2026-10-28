sub init()
    m.top.functionName = "work"
end sub

' Requests are site addresses, or "backend:<kind>/<a>/<b>" (backendUrl in
' common.brs): one of the app's lists from the backend in use (see DESIGN_NOTES,
' Backends), fetched once however many lists ask for it and converted here, off
' the render thread, into the shapes the screens read.
sub work()
    port = CreateObject("roMessagePort")
    pending = {}
    results = {}
    wanted = {}
    urls = {}
    for each name in m.top.requests
        url = m.top.requests[name]
        if Left(url, 8) = "backend:" then
            parts = Mid(url, 9).Split("/")
            while parts.Count() < 3
                parts.Push("")
            end while
            wanted[name] = {kind: parts[0], a: parts[1], b: parts[2]}
            urls["backend:" + backendRealUrl()] = backendRealUrl()
        else
            urls[name] = url
        end if
    end for
    for each name in urls
        x = CreateObject("roUrlTransfer")
        x.SetUrl(urls[name])
        x.SetCertificatesFile("common:/certs/ca-bundle.crt")
        x.InitClientCertificates()
        x.EnableEncodings(true)
        x.SetMessagePort(port)
        if x.AsyncGetToString() then
            pending[x.GetIdentity().ToStr()] = {name: name, xfer: x}
        else
            results[name] = ""
        end if
    end for
    deadline = CreateObject("roTimespan")
    while pending.Count() > 0 and deadline.TotalMilliseconds() < 20000
        ev = wait(1000, port)
        if type(ev) = "roUrlEvent" and ev.GetInt() = 1 then
            key = ev.GetSourceIdentity().ToStr()
            if pending.DoesExist(key) then
                text = ""
                if ev.GetResponseCode() = 200 then text = ev.GetString()
                results[pending[key].name] = text
                pending.Delete(key)
            end if
        end if
    end while
    for each key in pending
        pending[key].xfer.AsyncCancel()
        results[pending[key].name] = ""
    end for
    for each name in wanted
        w = wanted[name]
        text = results["backend:" + backendRealUrl()]
        if text = invalid or text = "" then
            results[name] = ""
        else
            results[name] = backendConvert(w.kind, w.a, w.b, text)
        end if
    end for
    m.top.results = results
end sub
