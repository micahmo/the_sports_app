sub init()
    m.top.functionName = "work"
end sub

sub work()
    port = CreateObject("roMessagePort")
    pending = {}
    results = {}
    for each name in m.top.requests
        x = CreateObject("roUrlTransfer")
        x.SetUrl(m.top.requests[name])
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
    m.top.results = results
end sub
