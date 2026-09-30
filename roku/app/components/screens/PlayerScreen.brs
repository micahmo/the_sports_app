sub init()
    t = theme()
    m.video = m.top.findNode("video")
    m.status = m.top.findNode("status")
    m.status.font = bodyFont(32)
    m.status.color = t.textDim
    m.video.observeField("state", "onVideoState")
    ' Our spinner stands in for the player's own buffering indicators.
    m.video.bufferingBarVisibilityAuto = false
    m.video.retrievingBarVisibilityAuto = false
    m.stall = m.top.findNode("stall")
    m.stall.observeField("fire", "onStall")
    m.retry = m.top.findNode("retry")
    m.retry.observeField("fire", "onRetry")

    m.bar = m.top.findNode("bar")
    m.barTitle = mkLabel(m.bar, "", condensed("SemiBold", 48), t.text, 96, 26, 1728, 60)
    m.barQuality = mkLabel(m.bar, "", bodyFont(28), t.textDim, 96, 88, 1728, 40)
    m.barTimer = m.top.findNode("barTimer")
    m.barTimer.observeField("fire", "onBarTimer")
    ' The bar is up from the start until the first quality reading, so what's
    ' playing gets seen; then it goes after the usual few seconds.
    m.holdBar = true

    ' Ours whenever there's something to wait for: starting, reconnecting (with
    ' the status under it) and buffering.
    ' In the true centre whether or not there's text; the text goes under it.
    m.spinner = mkSpinner(m.top, 960, 540)
    hideStatus()

    m.restarts = 0

    ' The streams row (this game's other streams, recent games), its pill, and
    ' the note after falling back. See the phone app's streams_row.dart.
    m.row = m.top.createChild("Group")
    m.row.visible = false
    m.pill = m.top.createChild("Group")
    m.pill.visible = false
    m.note = m.top.createChild("Group")
    m.note.visible = false
    m.noteTimer = m.top.createChild("Timer")
    m.noteTimer.duration = appPlayer().switchedNoteMs / 1000
    m.noteTimer.observeField("fire", "onNoteTimer")
    m.rowOpen = false
    m.rowCards = []
    m.rowSplit = 0
    m.rowFocus = -1
    renderPill()
    m.tried = {}
    m.failed = {}
    m.trying = ""
    m.fallbackFrom = ""
end sub

' First open: what to play and what else this game has.
sub onParams()
    p = m.top.params
    m.stream = p.stream
    if m.stream = invalid then m.stream = {embedUrl: p.embedUrl, source: "", streamNo: 0, hd: true, language: ""}
    m.match = p.match
    if m.match = invalid then m.match = {id: "", title: p.title, category: "", date: 0}
    m.streams = p.streams
    if m.streams = invalid then m.streams = [m.stream]
    m.tried[m.stream.embedUrl] = true
    start()
end sub

sub start()
    driver = getDriver()
    if driver = "" then
        showFinal("No stream server is set up yet." + Chr(10) + "Open Settings on the home screen to find one.")
        return
    end if
    if m.trying <> "" then
        showWorking(m.fallbackFrom + Chr(10) + m.trying)
    else
        showWorking("Starting...")
    end if
    m.barTitle.text = m.match.title
    m.barQuality.text = barLine("")
    m.recorded = false
    if m.holdBar then
        m.bar.visible = true
        m.pill.visible = hasRow()
    end if
    m.task = CreateObject("roSGNode", "StreamTask")
    m.task.embedUrl = m.stream.embedUrl
    m.task.driver = driver
    m.task.observeField("status", "onStatus")
    m.task.observeField("error", "onError")
    m.task.observeField("streamUrl", "onStreamUrl")
    m.task.observeField("quality", "onQuality")
    m.task.control = "run"
end sub

sub onStatus()
    ' While falling back, the spinner says what stopped and what's next.
    if m.spinner.visible and m.trying = "" then m.status.text = m.task.status
end sub

