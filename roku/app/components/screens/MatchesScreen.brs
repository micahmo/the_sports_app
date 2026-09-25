sub init()
    m.titleGroup = m.top.findNode("titleGroup")
    m.list = m.top.findNode("list")
    m.streams = m.top.findNode("streams")
    m.header = m.top.findNode("header")
    m.messages = m.top.findNode("messages")
    m.matches = []
    m.names = {}
    m.shown = invalid
    m.lastPlayed = ""
    m.streamItems = []
    m.list.observeField("itemFocused", "onMatchFocused")
    m.list.observeField("itemSelected", "onMatchSelected")
    m.streams.observeField("itemSelected", "onStreamSelected")
    m.streams.observeField("itemFocused", "onStreamFocused")
    m.streamFocus = -1
    m.loadedAt = invalid
    m.sig = ""
    m.streamsSig = ""
    m.streamsTotal = 0
    m.top.observeField("focusedChild", "onFocusChanged")
    m.top.observeField("refresh", "onRefresh")
    m.top.observeField("visible", "onVisible")
end sub

sub start()
    p = m.top.params
    m.mode = p.mode
    title = "Live"
    if m.mode = "popular" then title = "Popular"
    if m.mode = "sport" then title = p.sportName
    m.title = title
    renderTitle(invalid)
    loading("list")

    url = apiBase() + "/api/matches/live"
    if m.mode = "popular" then url = apiBase() + "/api/matches/live/popular"
    if m.mode = "sport" then url = apiBase() + "/api/matches/" + p.sportId
    m.url = url
    fetch(false)
end sub

' quiet: a background refresh (see applyRefresh).
sub fetch(quiet as Boolean)
    m.quiet = quiet
    if m.api <> invalid then m.api.unobserveField("results")
    m.api = CreateObject("roSGNode", "ApiTask")
    m.api.requests = {
        matches: m.url
        counts: apiBase() + "/api/matches/live/popular-viewcount"
        sports: apiBase() + "/api/sports"
    }
    m.api.observeField("results", "onLoaded")
    m.api.control = "run"
end sub

sub onRefresh()
    if m.url = invalid then return
    ' With nothing listed yet (a failed or empty load) this is a plain reload.
    fetch(m.list.content <> invalid)
end sub

' Back from the player after a while.
sub onVisible()
    if not m.top.visible then return
    ' The stream just played has measured itself: show it on its row.
    for each c in m.streamItems
        c.quality = qualityLabel(c.stream.embedUrl)
    end for
    if m.loadedAt <> invalid and m.loadedAt.TotalSeconds() > 60 then fetch(true)
end sub

sub renderTitle(count as Dynamic)
    t = theme()
    m.titleGroup.removeChildrenIndex(m.titleGroup.getChildCount(), 0)
    title = mkLabel(m.titleGroup, UCase(m.title), condensed("SemiBold", 60), t.text, 96, 44, 0, 80)
    if count <> invalid and m.mode <> "sport" then
        w = title.boundingRect().width
        ' On the title's baseline, as in the phone app.
        mkLabel(m.titleGroup, count.ToStr(), condensed("SemiBold", 40), t.live, 96 + w + 16, topOnBaseline(baselineOf(44, 80, 60), 40), 0, 0)
    end if
end sub

' One line of text in place of the list ("list") or the streams ("streams").
' Two fixed labels whose text changes, so messages can never pile up.
sub message(where as String, text as String)
    if m.msg = invalid then
        m.msg = {
            list: mkLabel(m.messages, "", bodyFont(30), theme().textDim, 96, 420, 780, 60, "center")
            streams: mkLabel(m.messages, "", bodyFont(30), theme().textDim, 924, 520, 900, 60, "center")
        }
    end if
    l = m.msg[where]
    l.text = text
    l.visible = (text <> "")
    if m.spin <> invalid and m.spin[where] <> invalid then
        m.spin[where].visible = false
        m.spin[where].control = "stop"
    end if
end sub

