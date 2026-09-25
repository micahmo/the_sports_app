sub init()
    m.disc = m.top.findNode("disc")
    m.logo = m.top.findNode("logo")
    m.icon = m.top.findNode("icon")
    m.disc.blendColor = theme().disc
    m.icon.blendColor = "0x55585FFF"
    m.logo.observeField("loadStatus", "onLoad")
    m.mask = m.top.findNode("mask")
    m.coverImage = m.top.findNode("coverImage")
    m.coverImage.observeField("loadStatus", "onCoverLoad")
end sub

sub update()
    s = m.top.size
    m.disc.width = s
    m.disc.height = s
    pad = s * 0.14
    m.logo.translation = [pad, pad]
    m.logo.width = s - 2 * pad
    m.logo.height = s - 2 * pad
    ip = s * 0.2
    m.icon.translation = [ip, ip]
    m.icon.width = s - 2 * ip
    m.icon.height = s - 2 * ip
    m.icon.uri = m.top.fallback
    m.mask.maskSize = [s, s]
    m.coverImage.width = s
    m.coverImage.height = s
    ' Decode images at the size they're shown, not full size.
    m.coverImage.loadWidth = s
    m.coverImage.loadHeight = s
    m.logo.loadWidth = s
    m.logo.loadHeight = s
    m.mask.visible = false
    if m.top.cover <> "" then
        m.coverImage.uri = m.top.cover
        m.mask.visible = true
        m.logo.visible = false
        m.icon.visible = false
    else if m.top.uri <> "" then
        m.logo.uri = m.top.uri
        m.logo.visible = true
        m.icon.visible = false
    else
        m.logo.visible = false
        m.icon.visible = true
    end if
end sub

sub onCoverLoad()
    if m.coverImage.loadStatus = "failed" then
        m.mask.visible = false
        m.icon.visible = true
    end if
end sub

sub onLoad()
    if m.logo.loadStatus = "failed" then
        m.logo.visible = false
        m.icon.visible = true
    end if
end sub
