' Shared by the scenes and the tasks. Mirrors lib/src/theme.dart (dark) and the
' helpers in lib/src/widgets/match_widgets.dart.

' The app's colours, the same as the phone app's dark theme: from
' shared/app_data.json, via source/generated/app_data.brs.
function theme() as Object
    return appPalette()
end function

function apiBase() as String
    return "https://streamed.pk"
end function

' ---- UI builders -----------------------------------------------------------

function mkFont(file as String, size as Integer) as Object
    f = CreateObject("roSGNode", "Font")
    f.uri = "pkg:/fonts/" + file
    f.size = size
    return f
end function

' Condensed display face (titles, names, numbers) and the body face.
function condensed(weight as String, size as Integer) as Object
    return mkFont("BarlowSemiCondensed-" + weight + ".ttf", size)
end function

function bodyFont(size as Integer, medium = false as Boolean) as Object
    if medium then return mkFont("roboto-medium.ttf", size)
    return mkFont("roboto-regular.ttf", size)
end function

function mkLabel(parent as Object, text as String, font as Object, color as String, x as Float, y as Float, w as Float, h as Float, align = "left" as String) as Object
    l = parent.createChild("Label")
    l.text = text
    l.font = font
    l.color = color
    l.translation = [x, y]
    l.width = w
    l.height = h
    l.horizAlign = align
    l.vertAlign = "center"
    return l
end function

' A turning ring in place of "Loading..." text, centred on (cx, cy).
function mkSpinner(parent as Object, cx as Float, cy as Float) as Object
    s = parent.createChild("BusySpinner")
    s.translation = [cx - 36, cy - 36]   ' images/spinner.png is 72px
    s.poster.uri = "pkg:/images/spinner.png"
    s.poster.blendColor = theme().primary
    s.spinInterval = 1
    s.control = "start"
    return s
end function

function mkPoster(parent as Object, uri as String, x as Float, y as Float, w as Float, h as Float, blend = "" as String) as Object
    p = parent.createChild("Poster")
    p.uri = uri
    p.translation = [x, y]
    p.width = w
    p.height = h
    p.loadDisplayMode = "scaleToFit"
    if blend <> "" then p.blendColor = blend
    return p
end function

' Labels centre their line box, not their capitals, and the two faces sit
' differently in that box (measured on a Roku TV screenshot): Barlow's capitals
' ~0.04em below its centre, Roboto's ~0.1em above. capsShift is how far the
' capitals' centre is from the box's; things placed beside text go by it, so
' they line up with the letters instead of the box.
function capsShift(face as String, size as Float) as Float
    if face = "body" then return -0.1 * size
    return 0.04 * size
end function

' Top y for something ih tall beside label l, centred on l's capitals.
function besideY(l as Object, ih as Float, face as String, size as Float) as Float
    r = l.boundingRect()
    return r.y + r.height / 2 - ih / 2 + capsShift(face, size)
end function

' Barlow in a Label: the line box is 1.2em tall and the baseline 0.96em below
' its top (measured on a Roku). baselineOf gives a centred label's baseline;
' topOnBaseline where to put an auto-height label (height 0) so its text sits
' on that baseline — for two sizes side by side, like "LIVE 3".
function baselineOf(labelY as Float, labelH as Float, size as Float) as Float
    return labelY + (labelH - 1.2 * size) / 2 + 0.96 * size
end function

function topOnBaseline(baseline as Float, size as Float) as Float
    return baseline - 0.96 * size
end function

' Roboto in a Label sits differently: its baseline is 0.28em below the centre of
' the label's box (measured). Top y for a Roboto label of height boxH whose text
' should sit on `baseline` — e.g. "English" beside "Stream 1".
' opticalLift raises the text above the exact baseline where it would otherwise
' look low: small grey text beside large bold coloured text (e.g. after LIVE).
function bodyTopOnBaseline(baseline as Float, boxH as Float, size as Float, opticalLift = 0 as Float) as Float
    return baseline - boxH / 2 - 0.28 * size - opticalLift
end function

' A rounded rectangle (9-patch), tinted.
function mkCard(parent as Object, x as Float, y as Float, w as Float, h as Float, color as String, image = "card" as String) as Object
    p = parent.createChild("Poster")
    p.uri = "pkg:/images/" + image + ".9.png"
    p.translation = [x, y]
    p.width = w
    p.height = h
    p.blendColor = color
    return p
