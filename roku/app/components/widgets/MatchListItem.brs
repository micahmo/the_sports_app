sub init()
    m.bg = m.top.findNode("bg")
    m.card = m.top.findNode("card")
    m.ring = m.top.findNode("ring")
    onFocus()
end sub

sub onSize()
    for each n in [m.bg, m.ring]
        n.width = m.top.width
        n.height = m.top.height
    end for
    m.card.width = m.top.width
    m.card.height = m.top.height
end sub

sub onContent()
    c = m.top.itemContent
    if c = invalid then return
    ' Background refreshes update a row's match in place.
    if m.watched = invalid or not m.watched.isSameNode(c) then
        if m.watched <> invalid then m.watched.unobserveField("match")
        c.observeField("match", "onContent")
        m.watched = c
    end if
    m.card.sportName = c.sportName
    m.card.match = c.match
end sub

sub onFocus()
    t = theme()
    current = m.top.focusPercent > 0.5
    active = current and m.top.listHasFocus
    m.ring.visible = current
    if active then m.ring.blendColor = t.primary else m.ring.blendColor = t.outline
    if active then m.bg.blendColor = t.cardHighest else m.bg.blendColor = t.card
    m.card.focused = active
end sub