' The title bar's second line, what you glance for first: quality, then which
' stream ("1080p30 · 6.2 Mbps · Admin · Stream 1").
function barLine(quality as String) as String
    parts = []
    if quality <> "" then parts.Push(quality)
    src = m.stream.source
    if src <> invalid and src <> "" then parts.Push(UCase(Left(src, 1)) + Mid(src, 2))
    if m.stream.streamNo <> invalid and m.stream.streamNo > 0 then parts.Push("Stream " + Int(m.stream.streamNo).ToStr())
    return parts.Join(" · ")
end function

' Working on it: our spinner in the middle, what's happening just under it.
' (The label centres its text in its 200px height: one line lands ~25px below
' the spinner's bottom edge.)
sub showWorking(text as String)
    m.status.text = text
    m.status.translation = [160, 520]
    m.status.visible = true
    m.spinner.visible = true
    m.spinner.control = "start"
end sub

' Nothing more to wait for: the message alone, centred.
sub showFinal(text as String)
    m.spinner.visible = false
    m.spinner.control = "stop"
    m.status.text = text
    m.status.translation = [160, 440]
    m.status.visible = true
end sub

sub hideStatus()
    m.spinner.visible = false
    m.spinner.control = "stop"
    m.status.visible = false
end sub

sub onError()
    if m.task.error = "offline" then
        ' No internet: wait, and look again in 10 seconds. Never counts as a try.
        m.task = invalid
        showWorking("Waiting for connection...")
        m.retry.duration = 10
        m.retry.control = "start"
        return
    end if
    if m.restarts > 0 then
        ' A reconnect that didn't work: try again after a longer gap.
        reconnect(m.task.error)
        return
    end if
    failedForGood(m.task.error)
end sub

' The stream has failed for good (never started, or the reconnects gave up):
' move on to the next one like it, or say it's unavailable. HD for HD and SD for
' SD, best sources first, the same language if there is one, never one already
' tried. No limit: Back leaves any time. (As the phone app.)
sub failedForGood(reason as String)
    m.failed[m.stream.embedUrl] = true
    left = []
    for each s in m.streams
        if s.hd = m.stream.hd and not m.tried.DoesExist(s.embedUrl) then left.Push(s)
    end for
    if left.Count() = 0 then
        m.trying = ""
        m.fallbackFrom = ""
        showFinal(reason + Chr(10) + "Press Back to pick another stream.")
        return
    end if
    nxt = left[0]
    for each s in left
        if languageOf(s) = languageOf(m.stream) then
            nxt = s
            exit for
        end if
    end for
    from = playerText("stoppedWorking", streamLabel(m.stream))
    m.fallbackFrom = from
    m.trying = playerText("trying", streamLabel(nxt))
    switchTo(nxt, true)
end sub

' The language itself, not the label around it: "English" and "English - NBC"
' are the same language.
function languageOf(s as Object) as String
    l = s.language
    if l = invalid then return ""
    l = LCase(l.Trim())
    for each sep in [" ", "-", "(", ",", "/"]
        at = Instr(1, l, sep)
        if at > 0 then l = Left(l, at - 1)
    end for
    return l
end function

' Play s in place of what's playing: the same screen, a fresh start. A pick from
' the streams row starts a new round of falling back; a fallback carries on.
sub switchTo(s as Object, fallback as Boolean)
    saveBest()
    m.best = invalid
    m.savedAt = invalid
    m.stall.control = "stop"
    m.retry.control = "stop"
    m.video.control = "stop"
    m.video.content = invalid
    if m.task <> invalid then
        m.task.unobserveField("status")
        m.task.unobserveField("error")
        m.task.unobserveField("streamUrl")
        m.task.unobserveField("quality")
        m.task.quit = true
        m.task = invalid
    end if
    if not fallback then
        m.tried = {}
        m.trying = ""
        m.fallbackFrom = ""
    end if
    m.tried[s.embedUrl] = true
    m.stream = s
    m.restarts = 0
    closeRow()
    m.note.visible = false
    start()
end sub

sub onRetry()
    start()
    showWorking("Reconnecting...")
end sub

sub onStreamUrl()
    content = CreateObject("roSGNode", "ContentNode")
    content.url = m.task.streamUrl
    content.streamFormat = "hls"
    content.live = true
    ' Our bar shows the title (full width, and with the quality), so the
    ' player's own bar doesn't. Set here, before playback: changing the content
    ' once it's playing stalls the stream (see onQuality).
    content.title = ""
    m.video.content = content
    ' Our spinner and the last status stay up until it plays (onVideoState).
    m.video.control = "play"