' A spinner in place of the list or the streams while they load; the next
' message() (including "" once they've loaded) takes it away.
sub loading(where as String)
    message(where, "")
    if m.spin = invalid then m.spin = {}
    if m.spin[where] = invalid then
        ' The list only loads visibly when the screen opens and is still empty,
        ' so its spinner sits mid-screen (as on Home); the streams' sits in
        ' their panel, beside the list.
        centres = {list: [960, 510], streams: [1374, 550]}
        c = centres[where]
        m.spin[where] = mkSpinner(m.messages, c[0], c[1])
    end if
    m.spin[where].visible = true
    m.spin[where].control = "start"
end sub

sub onLoaded()
    r = m.api.results
    matches = ParseJson(r.matches)
    quiet = m.quiet and m.list.content <> invalid
    if type(matches) <> "roArray" then
        if quiet then return   ' keep what's showing
        message("list", "Couldn't load matches.")
        return
    end if
    m.loadedAt = CreateObject("roTimespan")
    sports = ParseJson(r.sports)
    renameSports(sports)
    if type(sports) = "roArray" then
        for each s in sports
            m.names[s.id] = s.name
        end for
    end if
    matches = withViewers(matches, viewerCounts(ParseJson(r.counts)))
    ' Opened from a Home card whose match isn't in this list (e.g. a 24/7
    ' channel the API doesn't call live): put it first so it can be watched.
    p = m.top.params
    if p.initialMatch <> invalid and p.match <> invalid then
        found = false
        for each mt in matches
            if mt.id = p.initialMatch then found = true
        end for
        if not found then matches.Unshift(p.match)
    end if
    if quiet then
        applyRefresh(matches)
        return
    end if
    m.matches = matches
    m.sig = matchesSignature(matches)
    renderTitle(m.matches.Count())
    if m.matches.Count() = 0 then
        message("list", "Nothing on right now.")
        return
    end if
    message("list", "")
    m.swapping = true
    m.list.content = listContent(m.matches)

    first = 0
    want = m.top.params.initialMatch
    if want <> invalid then
        for i = 0 to m.matches.Count() - 1
            if m.matches[i].id = want then first = i
        end for
    end if
    if first > 0 then m.list.jumpToItem = first
    m.swapping = false
    m.list.setFocus(true)
    showMatch(first)
end sub

function listContent(matches as Object) as Object
    content = CreateObject("roSGNode", "ContentNode")
    for each mt in matches
        item = content.createChild("ContentNode")
        sportName = ""
        ' A sport's own list doesn't need the sport on every row.
        if m.mode <> "sport" then
            sportName = m.names[mt.category]
            if sportName = invalid then sportName = mt.category
        end if
        item.addFields({match: mt, sportName: sportName})
    end for
    return content
end function

' What the list shows; a refresh that changes none of it leaves the list alone.
function matchesSignature(matches as Object) as String
    s = ""
    for each mt in matches
        v = ""
        if mt.viewers <> invalid then v = mt.viewers.ToStr()
        s = s + mt.id + ":" + v + "|"
    end for
    return s
end function

' A background refresh: swap in the new list without moving the cursor off the
' match it's on (onto its neighbour if that match has finished), then refresh
' the showing match's streams the same way.
sub applyRefresh(matches as Object)
    sig = matchesSignature(matches)
    if sig <> m.sig then
        m.sig = sig
        index = m.list.itemFocused
        focusedId = ""
        if index >= 0 and index < m.matches.Count() then focusedId = m.matches[index].id
        m.matches = matches
        renderTitle(matches.Count())
        if matches.Count() = 0 then
            m.list.content = invalid
            m.streams.content = invalid
            m.streamItems = []
            m.shown = invalid
            m.header.removeChildrenIndex(m.header.getChildCount(), 0)
            message("streams", "")
            message("list", "Nothing on right now.")
            m.list.setFocus(true)
            m.inStreams = false
            return
        end if
        message("list", "")
        for i = 0 to matches.Count() - 1
            if matches[i].id = focusedId then index = i
        end for
        if index < 0 then index = 0
        if index > matches.Count() - 1 then index = matches.Count() - 1
        m.swapping = true
        if sameMatches(m.list.content, matches) then
            ' Same games in the same order: update the rows where they are.
            ' Swapping the content makes the list reposition the cursor row.
            for i = 0 to matches.Count() - 1
                m.list.content.getChild(i).match = matches[i]
            end for
        else
            m.list.content = listContent(matches)
            m.list.jumpToItem = index
        end if
        m.swapping = false
        print "refresh: list changed, cursor on "; index
        if m.shown <> invalid and matches[index].id <> m.shown.id then
            ' The match that was showing has gone: show the one under the cursor.
            showMatch(index)
            return
        end if
        mt = matches[index]
        if m.shown <> invalid and headerKey(mt) <> headerKey(m.shown) then
            v = mt.viewers
            if v = invalid then v = m.streamsTotal
            renderHeader(mt, v)
        end if
        m.shown = mt
    end if
    if m.shown <> invalid then loadStreams(m.shown, m.streamItems.Count() > 0)
