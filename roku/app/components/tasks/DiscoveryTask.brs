sub init()
    m.top.functionName = "work"
end sub

sub work()
    prefixes = []
    addrs = CreateObject("roDeviceInfo").GetIPAddrs()
    for each iface in addrs
        parts = addrs[iface].Split(".")
        if parts.Count() = 4 then prefixes.Push(parts[0] + "." + parts[1] + "." + parts[2] + ".")
    end for
    candidates = []
    for each prefix in prefixes
        for i = 1 to 254
            candidates.Push(prefix + i.ToStr())
        end for
    end for

    ' Selenium first: it is what the app is set up for.
    for each portNum in [4444, 9515]
        found = scan(candidates, portNum)
        if found <> "" then
            m.top.found = found
            return
        end if
    end for
    m.top.found = ""
end sub

' Probes /status on every candidate, a batch at a time, and returns the first
' server that says it is ready.
function scan(hosts as Object, portNum as Integer) as String
    batch = 48
    i = 0
    while i < hosts.Count()
        m.top.progress = "Checking port " + portNum.ToStr() + ": " + i.ToStr() + " of " + hosts.Count().ToStr()
        port = CreateObject("roMessagePort")
        live = {}
        last = i + batch - 1
        if last > hosts.Count() - 1 then last = hosts.Count() - 1
        for j = i to last
            x = CreateObject("roUrlTransfer")
            x.SetUrl("http://" + hosts[j] + ":" + portNum.ToStr() + "/status")
            x.SetMessagePort(port)
            x.AsyncGetToString()
            live[x.GetIdentity().ToStr()] = {xfer: x, base: "http://" + hosts[j] + ":" + portNum.ToStr()}
        end for
        t = CreateObject("roTimespan")
        hit = ""
        while live.Count() > 0 and t.TotalMilliseconds() < 1500 and hit = ""
            ev = wait(250, port)
            if type(ev) = "roUrlEvent" and ev.GetInt() = 1 then
                key = ev.GetSourceIdentity().ToStr()
                if live.DoesExist(key) then
                    if ev.GetResponseCode() = 200 then
                        json = ParseJson(ev.GetString())
                        if json <> invalid and json.value <> invalid and json.value.ready = true then hit = live[key].base
                    end if
                    live.Delete(key)
                end if
            end if
        end while
        for each key in live
            live[key].xfer.AsyncCancel()
        end for
        if hit <> "" then return hit
        i = last + 1
    end while
    return ""
end function
