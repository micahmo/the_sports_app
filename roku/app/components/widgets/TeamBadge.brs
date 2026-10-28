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
    ' The mask repeats its edge outside its square, so a picture bigger than
    ' the disc (a logo cut from a poster) is clipped to it too.
    m.mask.clippingRect = [0, 0, s, s]
    m.coverImage.width = s
    m.coverImage.height = s
    ' Decode images at the size they're shown, not full size.
    m.coverImage.loadWidth = s
    m.coverImage.loadHeight = s
    m.logo.loadWidth = s
    m.logo.loadHeight = s
    m.coverImage.translation = [0, 0]
    m.mask.visible = false
    image = badgeImage(m.top.badge)
    if m.top.cover <> "" then
        m.coverImage.uri = m.top.cover
        m.mask.visible = true
        m.logo.visible = false
        m.icon.visible = false
    else if image <> invalid and image.crop <> invalid then
        ' The whole picture, sized and moved so the logo's part fills the disc.
        c = image.crop
        w = s / c[2]
        h = s / c[3]
        m.coverImage.width = w
        m.coverImage.height = h
        m.coverImage.loadWidth = w
        m.coverImage.loadHeight = h
        m.coverImage.translation = [-c[0] * w, -c[1] * h]
        m.coverImage.uri = image.uri
        m.mask.visible = true
        m.logo.visible = false
        m.icon.visible = false
    else if image <> invalid then
        m.logo.uri = image.uri
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