end function

' ---- formatting -------------------------------------------------------------

' The user did something (a key, the cursor moving). The background refresh
' waits for a quiet spell; see MainScene's onFreshTimer.
sub noteInput()
    m.global.lastInput = CreateObject("roDateTime").AsSeconds()
end sub

' Sport names as North Americans say them (shared/app_data.json). Only the names
' change: the ids, which requests and icons use, stay as the API has them.
' Renames the parsed /api/sports list in place.
sub renameSports(sports as Dynamic)
    if type(sports) <> "roArray" then return
    renamed = appSportDisplayNames()
    for each s in sports
        if s.id <> invalid and renamed.DoesExist(s.id) then s.name = renamed[s.id]
    end for
end sub

' "1080p60 · 8.5 Mbps" from {height, fps, mbps}; "" if there's nothing yet.
' Frame rates snap to the usual ones (a count over a segment is approximate).
function qualityText(q as Dynamic) as String
    if q = invalid or q.mbps = invalid or q.mbps <= 0 then return ""
    tenths = Int(q.mbps * 10 + 0.5)
    rate = (tenths \ 10).ToStr() + "." + (tenths mod 10).ToStr() + " Mbps"
    if q.height = invalid or q.height <= 0 then return rate
    fps = Int(q.fps + 0.5)
    for each s in [24, 25, 30, 50, 60]
        if Abs(q.fps - s) / s < 0.1 then fps = s
    end for
    res = q.height.ToStr() + "p"
    if fps > 0 then res = res + fps.ToStr()
    return res + " · " + rate
end function

' What a stream measured when it was last played, or "". Kept for two days
' (a stream only lasts its match), and only the latest 40, since the registry
' is small.
function qualityLabel(embedUrl as String) as String
    s = CreateObject("roRegistrySection", "quality")
    if not s.Exists(embedUrl) then return ""
    v = ParseJson(s.Read(embedUrl))
    if v = invalid or v.label = invalid then return ""
    if CreateObject("roDateTime").AsSeconds() - v.at > 2 * 86400 then return ""
    return v.label
end function

sub saveQuality(embedUrl as String, label as String)
    s = CreateObject("roRegistrySection", "quality")
    now = CreateObject("roDateTime").AsSeconds()
    s.Write(embedUrl, FormatJson({label: label, at: now}))
    keys = s.GetKeyList()
    if keys.Count() > 40 then
        oldest = ""
        oldestAt = now + 1
        for each k in keys
            v = ParseJson(s.Read(k))
            at = 0
            if v <> invalid and v.at <> invalid then at = v.at
            if at < oldestAt then
                oldest = k
                oldestAt = at
            end if
        end for
        if oldest <> "" then s.Delete(oldest)
    end if
    s.Flush()
end sub

function formatViewers(n as Dynamic) as String
    if n = invalid then return ""
    n = Int(n)
    if n < 1000 then return n.ToStr()
    if n < 10000 then
        tenths = Int((n + 50) / 100)          ' round to one decimal
        return (tenths \ 10).ToStr() + "." + (tenths mod 10).ToStr() + "k"
    end if
    return Int((n + 500) / 1000).ToStr() + "k"
end function

