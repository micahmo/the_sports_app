sub init()
    t = theme()
    m.bg = m.top.findNode("bg")
    m.ring = m.top.findNode("ring")
    m.bg.blendColor = t.card
    m.ring.blendColor = t.primary
end sub

sub layout()
    m.bg.width = m.top.width
    m.bg.height = m.top.height
    m.ring.width = m.top.width
    m.ring.height = m.top.height
end sub

sub onFocused()
    t = theme()
    m.ring.visible = m.top.focused
    if m.top.focused then m.bg.blendColor = t.cardHighest else m.bg.blendColor = t.card
    content = m.top.findNode("content")
    for i = 0 to content.getChildCount() - 1
        c = content.getChild(i)
        if c.hasField("focused") then c.focused = m.top.focused
    end for
end sub
