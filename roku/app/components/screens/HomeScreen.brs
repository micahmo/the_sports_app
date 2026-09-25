' Home: Live now / Popular / Settings, the three most-watched games, and every
' sport — the desktop layout of the phone app, driven with the D-pad.

sub init()
    m.page = m.top.findNode("page")
    m.rows = []
    m.fr = 0
    m.fc = 0
    m.loadedAt = invalid
    m.sig = ""
    m.top.observeField("visible", "onVisible")
    m.top.observeField("refresh", "onRefresh")
    m.top.observeField("focusedChild", "onFocusChanged")
    m.scene = m.top.getScene()
    m.scene.observeField("driverStatus", "onDriverStatus")
    showLoading()
    load()
end sub

' quiet: a background refresh. Keep what's showing if it fails or nothing
' changed, and keep the cursor on the same tile.
sub load(quiet = false as Boolean)
    m.quiet = quiet
    if m.api <> invalid then m.api.unobserveField("results")
    m.api = CreateObject("roSGNode", "ApiTask")
    m.api.requests = {
        sports: apiBase() + "/api/sports"
        live: apiBase() + "/api/matches/live"
        counts: apiBase() + "/api/matches/live/popular-viewcount"
    }
    m.api.observeField("results", "onLoaded")
    m.api.control = "run"
end sub

' Coming back to Home after a while: refresh the counts.
sub onVisible()
    if m.top.visible and m.loadedAt <> invalid and m.loadedAt.TotalSeconds() > 60 then load(true)
end sub

sub onRefresh()
    ' After a failed first load this is a retry, which may show its error.
    load(m.rows.Count() > 0)
end sub

sub onFocusChanged()
    if m.top.hasFocus() then applyFocus()
end sub

sub onDriverStatus()
    if m.settingsNote <> invalid then m.settingsNote.text = driverNote()
end sub

function driverNote() as String
    st = m.scene.driverStatus
    if st = "searching" then return "Looking for the stream server..."
    if st = "missing" then return "No stream server found"
    return ""
end function

sub showMessage(text as String)
    m.page.removeChildrenIndex(m.page.getChildCount(), 0)
    t = theme()
    mkLabel(m.page, "SPORTS", condensed("SemiBold", 60), t.text, 96, 44, 600, 80)
    mkLabel(m.page, text, bodyFont(30), t.textDim, 96, 480, 1728, 60, "center")
end sub

sub showLoading()
    showMessage("")
    mkSpinner(m.page, 960, 510)
end sub

sub onLoaded()
    r = m.api.results
    sports = ParseJson(r.sports)
    renameSports(sports)
    live = ParseJson(r.live)
    if type(sports) <> "roArray" then
        if m.quiet and m.rows.Count() > 0 then return
        showMessage("Couldn't reach streamed.pk. Press OK to retry.")
        m.rows = []
        return
    end if
    if type(live) <> "roArray" then live = []
    m.loadedAt = CreateObject("roTimespan")

    names = {}
    for each s in sports
        names[s.id] = s.name
    end for
    liveBy = {}
    for each mt in live
        if liveBy.DoesExist(mt.category) then liveBy[mt.category] = liveBy[mt.category] + 1 else liveBy[mt.category] = 1
    end for
    ' The three most watched, straight from the view-count list, as the phone
    ' app does: it includes 24/7 channels that /live doesn't list.
    top = []
    counted = ParseJson(r.counts)
    if type(counted) = "roArray" then
        ranked = []
        for each mt in counted
            if mt.viewers <> invalid and mt.id <> invalid then ranked.Push(mt)
        end for
        ranked.SortBy("viewers", "r")
        for each mt in ranked
            if top.Count() < 3 then top.Push(mt)
        end for
    end if

    ' What the page shows; if a refresh brings nothing new, leave it alone.
    sig = live.Count().ToStr()
    for each s in sports
        n = 0
        if liveBy.DoesExist(s.id) then n = liveBy[s.id]
        sig = sig + "|" + s.id + ":" + n.ToStr()
    end for
    for each mt in top
        sig = sig + "|" + mt.id + ":" + mt.viewers.ToStr()
    end for
    if m.quiet and sig = m.sig then return
    m.sig = sig
    build(sports, names, liveBy, live.Count(), top)
end sub

' What a tile opens, as a key that survives a rebuild.
function actionKey(a as Object) as String
    k = a.screen
    for each f in ["mode", "sportId", "initialMatch"]
        if a[f] <> invalid then k = k + "|" + a[f]
    end for
    return k
end function