end sub

' What's playing, in our title bar and remembered for the streams list. (Not in
' the player's own title: changing the Video's content, even just its title,
' mid-playback made the next segment take ~11s and the stream stall, every
' time. See DESIGN_NOTES.md.)
sub onQuality()
    q = m.task.quality
    label = qualityText(q)
    if label = "" then return
    m.barQuality.text = barLine(label)
    if m.holdBar then
        m.holdBar = false
        m.barTimer.control = "stop"
        m.barTimer.control = "start"
    end if
    ' The list keeps the best resolution and frame rate this viewing reached (a
    ' dip just before leaving shouldn't stick), with the average bitrate while
    ' at that level: the stream's typical rate. Each viewing starts afresh, in
    ' case the feed behind a stream changes. (Same as the phone app.)
    fps = Int(q.fps + 0.5)
    better = m.best = invalid
    if not better then better = q.height > m.best.height or (q.height = m.best.height and fps > m.best.fps)
    if better then m.best = {height: q.height, fps: q.fps, sum: 0, n: 0}
    if q.height <> m.best.height or fps <> Int(m.best.fps + 0.5) then return
    m.best.sum = m.best.sum + q.mbps
    m.best.n = m.best.n + 1
    ' A reading per segment: save when the level changes, every half minute,
    ' and once more on leaving (onClosing).
    if better or m.savedAt = invalid or m.savedAt.TotalSeconds() > 30 then saveBest()
end sub

sub saveBest()
    if m.best = invalid or m.best.n = 0 then return
    label = qualityText({height: m.best.height, fps: m.best.fps, mbps: m.best.sum / m.best.n})
    if label = "" then return
    saveQuality(m.stream.embedUrl, label)
    m.savedAt = CreateObject("roTimespan")
end sub

sub onVideoState()
    st = m.video.state
    print "[player] "; st; " "; m.video.errorMsg
    if st = "playing" then
        hideStatus()
        m.stall.control = "stop"
        m.restarts = 0
        if not m.recorded then
            m.recorded = true
            if m.match.id <> "" then recordRecent(m.match, m.stream)
        end if
        ' Fell back to this one: say so briefly, then get out of the way.
        if m.trying <> "" then
            showNote(playerText("switchedTo", streamLabel(m.stream)))
            m.trying = ""
            m.fallbackFrom = ""
        end if
    else if st = "buffering" then
        ' Mid-game, our spinner alone; while starting, the status is under it.
        m.spinner.visible = true
        m.spinner.control = "start"
        m.stall.control = "stop"
        m.stall.control = "start"
    else if st = "paused" and not m.status.visible then
        hideStatus()
    else if st = "error" then
        reconnect("Playback failed: " + m.video.errorMsg)
    end if
end sub

' The bar goes after a few seconds, and the pill and row with it.
sub onBarTimer()
    if m.holdBar then return
    m.bar.visible = false
    m.pill.visible = false
    closeRow()
end sub

sub showBar()
    m.bar.visible = true
    m.pill.visible = not m.rowOpen and m.note.visible = false and hasRow()
    m.barTimer.control = "stop"
    ' Longer with the row open, to read the cards.
    if m.rowOpen then m.barTimer.duration = 8 else m.barTimer.duration = 5
    m.barTimer.control = "start"
end sub

' ---- the streams row ----------------------------------------------------------

' This game's other streams: the same HD/SD as what's playing first, then the
' rest, best sources first within each; none that failed.
function rowStreams() as Object
    same = []
    other = []
    for each s in m.streams
        if s.embedUrl <> m.stream.embedUrl and not m.failed.DoesExist(s.embedUrl) then
            if s.hd = m.stream.hd then same.Push(s) else other.Push(s)
        end if
    end for
    same.Append(other)
    out = []
    for each s in same
        if out.Count() >= appPlayer().rowThisGame then exit for
        out.Push(s)
    end for
    return out
end function

