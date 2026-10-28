' The backend in use (see DESIGN_NOTES, Backends; appBackend() in
' generated/app_data.brs, from shared/app_data.json), for ApiTask: the address
' to fetch, and the adapter that turns its answer into the app's lists.

function backendRealUrl() as String
    return appBackend().api
end function

' Badge ids for a game's two teams, in the order its title names them, for a
' site without team badges whose posters show both logos in the same places
' (appBackend().logoCrops; badgeImage in common.brs cuts them out); "" without
' those. As Backend.posterLogos in the phone app.
function posterLogos(poster as Dynamic) as Object
    if poster = invalid or poster = "" or appBackend().logoCrops.Count() < 2 then return ["", ""]
    return ["logo0:" + poster, "logo1:" + poster]
end function

' kind: sports, live, all, popular, counts, sport (a: sport id), stream (a:
' source, b: match id). JSON text in the shapes the screens read.
function backendConvert(kind as String, a as String, b as String, text as String) as String
    name = appBackend().name
    if name = "ppv" then return ppvConvert(kind, a, b, text)
    return ""
end function
