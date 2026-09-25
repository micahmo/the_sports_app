sub init()
    m.top.backgroundColor = theme().bg
    m.top.backgroundURI = ""

    ' Standard dialogs (the exit prompt, Settings' keyboard) in the app's
    ' colours rather than Roku's purple.
    t = theme()
    palette = CreateObject("roSGNode", "RSGPalette")
    palette.colors = {
        DialogBackgroundColor: t.cardHigh
        DialogTextColor: t.text
        DialogSecondaryTextColor: t.textDim
        DialogItemColor: t.textDim
        DialogFocusColor: t.primary
        DialogFocusItemColor: t.bg
        DialogSecondaryItemColor: t.outline
        DialogInputFieldColor: t.cardHighest
        DialogKeyboardColor: t.cardHighest   ' tints the keys; their labels are the item colour
        DialogFootprintColor: t.outline
    }
    m.top.palette = palette

    m.stack = []
    push(CreateObject("roSGNode", "HomeScreen"))

    m.global.addFields({lastInput: 0, sessionsTidied: false})
    m.device = CreateObject("roDeviceInfo")
    m.freshTimer = m.top.findNode("freshTimer")
    m.freshTimer.observeField("fire", "onFreshTimer")
    m.freshTimer.control = "start"

    ' First run: find the browser server on the LAN without being asked.
    if getDriver() = "" then startDiscovery()

    if appVersion() <> "" then
        checkForUpdate()
        m.updateTimer = m.top.findNode("updateTimer")
        m.updateTimer.observeField("fire", "checkForUpdate")
        m.updateTimer.control = "start"
    end if
end sub

' A newer release? Home and Settings say so; installing it is up to the user.
sub checkForUpdate()
    if m.top.updateStatus <> "done" then m.top.updateStatus = "checking"
    m.updateCheck = CreateObject("roSGNode", "ApiTask")
    m.updateCheck.requests = {latest: "https://api.github.com/repos/micahmo/the_sports_app/releases/latest"}
    m.updateCheck.observeField("results", "onUpdateChecked")
    m.updateCheck.control = "run"
end sub

sub onUpdateChecked()
    json = ParseJson(m.updateCheck.results.latest)
    m.updateCheck = invalid
    if json = invalid or json.tag_name = invalid then
        ' Keep an answer from an earlier check rather than forget it.
        if m.top.updateStatus <> "done" then m.top.updateStatus = "failed"
        return
    end if
    latest = json.tag_name
    if Left(latest, 1) = "v" then latest = Mid(latest, 2)
    if isNewerVersion(latest, appVersion()) then m.top.newVersion = latest else m.top.newVersion = ""
    m.top.updateStatus = "done"
end sub

sub startDiscovery()
    if m.discovery <> invalid then return
    m.top.driverStatus = "searching"
    m.discovery = CreateObject("roSGNode", "DiscoveryTask")
    m.discovery.observeField("found", "onDiscovered")
    m.discovery.control = "run"
end sub

sub onDiscovered()
    if m.discovery.found <> "" then
        setDriver(m.discovery.found)
        m.top.driverStatus = "found"
    else
        m.top.driverStatus = "missing"
    end if
    m.discovery = invalid
end sub

' Every minute, while the remote has been idle for a bit, the screen on top
' reloads its data quietly (screens that can have a `refresh` field). The app
' tends to be left open on the TV, so it never "comes back" to prompt one.
' Nothing refreshes under the player.
sub onFreshTimer()
    ' The Roku's own count misses keys from the Roku mobile app (and other
    ' network remotes), so go by whichever of it and the screens saw input last.
    idle = m.device.TimeSinceLastKeypress()
    sinceInput = CreateObject("roDateTime").AsSeconds() - m.global.lastInput
    if sinceInput < idle then idle = sinceInput
    if idle < 10 then return
    top = m.stack.Peek()
    if top.hasField("refresh") then top.refresh = true
end sub

sub push(screen as Object)
    if m.stack.Count() > 0 then m.stack.Peek().visible = false
    screen.observeField("navigate", "onNavigate")
    m.top.appendChild(screen)
    m.stack.Push(screen)
    screen.setFocus(true)
end sub

sub pop()
    screen = m.stack.Pop()
    screen.unobserveField("navigate")
    screen.closing = true
    m.top.removeChild(screen)
    top = m.stack.Peek()
    top.visible = true
    top.setFocus(true)
end sub

' A screen wants another one: {screen: "matches" | "player" | "settings", ...fields}.
sub onNavigate(ev as Object)
    req = ev.getData()
    if req = invalid or req.screen = invalid then return
    if req.screen = "matches" then
        s = CreateObject("roSGNode", "MatchesScreen")
    else if req.screen = "player" then
        s = CreateObject("roSGNode", "PlayerScreen")
    else if req.screen = "settings" then
        s = CreateObject("roSGNode", "SettingsScreen")
    else
        return
    end if
    ' Screens read what they need from `params` (a case-insensitive lookup,
    ' unlike node field names).
    s.params = req
    push(s)
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press or key <> "back" then return false
    if m.stack.Count() > 1 then
        pop()
    else
        confirmExit()
    end if
    return true
end function

' Back on Home: ask first, so a stray press doesn't close the app.
sub confirmExit()
    d = CreateObject("roSGNode", "StandardMessageDialog")
    d.title = "Exit Sports?"
    d.buttons = ["Exit", "Cancel"]
    d.observeField("buttonSelected", "onExitButton")
    m.exitDialog = d
    m.top.dialog = d
end sub

sub onExitButton()
    exiting = (m.exitDialog.buttonSelected = 0)
    m.exitDialog.close = true
    if exiting then m.top.exitApp = true
end sub
