sub init()
    t = theme()
    m.page = m.top.findNode("page")
    x0 = 96
    W = 1728
    mkLabel(m.page, "SETTINGS", condensed("SemiBold", 60), t.text, x0, 44, 800, 80)

    mkLabel(m.page, "STREAM SERVER", condensed("SemiBold", 30), t.textDim, x0 + 4, 150, 800, 40)
    mkCard(m.page, x0, 198, W, 170, t.card)
    m.address = mkLabel(m.page, "", condensed("SemiBold", 44), t.text, x0 + 32, 214, W - 64, 60)
    m.state = mkLabel(m.page, "", bodyFont(28), t.textDim, x0 + 32, 276, W - 64, 44)
    mkLabel(m.page, "A Selenium Chrome server on your network (port 4444) opens the streams.", bodyFont(24), t.outline, x0 + 32, 318, W - 64, 40)

    labels = ["Scan network", "Enter address", "Test connection"]
    icons = ["wifi_find", "settings", "visibility"]
    m.buttons = []
    bw = 420
    for i = 0 to 2
        b = m.page.createChild("FocusCard")
        b.translation = [x0 + i * (bw + 24), 400]
        b.width = bw
        b.height = 96
        content = b.findNode("content")
        label = mkLabel(content, labels[i], bodyFont(30, true), t.text, 92, 0, bw - 120, 96)
        mkPoster(content, "pkg:/images/icons/" + icons[i] + ".png", 28, besideY(label, 44, "body", 30), 44, 44, t.textDim)
        m.buttons.Push(b)
    end for
    m.focus = 0
    m.top.observeField("focusedChild", "onFocusChanged")

    mkLabel(m.page, "APP", condensed("SemiBold", 30), t.textDim, x0 + 4, 552, 800, 40)
    mkCard(m.page, x0, 600, W, 170, t.card)
    ' Two lines, centred in a card as tall as the stream server's.
    m.version = mkLabel(m.page, "", condensed("SemiBold", 44), t.text, x0 + 32, 633, W - 64, 60)
    m.versionNote = mkLabel(m.page, "", bodyFont(28), t.textDim, x0 + 32, 695, W - 64, 44)
    m.top.getScene().observeField("newVersion", "showVersion")
    m.top.getScene().observeField("updateStatus", "showVersion")
    showVersion()
    refresh()
end sub

' This build, and whether a newer one is out.
sub showVersion()
    current = appVersion()
    latest = m.top.getScene().newVersion
    status = m.top.getScene().updateStatus
    if current = "" then
        m.version.text = "Development build"
        m.versionNote.text = "Doesn't check for updates."
        return
    end if
    m.version.text = "Version " + current
    if latest <> "" then
        m.versionNote.text = "Version " + latest + " is available."
    else if status = "done" then
        m.versionNote.text = "This is the latest version."
    else if status = "failed" then
        m.versionNote.text = "Couldn't check for updates."
    else
        m.versionNote.text = "Checking for updates..."
    end if
end sub

sub onFocusChanged()
    applyFocus()
end sub

sub applyFocus()
    for i = 0 to m.buttons.Count() - 1
        m.buttons[i].focused = (i = m.focus) and m.top.isInFocusChain()
    end for
end sub

sub refresh()
    driver = getDriver()
    if driver = "" then
        m.address.text = "Not set"
        m.state.text = "Use Scan network to find it, or Enter address."
        return
    end if
    m.address.text = driver
    m.state.text = "Checking..."
    m.check = CreateObject("roSGNode", "ApiTask")
    m.check.requests = {status: driver + "/status"}
    m.check.observeField("results", "onChecked")
    m.check.control = "run"
end sub

sub onChecked()
    json = ParseJson(m.check.results.status)
    if json = invalid or json.value = invalid then
        m.state.text = "Not reachable. Is the container running?"
    else if json.value.ready = true then
        m.state.text = "Ready: " + json.value.message
    else
        m.state.text = "Reachable but busy: " + json.value.message
    end if
end sub

sub scan()
    m.address.text = "Scanning your network..."
    m.state.text = ""
    m.discovery = CreateObject("roSGNode", "DiscoveryTask")
    m.discovery.observeField("progress", "onScanProgress")
    m.discovery.observeField("found", "onScanned")
    m.discovery.control = "run"
end sub

sub onScanProgress()
    m.state.text = m.discovery.progress
end sub

sub onScanned()
    if m.discovery.found <> "" then
        setDriver(m.discovery.found)
        refresh()
    else
        m.address.text = "Nothing found"
        m.state.text = "No WebDriver server answered on ports 4444 or 9515. Try Enter address."
    end if
end sub

sub enterAddress()
    d = CreateObject("roSGNode", "StandardKeyboardDialog")
    d.title = "Stream server address"
    d.message = ["For example http://192.168.1.20:4444"]
    current = getDriver()
    if current = "" then current = "http://"
    d.text = current
    d.buttons = ["Save", "Cancel"]
    d.observeField("buttonSelected", "onDialogButton")
    m.dialog = d
    m.top.getScene().dialog = d
end sub

sub onDialogButton()
    if m.dialog.buttonSelected = 0 then
        text = m.dialog.text.Trim()
        if text <> "" and Instr(1, text, "://") = 0 then text = "http://" + text
        while Right(text, 1) = "/"
            text = Left(text, Len(text) - 1)
        end while
        setDriver(text)
        refresh()
    end if
    m.dialog.close = true
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "left" and m.focus > 0 then
        m.focus = m.focus - 1
        applyFocus()
        return true
    else if key = "right" and m.focus < m.buttons.Count() - 1 then
        m.focus = m.focus + 1
        applyFocus()
        return true
    else if key = "OK" then
        if m.focus = 0 then scan()
        if m.focus = 1 then enterAddress()
        if m.focus = 2 then refresh()
        return true
    end if
    return false
end function
