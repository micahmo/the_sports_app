' ppv.st (see DESIGN_NOTES, Backends), as the phone and desktop apps'
' lib/src/api/ppv_backend.dart. One request lists every event by category;
' ApiTask fetches it once and asks this for each list a screen wants, in the
' shapes the screens read (the app's models).

' The site's answer as one of the app's lists, as JSON text ("" if the answer
' isn't what's expected). kind: sports, live, all, popular, counts, sport (a:
' our sport id), stream (b: the match id).
function ppvConvert(kind as String, a as String, b as String, text as String) as String
    d = ParseJson(text)
    if type(d) <> "roAssociativeArray" or type(d.streams) <> "roArray" then return ""
    now = d.timestamp
    if now = invalid then now = CreateObject("roDateTime").AsSeconds()
    sportIds = appBackend().sportIds
    sports = []
    seen = {}
    matches = []
    for each cat in d.streams
        catName = cat.category
        sportId = sportIds[catName]
        if sportId = invalid then sportId = ppvSlug(catName)
        if cat.streams <> invalid and cat.streams.Count() > 0 and not seen.DoesExist(sportId) then
            seen[sportId] = true
            sports.Push({id: sportId, name: catName})
        end if
        if cat.streams <> invalid then
            for each ev in cat.streams
                always = ev.always_live <> invalid and ev.always_live <> 0
                starts = ev.starts_at
                if starts = invalid then starts = 0
                ends = ev.ends_at
                if ends = invalid then ends = 0
                id = ev.id.ToStr()
                live = always or (starts <= now and (ends = 0 or now < ends))
                ' The site counts people waiting for a game too, before it starts.
                viewers = invalid
                if type(ev.viewers) = "roString" or type(ev.viewers) = "String" then viewers = Int(Val(ev.viewers))
                if type(ev.viewers) = "roInt" or type(ev.viewers) = "Integer" then viewers = ev.viewers
                ' 0: a 24/7 channel, as the app has always read it.
                date = 0&
                if not always then date = starts * 1000&
                mt = {id: id, title: ev.name.Trim(), category: sportId, date: date, poster: ev.poster, backdrop: ppvBackdrop(ev.poster), teams: ppvTeams(ev.name.Trim(), ev.poster), sources: [{source: "ppv", id: id}], viewers: viewers}
                mt.live = live
                if kind = "stream" and id = b then return FormatJson(ppvStreams(ev, viewers))
                matches.Push(mt)
            end for
        end if
    end for
    if kind = "stream" then return "[]"
    if kind = "sports" then return FormatJson(sports)
    out = []
    for each mt in matches
        ok = true
        if kind = "live" or kind = "popular" or kind = "counts" then ok = mt.live
        if kind = "sport" then ok = mt.category = a
        if (kind = "popular" or kind = "counts") and mt.viewers = invalid then ok = false
        if kind = "popular" and mt.viewers <> invalid and mt.viewers = 0 then ok = false
        if ok then
            mt.Delete("live")
            out.Push(mt)
        end if
    end for
    if kind = "popular" or kind = "counts" then out.SortBy("viewers", "r")
    return FormatJson(out)
end function

' An event's streams: its own feed, then its other feeds (other broadcasters,
' languages), each named by broadcaster.
function ppvStreams(ev as Object, viewers as Dynamic) as Object
    list = []
    feeds = [ev]
    if type(ev.substreams) = "roArray" then feeds.Append(ev.substreams)
    for i = 0 to feeds.Count() - 1
        f = feeds[i]
        source = ""
        if f.source_tag <> invalid then source = f.source_tag.Trim()
        if source = "" then source = "Stream"
        n = 1
        for each s in list
            if s.source = source then n = n + 1
        end for
        v = invalid
        if i = 0 then v = viewers
        list.Push({id: f.id.ToStr(), streamNo: n, language: ppvLanguage(f.locale), hd: true, embedUrl: f.iframe, source: source, viewers: v})
    end for
    return list
end function

' The two sides of "A vs B" (home first) or "A at B" (away first), for the
' cards' team lines, with their logos from the poster (the first-named team's
' on the left); invalid for anything else (channels, events).
function ppvTeams(title as String, poster as Dynamic) as Dynamic
    logos = posterLogos(poster)
    parts = title.Split(" at ")
    if parts.Count() = 2 then return {home: {name: parts[1].Trim(), badge: logos[1]}, away: {name: parts[0].Trim(), badge: logos[0]}}
    for each sep in [" vs. ", " vs ", " VS ", " v "]
        parts = title.Split(sep)
        if parts.Count() = 2 then return {home: {name: parts[0].Trim(), badge: logos[0]}, away: {name: parts[1].Trim(), badge: logos[1]}}
    end for
    return invalid
end function

' The poster's a 300x168 thumbnail; without "-thumbnail", the full picture
' (1280x720 mostly, 2026-10-28). invalid if it isn't one.
function ppvBackdrop(poster as Dynamic) as Dynamic
    if poster = invalid then return invalid
    i = Instr(1, poster, "-thumbnail.")
    if i = 0 then return invalid
    return Left(poster, i - 1) + Mid(poster, i + 10)
end function

' "en-gb" -> "English"; an unknown code as it is.
function ppvLanguage(locale as Dynamic) as String
    if locale = invalid or locale = "" then return ""
    names = {en: "English", es: "Spanish", fr: "French", de: "German", it: "Italian", pt: "Portuguese", nl: "Dutch", sv: "Swedish", ar: "Arabic"}
    code = LCase(locale.Split("-")[0])
    if names.DoesExist(code) then return names[code]
    return locale
end function

' A category name as an id: lowercase, dashes ("Table Tennis" -> table-tennis).
function ppvSlug(name as String) as String
    out = ""
    dash = false
    for each c in LCase(name).Split("")
        if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") then
            if dash and out <> "" then out = out + "-"
            out = out + c
            dash = false
        else
            dash = true
        end if
    end for
    return out
end function
