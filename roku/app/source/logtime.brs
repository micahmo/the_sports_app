' The time of day for the debug console's lines ("20:09:59.183 "), so a slow
' start shows which step took the time.
function logTime() as String
    d = CreateObject("roDateTime")
    d.ToLocalTime()
    return Right("0" + d.GetHours().ToStr(), 2) + ":" + Right("0" + d.GetMinutes().ToStr(), 2) + ":" + Right("0" + d.GetSeconds().ToStr(), 2) + "." + Right("00" + d.GetMilliseconds().ToStr(), 3) + " "
end function