end sub

function sameMatches(content as Dynamic, matches as Object) as Boolean
    if content = invalid or content.getChildCount() <> matches.Count() then return false
    for i = 0 to matches.Count() - 1
        if content.getChild(i).match.id <> matches[i].id then return false
    end for
    return true
end function

' The same streams under the same headings, in the same order.
function sameStreams(a as Dynamic, b as Object) as Boolean
    if a = invalid or a.getChildCount() <> b.getChildCount() then return false
    for i = 0 to b.getChildCount() - 1
        x = a.getChild(i)
        y = b.getChild(i)
        if (x.stream = invalid) <> (y.stream = invalid) then return false
        if x.stream <> invalid and x.stream.embedUrl <> y.stream.embedUrl then return false
        if x.heading <> invalid and x.heading <> y.heading then return false
    end for
    return true
end function

function headerKey(mt as Object) as String
    v = ""
    if mt.viewers <> invalid then v = mt.viewers.ToStr()
    return mt.title + "|" + v + "|" + isLiveNow(mt).ToStr()
end function

' Back from the player: return to whichever list had the cursor.
sub onFocusChanged()
    if not m.top.hasFocus() then return
    if m.inStreams = true and m.streams.content <> invalid then m.streams.setFocus(true) else m.list.setFocus(true)
end sub

sub focusStreams()
    ' The match under the cursor isn't the one showing, or its streams are
    ' still loading: move over once they arrive, not into a stale or empty list.
    if m.list.itemFocused >= 0 and m.list.itemFocused < m.matches.Count() then
        if m.shown = invalid or m.shown.id <> m.matches[m.list.itemFocused].id then
            m.wantStreams = true
            showMatch(m.list.itemFocused)
            return
        end if
    end if
    if m.streamsLoading = true then
        m.wantStreams = true
        return
    end if
    if m.streamItems.Count() > 0 then
        if isHeading(m.streams.itemFocused) then
            m.streamFocus = m.streams.itemFocused + 1
            m.streams.jumpToItem = m.streamFocus
        end if
        m.streams.setFocus(true)
        m.inStreams = true
    end if
end sub

' Moving through the list: show that match right away. Streams requested for a
' match the cursor has already left are ignored when they arrive.
sub onMatchFocused()
    ' Replacing the list reports the cursor on row 0 and then where it's put;
    ' neither is the user moving.
    if m.swapping = true then return
    noteInput()
    showMatch(m.list.itemFocused)
end sub

sub onMatchSelected()
    focusStreams()
end sub

sub showMatch(index as Integer)
    if index < 0 or index > m.matches.Count() - 1 then return
    mt = m.matches[index]
    if m.shown <> invalid and m.shown.id = mt.id then return
    m.shown = mt
    renderHeader(mt, mt.viewers)
    if not m.list.hasFocus() then
        m.list.setFocus(true)
        m.inStreams = false
    end if
    m.streamItems = []
    m.streams.content = invalid
    m.streamsSig = ""
    loading("streams")
    loadStreams(mt, false)
end sub