' Other games played recently, still on the site's list and started.
function rowRecent() as Object
    out = []
    now = nowSeconds()
    for each r in recentGames()
        if out.Count() >= appPlayer().rowRecent then exit for
        ok = r.match <> invalid and r.match.id <> m.match.id and matchSeconds(r.match) <= now
        if ok and m.currentIds <> invalid then ok = m.currentIds.DoesExist(r.match.id)
        if ok then out.Push(r)
    end for
    return out
end function

function hasRow() as Boolean
    return rowStreams().Count() > 0 or rowRecent().Count() > 0
end function

sub openRow()
    if m.rowOpen or not hasRow() then return
    m.rowOpen = true
    m.rowFocus = -1
    renderRow()
    m.row.visible = true
    m.pill.visible = false
    showBar()
    ' Finished games drop out: check the site's list (which has 24/7 channels,
    ' unlike the live list), at most once a minute.
    if m.currentAt = invalid or m.currentAt.TotalSeconds() > 60 then
        m.currentAt = CreateObject("roTimespan")
        m.allApi = CreateObject("roSGNode", "ApiTask")
        m.allApi.requests = {all: apiBase() + "/api/matches/all"}
        m.allApi.observeField("results", "onAllLoaded")
        m.allApi.control = "run"
    end if
end sub

sub onAllLoaded()
    list = ParseJson(m.allApi.results.all)
    if type(list) <> "roArray" then return
    ids = {}
    for each mt in list
        if mt.id <> invalid then ids[mt.id] = true
    end for
    m.currentIds = ids
    if m.rowOpen then renderRow()
end sub

sub closeRow()
    m.rowOpen = false
    m.row.visible = false
end sub

' Cards along the bottom: THIS GAME, a divider, RECENT. All the same size, the
' same three slots in each (top row, name, details). Focus starts on the divider,
' one step from either side.
sub renderRow()
    t = theme()
    m.row.removeChildrenIndex(m.row.getChildCount(), 0)
    bg = m.row.createChild("Rectangle")
    bg.translation = [0, 770]
    bg.width = 1920
    bg.height = 310
    bg.color = "0x000000C0"
    m.rowCards = []
    cw = 260
    ch = 190
    top = 836
    x = 96
    streams = rowStreams()
    recent = rowRecent()
    m.rowSplit = streams.Count()
    if streams.Count() > 0 then
        mkLabel(m.row, playerText("thisGame"), bodyFont(22), t.textDim, x, 790, 600, 34)
        for each s in streams
            m.rowCards.Push({kind: "stream", stream: s, x: x})
            x = x + cw + 20
        end for
    end if
    m.divider = invalid
    if streams.Count() > 0 and recent.Count() > 0 then
        x = x + 10
        m.divider = m.row.createChild("Rectangle")
        m.divider.translation = [x, top]
        m.divider.width = 3
        m.divider.height = ch
        x = x + 33
    end if
    if recent.Count() > 0 then
        mkLabel(m.row, playerText("recent"), bodyFont(22), t.textDim, x, 790, 600, 34)
        for each r in recent
            m.rowCards.Push({kind: "recent", recent: r, x: x})
            x = x + cw + 20
        end for
    end if
    ' Nothing on one side: start on the other.
    if m.rowFocus = -1 and m.divider = invalid then
        m.rowFocus = 0
    end if
    if m.rowFocus >= m.rowCards.Count() then m.rowFocus = m.rowCards.Count() - 1
    for i = 0 to m.rowCards.Count() - 1
        drawCard(m.rowCards[i], top, cw, ch, i = m.rowFocus)
    end for
    if m.divider <> invalid then
        if m.rowFocus = -1 then m.divider.color = t.primary else m.divider.color = t.divider
    end if
end sub

sub drawCard(c as Object, top as Integer, w as Integer, h as Integer, focused as Boolean)
    t = theme()
    g = m.row.createChild("Group")
    g.translation = [c.x, top]
    if focused then
        mkCard(g, 0, 0, w, h, t.cardHighest)
        mkCard(g, 0, 0, w, h, t.primary, "ring")
    else
        mkCard(g, 0, 0, w, h, t.card)
    end if
    pad = 18
    if c.kind = "stream" then
        s = c.stream
        tagColor = t.sd
        tag = "SD"
        if s.hd = true then
            tagColor = t.hd
            tag = "HD"
        end if
        mkCard(g, pad, pad, 64, 40, tagColor, "chip")
        mkLabel(g, tag, condensed("Bold", 26), t.bg, pad, pad - capsShift("condensed", 26), 64, 40, "center")
        mkLabel(g, streamName(s), condensed("SemiBold", 36), t.text, pad, 70, w - 2 * pad, 46)
        q = qualityLabel(s.embedUrl)
        if q = "" then q = playerText("notPlayed")
        if s.language <> invalid and s.language <> "" then q = q + " · " + s.language
        ' The name is one line here, so the details can have two.
        d = mkLabel(g, q, bodyFont(22), t.textDim, pad, 118, w - 2 * pad, 60)
        d.wrap = true
        d.maxLines = 2
        d.vertAlign = "top"
    else
        r = c.recent
        teams = orderedTeams(r.match)
        icon = sportIcon(r.match.category)
        if teams <> invalid then
            for i = 0 to 1
                b = g.createChild("TeamBadge")
                b.translation = [pad + i * 30, pad - 2]
                b.fallback = icon
                b.uri = badgeUrl(teams[i].badge)
                b.size = 44
            end for
        else
            b = g.createChild("TeamBadge")
            b.translation = [pad, pad - 2]
            b.fallback = icon
            b.uri = ""
            b.cover = posterUrl(r.match)
            b.size = 44
        end if
        title = mkLabel(g, r.match.title, condensed("SemiBold", 32), t.text, pad, 66, w - 2 * pad, 80)
        title.wrap = true
        title.maxLines = 2
        title.vertAlign = "top"
        ' Quality first (what you glance for), then which stream.
        q = qualityLabel(r.stream.embedUrl)
        detail = streamName(r.stream)
        if q <> "" then detail = q.Split(" · ")[0] + " · " + detail
        mkLabel(g, detail, bodyFont(22), t.textDim, pad, h - 48, w - 2 * pad, 34)
    end if
end sub

' A recent game's stream: that game becomes the one playing, and its other
' streams load for the row and for falling back.
sub playRecent(r as Object)
    m.match = r.match
    m.streams = [r.stream]
    switchTo(r.stream, false)
    requests = {}
    for i = 0 to r.match.sources.Count() - 1
        s = r.match.sources[i]
        requests["s" + i.ToStr()] = apiBase() + "/api/stream/" + s.source + "/" + s.id
    end for
    m.streamsFor = r.match
    m.streamsApi = CreateObject("roSGNode", "ApiTask")
    m.streamsApi.requests = requests
    m.streamsApi.observeField("results", "onMatchStreams")
    m.streamsApi.control = "run"
end sub

sub onMatchStreams()
    mt = m.streamsFor
    if mt = invalid or mt.id <> m.match.id then return
    groups = []
    for i = 0 to mt.sources.Count() - 1
        list = ParseJson(m.streamsApi.results["s" + i.ToStr()])
        if type(list) = "roArray" and list.Count() > 0 then groups.Push({rank: sourceRank(mt.sources[i].source), index: i, streams: list})
    end for
    groups.SortBy("index")
    groups.SortBy("rank")
    all = []
    for each g in groups
        all.Append(g.streams)
    end for
    if all.Count() > 0 then m.streams = all
end sub

' After falling back: which stream took over, briefly, where the pill sits.
sub showNote(text as String)
    t = theme()
    m.note.removeChildrenIndex(m.note.getChildCount(), 0)
    ' Measure the text, then draw the background first and the text over it.
    l = mkLabel(m.note, text, bodyFont(28), t.text, 0, 0, 0, 56)
    lw = l.boundingRect().width
    m.note.removeChild(l)
    w = lw + 36 + 12 + 48
    x = (1920 - w) / 2
    mkCard(m.note, x, 972, w, 56, "0x000000D0", "chip")
    mkPoster(m.note, "pkg:/images/icons/swap.png", x + 24, 972 + 10, 36, 36, t.text)
    l.translation = [x + 24 + 36 + 12, 972]
    m.note.appendChild(l)
    m.note.visible = true
    m.pill.visible = false
    m.noteTimer.control = "stop"
    m.noteTimer.control = "start"
end sub

sub onNoteTimer()
    m.note.visible = false
    if m.bar.visible then m.pill.visible = not m.rowOpen and hasRow()
end sub

' The Streams pill: with the title bar, bottom centre; Down opens the row.
sub renderPill()
    t = theme()
    m.pill.removeChildrenIndex(m.pill.getChildCount(), 0)
    l = mkLabel(m.pill, playerText("streamsPill"), bodyFont(28), t.text, 0, 0, 0, 56)
    lw = l.boundingRect().width
    m.pill.removeChild(l)
    w = lw + 36 + 8 + 56
    x = (1920 - w) / 2
    mkCard(m.pill, x, 972, w, 56, "0x000000D0", "chip")
    mkPoster(m.pill, "pkg:/images/icons/arrow_down.png", x + 22, 972 + 10, 36, 36, t.text)
    l.translation = [x + 22 + 36 + 8, 972]
    m.pill.appendChild(l)
end sub

sub onStall()
    print "[player] stalled for "; m.stall.duration; "s"
    reconnect("The stream stalled")
end sub

' A stall or a player error: start the stream again from scratch (a fresh
' browser session and link), as backing out and picking it again would. A short
' outage upstream otherwise leaves the player spinning after the stream is back.
' The first try is immediate, then 20s, 40s. While there's no internet the task
' says "offline" and the player just waits (onError); only tries with the
' network up count, and three of those without playback mean the stream itself
' is gone, so say so. (The phone and desktop apps heal the same way.)
sub reconnect(reason as String)
    m.stall.control = "stop"
    m.retry.control = "stop"
    m.video.control = "stop"
    ' And let go of it, so none of the player's own UI (its buffering spinner)
    ' lingers under ours.
    m.video.content = invalid
    if m.task <> invalid then
        m.task.unobserveField("status")
        m.task.unobserveField("error")
        m.task.unobserveField("streamUrl")
        m.task.unobserveField("quality")
        m.task.quit = true
        m.task = invalid
    end if
    if m.restarts >= 3 then
        print "[player] giving up: "; reason
        failedForGood(reason)
        return
    end if
    m.restarts = m.restarts + 1
    print "[player] reconnecting ("; m.restarts; "): "; reason
    showWorking("Reconnecting...")
    if m.restarts = 1 then
        start()
        showWorking("Reconnecting...")
    else
        m.retry.duration = 20 * (m.restarts - 1)
        m.retry.control = "start"
    end if
end sub

sub onClosing()
    saveBest()
    m.stall.control = "stop"
    m.retry.control = "stop"
    m.video.control = "stop"
    if m.task <> invalid then m.task.quit = true
end sub

' This screen keeps the remote rather than the Video node, so OK brings up our
' bar instead of the player's own (which never said when it hid again): OK, or
' any button but Back (which leaves), shows it for a few seconds, with the
' Streams pill. Down opens the streams row; there Left/Right move (starting from
' the divider), OK plays, Up or Back closes it. Play/Pause still pauses.
function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.rowOpen then
        if key = "back" or key = "up" then
            closeRow()
            showBar()
        else if key = "left" then
            if m.rowFocus = -1 then
                m.rowFocus = m.rowSplit - 1
            else if m.rowFocus > 0 then
                m.rowFocus = m.rowFocus - 1
            end if
            renderRow()
            showBar()
        else if key = "right" then
            if m.rowFocus = -1 then
                m.rowFocus = m.rowSplit
            else if m.rowFocus < m.rowCards.Count() - 1 then
                m.rowFocus = m.rowFocus + 1
            end if
            renderRow()
            showBar()
        else if key = "OK" then
            if m.rowFocus >= 0 and m.rowFocus < m.rowCards.Count() then
                c = m.rowCards[m.rowFocus]
                if c.kind = "stream" then switchTo(c.stream, false) else playRecent(c.recent)
                showBar()
            end if
        else
            showBar()
        end if
        return true
    end if
    if key = "back" then return false
    if key = "play" then
        if m.video.state = "paused" then m.video.control = "resume" else m.video.control = "pause"
    end if
    if key = "down" and m.bar.visible then
        openRow()
        return true
    end if
    showBar()
    return true
end function