sub build(sports as Object, names as Object, liveBy as Object, liveTotal as Integer, top as Object)
    focusKey = ""
    if m.rows.Count() > 0 then focusKey = actionKey(m.rows[m.fr][m.fc].action)
    m.page.removeChildrenIndex(m.page.getChildCount(), 0)
    t = theme()
    x0 = 96
    W = 1728
    gap = 24
    rows = []

    mkLabel(m.page, "SPORTS", condensed("SemiBold", 60), t.text, x0, 44, 600, 80)

    ' Shortcut tiles.
    tw = (W - 2 * gap) / 3
    y = 150
    tiles = []
    tiles.Push(tile(x0, y, tw, "live_tv", t.live, "Live now", liveTotal, {screen: "matches", mode: "live"}))
    tiles.Push(tile(x0 + tw + gap, y, tw, "fire", t.popular, "Popular", -1, {screen: "matches", mode: "popular"}))
    settings = tile(x0 + 2 * (tw + gap), y, tw, "settings", t.textDim, "Settings", -1, {screen: "settings"})
    m.settingsNote = mkLabel(settings.findNode("content"), driverNote(), bodyFont(22), t.outline, 24, 18, tw - 48, 36, "right")
    tiles.Push(settings)
    rows.Push(tiles)
    y = y + 120 + 34

    ' Most watched now: three cards side by side, as on a wide window.
    if top.Count() > 0 then
        section(x0, y, "Most watched now")
        y = y + 48
        cards = []
        for i = 0 to top.Count() - 1
            c = card(x0 + i * (tw + gap), y, tw, 190, {screen: "matches", mode: "live", initialMatch: top[i].id, match: top[i]})
            mc = c.findNode("content").createChild("MatchCard")
            mc.width = tw
            mc.height = 190
            name = names[top[i].category]
            if name = invalid then name = top[i].category
            mc.sportName = name
            mc.match = top[i]
            cards.Push(c)
        end for
        rows.Push(cards)
        y = y + 190 + 34
    end if

    ' All sports, four to a row.
    section(x0, y, "All sports")
    y = y + 48
    cols = 4
    sw = (W - (cols - 1) * gap) / cols
    row = []
    for i = 0 to sports.Count() - 1
        s = sports[i]
        col = i mod cols
        if col = 0 and i > 0 then
            rows.Push(row)
            row = []
            y = y + 84 + 16
        end if
        c = card(x0 + col * (sw + gap), y, sw, 84, {screen: "matches", mode: "sport", sportId: s.id, sportName: s.name})
        content = c.findNode("content")
        n = 0
        if liveBy.DoesExist(s.id) then n = liveBy[s.id]
        countW = 0
        if n > 0 then
            num = mkLabel(content, n.ToStr(), condensed("Bold", 34), t.live, 0, 0, 0, 84)
            countW = num.boundingRect().width
            num.translation = [sw - 24 - countW, 0]
            mkPoster(content, "pkg:/images/disc.png", sw - 24 - countW - 22, besideY(num, 12, "condensed", 34), 12, 12, t.live)
            countW = countW + 30
        end if
        name = mkLabel(content, s.name, bodyFont(30), t.text, 84, 0, sw - 84 - 24 - countW, 84)
        mkPoster(content, sportIcon(s.id), 24, besideY(name, 40, "body", 30), 40, 40, t.textDim)
        row.Push(c)
    end for
    if row.Count() > 0 then rows.Push(row)

    m.rows = rows
    ' Keep the cursor on the tile it was on, wherever that tile is now (a
    ' refresh can add or drop the most-watched row, or change its games).
    found = false
    for r = 0 to rows.Count() - 1
        for c = 0 to rows[r].Count() - 1
            if not found and focusKey <> "" and actionKey(rows[r][c].action) = focusKey then
                m.fr = r
                m.fc = c
                found = true
            end if
        end for
    end for
    if m.fr > rows.Count() - 1 then m.fr = rows.Count() - 1
    if m.fc > rows[m.fr].Count() - 1 then m.fc = rows[m.fr].Count() - 1
    applyFocus()
end sub

function card(x as Float, y as Float, w as Float, h as Float, action as Object) as Object
    c = m.page.createChild("FocusCard")
    c.translation = [x, y]
    c.width = w
    c.height = h
    c.action = action
    return c
end function

function tile(x as Float, y as Float, w as Float, icon as String, color as String, label as String, count as Integer, action as Object) as Object
    t = theme()
    c = card(x, y, w, 120, action)
    content = c.findNode("content")
    mkPoster(content, "pkg:/images/icons/" + icon + ".png", 24, 18, 48, 48, color)
    mkLabel(content, label, bodyFont(30, true), t.text, 24, 72, w - 48, 36)
    if count >= 0 then
        num = mkLabel(content, count.ToStr(), condensed("Bold", 40), t.live, 0, 16, 0, 48)
        nw = num.boundingRect().width
        num.translation = [w - 24 - nw, 16]
        mkPoster(content, "pkg:/images/disc.png", w - 24 - nw - 22, besideY(num, 12, "condensed", 40), 12, 12, t.live)
    end if
    return c
end function

sub section(x as Float, y as Float, text as String)
    mkLabel(m.page, UCase(text), condensed("SemiBold", 30), theme().textDim, x + 4, y, 800, 40)
end sub

sub applyFocus()
    for r = 0 to m.rows.Count() - 1
        for c = 0 to m.rows[r].Count() - 1
            m.rows[r][c].focused = (r = m.fr and c = m.fc) and m.top.isInFocusChain()
        end for
    end for
end sub

' Moving between rows keeps to the column nearest the current one.
sub moveRow(delta as Integer)
    nr = m.fr + delta
    if nr < 0 or nr > m.rows.Count() - 1 then return
    cur = m.rows[m.fr][m.fc]
    cx = cur.translation[0] + cur.width / 2
    best = 0
    bestD = 99999
    for i = 0 to m.rows[nr].Count() - 1
        n = m.rows[nr][i]
        d = Abs(n.translation[0] + n.width / 2 - cx)
        if d < bestD then
            bestD = d
            best = i
        end if
    end for
    m.fr = nr
    m.fc = best
    applyFocus()
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    noteInput()
    if m.rows.Count() = 0 then
        if key = "OK" then
            showLoading()
            load()
            return true
        end if
        return false
    end if
    if key = "up" then
        moveRow(-1)
        return true
    else if key = "down" then
        moveRow(1)
        return true
    else if key = "left" then
        if m.fc > 0 then m.fc = m.fc - 1
        applyFocus()
        return true
    else if key = "right" then
        if m.fc < m.rows[m.fr].Count() - 1 then m.fc = m.fc + 1
        applyFocus()
        return true
    else if key = "OK" then
        m.top.navigate = m.rows[m.fr][m.fc].action
        return true
    end if
    return false
end function
