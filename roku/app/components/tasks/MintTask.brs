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
        ' A link on the server being left (StreamTask's `avoid`) is passed
        ' over for another session, unchecked (pickMedia): checking one on a
        ' dead server waits out two 8 s fetches. On 2026-11-07 the first new
        ' link landed on the server that had just died four times in five
        ' hours, and three times that check was most of a 15-23 s spinner.
        ' The last try takes any server.
        m.avoidHost = ""
        if try < 3 then m.avoidHost = m.top.avoid
        m.passedOver = false
        if not openSession() then exit for
        if findPlaylist() then
            if pickMedia() and not quitRequested() then
                if m.top.probe then
                    closeSession(m.driver, m.sid)
                    m.top.result = {ok: true}
                else
                    m.top.result = {sid: m.sid, url: m.playlistUrl}
                end if
                return
            end if
            if m.passedOver then
                print logTime(); "[stream] new link is on "; m.avoidHost; " again: trying another"
            else
                print logTime(); "[stream] new link didn't answer: "; Left(m.playlistUrl, 30)
            end if
        end if
        closeSession(m.driver, m.sid)
        if quitRequested() then exit for
    end for
    m.top.result = {}
end sub
