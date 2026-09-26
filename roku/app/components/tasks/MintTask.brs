sub init()
    m.top.functionName = "work"
end sub

' Some of a source's servers can be dead while others are fine, and each fresh
' session is handed one of them, so up to three sessions.
sub work()
    m.driver = m.top.driver
    m.quitting = false
    for try = 1 to 3
        m.sid = ""
        if not openSession() then exit for
        if findPlaylist() then
            if pickMedia() and not quitRequested() then
                m.top.result = {sid: m.sid, url: m.playlistUrl}
                return
            end if
            print "[stream] new link didn't answer: "; Left(m.playlistUrl, 30)
        end if
        wd(m.driver, "DELETE", "/session/" + m.sid, invalid, 5000)
        if quitRequested() then exit for
    end for
    m.top.result = {}
end sub