' quiet: a background refresh; keep what's showing if it fails or nothing changed.
sub loadStreams(mt as Object, quiet as Boolean)
    m.streamsQuiet = quiet
    if not quiet then m.streamsLoading = true
    m.streamsFor = mt
    requests = {}
    for i = 0 to mt.sources.Count() - 1
        s = mt.sources[i]
        requests["s" + i.ToStr()] = apiBase() + "/api/stream/" + s.source + "/" + s.id
    end for
    if m.streamsApi <> invalid then m.streamsApi.unobserveField("results")
    m.streamsApi = CreateObject("roSGNode", "ApiTask")
    m.streamsApi.requests = requests
    m.streamsApi.observeField("results", "onStreamsLoaded")
    m.streamsApi.control = "run"
end sub

sub onStreamsLoaded()
    mt = m.streamsFor
    quiet = m.streamsQuiet
    if not quiet then m.streamsLoading = false
    r = m.streamsApi.results
    groups = []
    for i = 0 to mt.sources.Count() - 1
        list = ParseJson(r["s" + i.ToStr()])
        if type(list) = "roArray" and list.Count() > 0 then groups.Push({rank: sourceRank(mt.sources[i].source), index: i, streams: list})
    end for
    groups.SortBy("index")
    groups.SortBy("rank")

    ' A heading row per source, as in the phone app ("ADMIN   Admin added
    ' streams"), then its streams. m.streamItems holds the stream rows only.
    content = CreateObject("roSGNode", "ContentNode")
    items = []
    total = 0
    sig = ""
    for each g in groups
        source = mt.sources[g.index].source
        head = content.createChild("ContentNode")
        head.addFields({heading: UCase(source), description: sourceDescription(source)})
        for each s in g.streams
            item = content.createChild("ContentNode")
            item.addFields({stream: s, lastPlayed: (s.embedUrl = m.lastPlayed), quality: qualityLabel(s.embedUrl)})
            items.Push(item)
            v = ""
            if s.viewers <> invalid then
                total = total + s.viewers
                v = s.viewers.ToStr()
            end if
            sig = sig + s.embedUrl + ":" + v + "|"
        end for
    end for
    ' A background refresh that failed or brought nothing new: leave the list,
    ' and the cursor, alone.
    if quiet and (items.Count() = 0 or sig = m.streamsSig) then return
    m.streamsSig = sig
    m.streamsTotal = total
    if items.Count() = 0 then
        m.streamItems = []
        m.wantStreams = false
        message("streams", "No streams available.")
        return
    end if
    message("streams", "")
    if quiet and sameStreams(m.streams.content, content) then
        ' Same streams: update the rows where they are (viewers), so the list
        ' doesn't reposition the cursor row.
        old = m.streams.content
        m.streamItems = []
        for i = 0 to content.getChildCount() - 1
            if old.getChild(i).stream <> invalid then
                old.getChild(i).stream = content.getChild(i).stream
                m.streamItems.Push(old.getChild(i))
            end if
        end for
    else if quiet then
        ' Keep the cursor on the stream it was on (or the first, if it's gone).
        focusedUrl = ""
        old = m.streams.content
        if old <> invalid and m.streamFocus >= 0 and m.streamFocus < old.getChildCount() then
            was = old.getChild(m.streamFocus)
            if was.stream <> invalid then focusedUrl = was.stream.embedUrl
        end if
        target = 1   ' the first stream; 0 is a heading
        for i = 0 to content.getChildCount() - 1
            c = content.getChild(i)
            if c.stream <> invalid and c.stream.embedUrl = focusedUrl then target = i
        end for
        m.streamItems = items
        m.streams.content = content
        m.streamFocus = target
        m.streams.jumpToItem = target
        print "refresh: streams changed, cursor on "; target
    else
        m.streamItems = items
        m.streams.content = content
        if m.wantStreams = true then
            m.wantStreams = false
            focusStreams()
        end if
    end if
    ' Prefer the site's match total; summing streams undercounts.
    if mt.viewers = invalid then renderHeader(mt, total)
end sub