' Match dates are unix milliseconds; beyond 32 bits, so go through a Double.
function matchSeconds(match as Object) as Integer
    if match.date = invalid then return 0
    return Int(match.date / 1000#)
end function

function nowSeconds() as Integer
    return CreateObject("roDateTime").AsSeconds()
end function

' Started, or starting within 15 minutes.
function isLiveNow(match as Object) as Boolean
    return matchSeconds(match) <= nowSeconds() + 15 * 60
end function

' "7:00 PM" today, otherwise "OCT 10 · 7:00 PM".
function matchTimeLabel(match as Object) as String
    dt = CreateObject("roDateTime")
    dt.FromSeconds(matchSeconds(match))
    dt.ToLocalTime()
    now = CreateObject("roDateTime")
    now.ToLocalTime()
    h = dt.GetHours()
    ampm = "AM"
    if h >= 12 then ampm = "PM"
    h = h mod 12
    if h = 0 then h = 12
    mins = dt.GetMinutes().ToStr()
    if Len(mins) = 1 then mins = "0" + mins
    t = h.ToStr() + ":" + mins + " " + ampm
    if dt.GetYear() = now.GetYear() and dt.GetMonth() = now.GetMonth() and dt.GetDayOfMonth() = now.GetDayOfMonth() then return t
    months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    return months[dt.GetMonth() - 1] + " " + dt.GetDayOfMonth().ToStr() + " · " + t
end function

' ---- API data ---------------------------------------------------------------

function sportIcon(category as String) as String
    name = appSportIcons()[category]
    if name = invalid then name = appDefaultSportIcon()
    return "pkg:/images/icons/" + name + ".png"
end function

' The event's poster, for matches without teams (as posterUrlFromMatch in the
' phone app).
function posterUrl(match as Object) as String
    p = match.poster
    if p = invalid or p = "" then return ""
    if Left(p, 4) = "http" then return p
    if Left(p, 1) = "/" then return apiBase() + p + ".webp"
    return apiBase() + "/api/images/proxy/" + p + ".webp"
end function

function badgeUrl(badge as Dynamic) as String
    if badge = invalid or badge = "" then return ""
    return apiBase() + "/api/images/badge/" + badge + ".webp"
end function

' The two teams in the order the title names them — the API's home/away does
' not always match the title. Invalid when the match has no teams.
function orderedTeams(match as Object) as Dynamic
    if match.teams = invalid then return invalid
    home = match.teams.home
    away = match.teams.away
    if home = invalid or away = invalid or home.name = invalid or away.name = invalid then return invalid
    ih = Instr(1, match.title, home.name)
    ia = Instr(1, match.title, away.name)
    if ih > 0 and ia > 0 and ia < ih then return [away, home]
    return [home, away]
end function

' streamed.pk lists its better sources first; mirror that (unknown ones last).
function sourceRank(source as String) as Integer
    order = appSourceOrder()
    for i = 0 to order.Count() - 1
        if order[i] = LCase(source) then return i
    end for
    return order.Count()
end function

function sourceDescription(source as String) as String
    v = appSourceDescriptions()[LCase(source)]
    if v = invalid then return ""
    return v
end function

' Viewer totals by match id, from /api/matches/live/popular-viewcount.
function viewerCounts(json as Dynamic) as Object
    counts = {}
    if type(json) <> "roArray" then return counts
    for each c in json
        if c.id <> invalid and c.viewers <> invalid then counts[c.id] = c.viewers
    end for
    return counts
end function

' Attach viewer counts, then float counted matches to the top, most-watched
' first; the rest keep the API's order.
function withViewers(matches as Dynamic, counts as Object) as Object
    counted = []
    rest = []
    if type(matches) <> "roArray" then return []
    for each mt in matches
        if counts.DoesExist(mt.id) then
            mt.viewers = counts[mt.id]
            counted.Push(mt)
        else
            rest.Push(mt)
        end if
    end for
    counted.SortBy("viewers", "r")
    counted.Append(rest)
    return counted
end function

' ---- settings -----------------------------------------------------------------

' The WebDriver server (Selenium standalone Chrome), e.g. "http://192.168.1.20:4444".
function getDriver() as String
    s = CreateObject("roRegistrySection", "settings")
    if s.Exists("driver") then return s.Read("driver")
    return ""
end function

sub setDriver(url as String)
    s = CreateObject("roRegistrySection", "settings")
    s.Write("driver", url)
    s.Flush()
end sub

' This build's version, e.g. "1.0.80" (the release workflow stamps the
' manifest); "" for a local build, whose manifest says 0.x.
function appVersion() as String
    v = CreateObject("roAppInfo").GetVersion()
    if Left(v, 2) = "0." then return ""
    return v
end function

' Whether version a (e.g. "1.0.81") is newer than b, comparing the numbers.
function isNewerVersion(a as String, b as String) as Boolean
    x = a.Split(".")
    y = b.Split(".")
    n = x.Count()
    if y.Count() < n then n = y.Count()
    for i = 0 to n - 1
        if x[i].ToInt() <> y[i].ToInt() then return x[i].ToInt() > y[i].ToInt()
    end for
    return x.Count() > y.Count()
end function
