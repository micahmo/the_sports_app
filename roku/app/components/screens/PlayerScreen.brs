sub init()
    t = theme()
    m.video = m.top.findNode("video")
    m.status = m.top.findNode("status")
    m.status.font = bodyFont(32)
    m.status.color = t.textDim
    m.video.observeField("state", "onVideoState")
    m.stall = m.top.findNode("stall")
    m.stall.observeField("fire", "onStall")
    m.retry = m.top.findNode("retry")
    m.retry.observeField("fire", "onRetry")

    m.bar = m.top.findNode("bar")
    m.barTitle = mkLabel(m.bar, "", condensed("SemiBold", 48), t.text, 96, 26, 1728, 60)
    m.barQuality = mkLabel(m.bar, "", bodyFont(28), t.textDim, 96, 88, 1728, 40)
    m.barTimer = m.top.findNode("barTimer")
    m.barTimer.observeField("fire", "onBarTimer")

    m.restarts = 0
end sub

sub start()
    driver = getDriver()
    if driver = "" then
        m.status.text = "No stream server is set up yet." + Chr(10) + "Open Settings on the home screen to find one."
        return
    end if
    m.status.text = "Starting..."
    m.barTitle.text = m.top.params.title
    m.task = CreateObject("roSGNode", "StreamTask")
    m.task.embedUrl = m.top.params.embedUrl
    m.task.driver = driver
    m.task.observeField("status", "onStatus")
    m.task.observeField("error", "onError")
    m.task.observeField("streamUrl", "onStreamUrl")
    m.task.observeField("quality", "onQuality")
    m.task.control = "run"
end sub

sub onStatus()
    if m.video.state <> "playing" then m.status.text = m.task.status
    placeStatus()
end sub

' The player draws a spinner in the middle while it buffers: move our text
' just below it then, so the two don't overlap. Centred otherwise.
sub placeStatus()
    if m.video.state = "buffering" then m.status.translation = [160, 600] else m.status.translation = [160, 440]
end sub

sub onError()
    m.status.visible = true
    if m.task.error = "offline" then
        ' No internet: wait, and look again in 10 seconds. Never counts as a try.
        m.task = invalid
        m.status.text = "Waiting for connection..."
        m.retry.duration = 10
        m.retry.control = "start"
        return
    end if
    if m.restarts > 0 then
        ' A reconnect that didn't work: try again after a longer gap.
        reconnect(m.task.error)
        return
    end if
    m.status.text = m.task.error + Chr(10) + "Press Back to pick another stream."
end sub

sub onRetry()
    start()
    m.status.text = "Reconnecting..."
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
    ' The player shows its own buffering spinner from here on; don't sit on it.
    m.status.visible = false
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
    m.barQuality.text = label
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
    saveQuality(m.top.params.embedUrl, label)
    m.savedAt = CreateObject("roTimespan")
end sub

sub onVideoState()
    st = m.video.state
    print "[player] "; st; " "; m.video.errorMsg
    placeStatus()
    if st = "playing" then
        m.status.visible = false
        m.stall.control = "stop"
        m.restarts = 0
    else if st = "buffering" then
        m.stall.control = "stop"
        m.stall.control = "start"
    else if st = "error" then
        reconnect("Playback failed: " + m.video.errorMsg)
    end if
end sub

sub onBarTimer()
    m.bar.visible = false
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
    if m.task <> invalid then
        m.task.unobserveField("status")
        m.task.unobserveField("error")
        m.task.unobserveField("streamUrl")
        m.task.unobserveField("quality")
        m.task.quit = true
        m.task = invalid
    end if
    m.status.visible = true
    if m.restarts >= 3 then
        print "[player] giving up: "; reason
        m.status.text = reason + Chr(10) + "Press Back to pick another stream."
        return
    end if
    m.restarts = m.restarts + 1
    print "[player] reconnecting ("; m.restarts; "): "; reason
    m.status.text = "Reconnecting..."
    if m.restarts = 1 then
        start()
        m.status.text = "Reconnecting..."
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
' any button but Back (which leaves), shows it for a few seconds. Play/Pause
' still pauses.
function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press or key = "back" then return false
    if key = "play" then
        if m.video.state = "paused" then m.video.control = "resume" else m.video.control = "pause"
    end if
    m.bar.visible = true
    m.barTimer.control = "stop"
    m.barTimer.control = "start"
    return true
end function