function isHeading(index as Integer) as Boolean
    c = m.streams.content
    if c = invalid or index < 0 or index >= c.getChildCount() then return false
    return c.getChild(index).heading <> invalid
end function

' Heading rows can't hold the cursor: move on past them in the direction it was
' going (back down if there is nothing above). A jump doesn't report itemFocused
' back, so note where it lands ourselves; otherwise the next move is judged
' from the old position and bounces back off the heading.
sub onStreamFocused()
    noteInput()
    i = m.streams.itemFocused
    if not isHeading(i) then
        m.streamFocus = i
        return
    end if
    if i < m.streamFocus and i > 0 then
        target = i - 1
    else if i + 1 < m.streams.content.getChildCount() then
        target = i + 1
    else
        return
    end if
    m.streamFocus = target
    m.streams.jumpToItem = target
end sub

sub onStreamSelected()
    item = m.streams.content.getChild(m.streams.itemSelected)
    if item = invalid or item.stream = invalid then return
    s = item.stream
    m.lastPlayed = s.embedUrl
    for each c in m.streamItems
        c.lastPlayed = (c.stream.embedUrl = m.lastPlayed)
    end for
    m.top.navigate = {screen: "player", embedUrl: s.embedUrl, title: m.shown.title}
end sub

' Both teams large with their badges, then LIVE, sport, time and viewers.
sub renderHeader(mt as Object, watching as Dynamic)
    t = theme()
    m.header.removeChildrenIndex(m.header.getChildCount(), 0)
    w = 900
    h = 232
    mkCard(m.header, 0, 0, w, h, t.card)
    teams = orderedTeams(mt)
    icon = sportIcon(mt.category)
    b = 64
    if teams <> invalid then
        for i = 0 to 1
            y = 20 + i * (b + 10)
            badge = m.header.createChild("TeamBadge")
            badge.translation = [24, y]
            badge.fallback = icon
            badge.uri = badgeUrl(teams[i].badge)
            badge.size = b
            mkLabel(m.header, teams[i].name, condensed("SemiBold", 50), t.text, 24 + b + 20, y, w - b - 68, b)
        end for
    else
        badge = m.header.createChild("TeamBadge")
        badge.translation = [24, 16 + (2 * b + 10) / 2 - b / 2]   ' centred on the title's box below
        badge.fallback = icon
        badge.uri = ""
        badge.cover = posterUrl(mt)
        badge.size = b
        l = mkLabel(m.header, mt.title, condensed("SemiBold", 46), t.text, 24 + b + 20, 16, w - b - 68, 2 * b + 10)
        l.wrap = true
        l.maxLines = 2
    end if

    parts = []
    name = m.names[mt.category]
    if name = invalid then name = mt.category
    parts.Push(name)
    parts.Push(matchTimeLabel(mt))
    if watching <> invalid and watching > 0 then parts.Push(formatViewers(watching) + " watching")
    ' Below the second team line with room to breathe; LIVE and the details
    ' share a baseline, as in the phone app.
    metaY = 20 + 2 * b + 10 + 18
    base = baselineOf(metaY, 40, 30)
    x = 24
    if isLiveNow(mt) then
        live = mkLabel(m.header, "LIVE", condensed("Bold", 30), t.live, x + 20, metaY, 0, 40)
        mkPoster(m.header, "pkg:/images/disc.png", x, besideY(live, 12, "condensed", 30), 12, 12, t.live)
        x = x + 20 + live.boundingRect().width + 16
    end if
    ' Beside bold red LIVE the details look low on the exact baseline; lift them.
    mkLabel(m.header, UCase(parts.Join(" · ")), bodyFont(24), t.textDim, x, bodyTopOnBaseline(base, 40, 24, 2), w - x - 24, 40)
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    noteInput()
    if key = "right" and m.list.hasFocus() then
        focusStreams()
        return true
    else if (key = "left" or key = "back") and not m.list.hasFocus() then
        ' Back from the streams returns to the matches, not out of the screen.
        m.list.setFocus(true)
        m.inStreams = false
        return true
    end if
    return false
end function
