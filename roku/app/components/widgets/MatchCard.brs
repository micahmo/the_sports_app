sub render()
    mt = m.top.match
    if mt = invalid or mt.id = invalid then return
    while m.top.getChildCount() > 0
        m.top.removeChildIndex(0)
    end while
    t = theme()
    w = m.top.width
    pad = 22
    b = 52
    nameX = pad + b + 16
    gap = 16
    m.long = []

    ' LIVE (first line) and the viewer count (second line), right-aligned.
    ' Each name gets the rest of its own line.
    right = w - pad
    liveW = 0
    viewersW = 0
    if isLiveNow(mt) then
        live = mkLabel(m.top, "LIVE", condensed("Bold", 30), t.live, 0, 22, 0, 0)
        lw = live.boundingRect().width
        live.translation = [right - lw, 22]
        mkPoster(m.top, "pkg:/images/disc.png", right - lw - 20, besideY(live, 12, "condensed", 30), 12, 12, t.live)
        liveW = lw + 20
    end if
    if mt.viewers <> invalid then
        num = mkLabel(m.top, formatViewers(mt.viewers), condensed("SemiBold", 36), t.text, 0, 72, 0, 0)
        nw = num.boundingRect().width
        num.translation = [right - nw, 72]
        mkPoster(m.top, "pkg:/images/icons/visibility.png", right - nw - 40, besideY(num, 30, "condensed", 36), 30, 30, t.outline)
        viewersW = nw + 40
    end if
    lineW = [right - liveW - gap - nameX, right - viewersW - gap - nameX]

    teams = orderedTeams(mt)
    icon = sportIcon(mt.category)
    if teams <> invalid then
        for i = 0 to 1
            y = 18 + i * (b + 8)
            badge = m.top.createChild("TeamBadge")
            badge.translation = [pad, y]
            badge.fallback = icon
            badge.uri = badgeUrl(teams[i].badge)
            badge.size = b
            nameLabel(teams[i].name, condensed("Medium", 38), nameX, y, lineW[i], b)
        end for
    else
        badge = m.top.createChild("TeamBadge")
        badge.translation = [pad, 14 + (2 * b + 8) / 2 - b / 2]   ' centred on the title's box below
        badge.fallback = icon
        badge.uri = ""
        badge.cover = posterUrl(mt)
        badge.size = b
        titleW = lineW[0]
        if lineW[1] < titleW then titleW = lineW[1]
        l = mkLabel(m.top, mt.title, condensed("Medium", 36), t.text, nameX, 14, titleW, 2 * b + 8)
        l.wrap = true
        l.maxLines = 2
    end if

    parts = []
    if m.top.sportName <> "" then parts.Push(m.top.sportName)
    parts.Push(matchTimeLabel(mt))
    ' A clear gap below the second team line (or the two-line title).
    metaY = 18 + 2 * b + 8 + 14
    mkLabel(m.top, UCase(parts.Join(" · ")), bodyFont(24), t.outline, nameX, metaY, w - nameX - pad, 32)
    onFocused()
end sub

' A team name cut to its line ("..."); remembered if it doesn't fit, so it can
' scroll while the card has focus.
sub nameLabel(text as String, font as Object, x as Float, y as Float, w as Float, h as Float)
    l = mkLabel(m.top, text, font, theme().text, x, y, 0, h)
    fits = l.boundingRect().width <= w
    l.width = w
    if not fits then m.long.Push({label: l, text: text, font: font, x: x, y: y, w: w, h: h})
end sub

' Focused: long names scroll (as TV apps do) instead of ending in "...".
sub onFocused()
    if m.long = invalid then return
    for each n in m.long
        if m.top.focused and n.scroll = invalid then
            s = m.top.createChild("ScrollingLabel")
            s.text = n.text
            s.font = n.font
            s.color = theme().text
            s.translation = [n.x, n.y]
            s.maxWidth = n.w
            s.scrollSpeed = 60   ' px/s; Roku's default is hard to read at this size
            s.height = n.h
            s.vertAlign = "center"
            n.scroll = s
            n.label.visible = false
        else if not m.top.focused and n.scroll <> invalid then
            m.top.removeChild(n.scroll)
            n.scroll = invalid
            n.label.visible = true
        end if
    end for
end sub
