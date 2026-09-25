sub init()
    m.bg = m.top.findNode("bg")
    m.content = m.top.findNode("content")
    m.ring = m.top.findNode("ring")
    m.ring.blendColor = theme().primary
    onFocus()
end sub

sub onFocus()
    t = theme()
    active = m.top.focusPercent > 0.5 and (m.top.listHasFocus or m.top.gridHasFocus) and m.bg.visible
    m.ring.visible = active
    if active then m.bg.blendColor = t.cardHighest else m.bg.blendColor = t.card
end sub

sub render()
    c = m.top.itemContent
    if c = invalid or m.top.width = 0 then return
    ' Redraw when this stream becomes (or stops being) the last played.
    if m.watched = invalid or not m.watched.isSameNode(c) then
        if m.watched <> invalid then
            m.watched.unobserveField("lastPlayed")
            m.watched.unobserveField("quality")
            m.watched.unobserveField("stream")
        end if
        c.observeField("lastPlayed", "render")
        c.observeField("quality", "render")
        ' Background refreshes update a row's stream (viewers) in place.
        c.observeField("stream", "render")
        m.watched = c
    end if
    m.content.removeChildrenIndex(m.content.getChildCount(), 0)
    s = c.stream
    if s = invalid then
        renderHeading(c)
        return
    end if
    m.bg.visible = true
    onFocus()
    t = theme()
    w = m.top.width
    h = m.top.height
    for each n in [m.bg, m.ring]
        n.width = w
        n.height = h
    end for

    ' HD and SD differ by one letter, so colour carries the difference.
    chipColor = t.sd
    chipText = "SD"
    if s.hd = true then
        chipColor = t.hd
        chipText = "HD"
    end if
    mkCard(m.content, 22, (h - 42) / 2, 68, 42, chipColor, "chip")
    mkLabel(m.content, chipText, condensed("Bold", 28), t.bg, 22, (h - 42) / 2 - capsShift("condensed", 28), 68, 42, "center")

    ' The last-played stream picks up the accent and goes bold.
    nameColor = t.text
    weight = "Medium"
    if c.lastPlayed = true then
        nameColor = t.primary
        weight = "Bold"
    end if
    ' A stream that has been played shows what it measured on a second, dimmer
    ' line; the name and language move up to make room.
    quality = ""
    if c.quality <> invalid then quality = c.quality
    lineTop = 0
    lineH = h
    if quality <> "" then
        lineTop = 4
        lineH = 54
    end if
    name = mkLabel(m.content, "Stream " + s.streamNo.ToStr(), condensed(weight, 38), nameColor, 112, lineTop, 0, lineH)
    x = 112 + name.boundingRect().width + 16

    right = w - 22
    if s.viewers <> invalid then
        num = mkLabel(m.content, formatViewers(s.viewers), condensed("SemiBold", 34), nameColor, 0, 0, 0, h)
        nw = num.boundingRect().width
        num.translation = [right - nw, 0]
        mkPoster(m.content, "pkg:/images/icons/visibility.png", right - nw - 40, besideY(num, 30, "condensed", 34), 30, 30, t.outline)
        right = right - nw - 64
    end if
    sw = 0

    if s.language <> invalid and s.language <> "" then
        mkLabel(m.content, s.language, bodyFont(24), t.textDim, x, bodyTopOnBaseline(baselineOf(lineTop, lineH, 38), lineH, 24), right - sw - 24 - x, lineH)
    end if
    if quality <> "" then
        mkLabel(m.content, quality, bodyFont(22), t.outline, 112, lineTop + lineH - 6, right - 112, 30)
    end if
end sub

' A source heading, like the phone app's: the name, and its description on the
' right. No card, and it sits low in the row so it reads as belonging to the
' streams below it.
sub renderHeading(c as Object)
    t = theme()
    m.bg.visible = false
    m.ring.visible = false
    h = m.top.height
    top = h - 52
    mkLabel(m.content, c.heading, condensed("Bold", 32), t.text, 4, top, 0, 0)
    if c.description <> invalid and c.description <> "" then
        base = top + 0.96 * 32
        mkLabel(m.content, c.description, bodyFont(24), t.outline, 0, bodyTopOnBaseline(base, 32, 24), m.top.width - 4, 32, "right")
    end if
end sub
