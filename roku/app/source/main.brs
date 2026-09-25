sub Main()
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)
    scene = screen.CreateScene("MainScene")
    screen.Show()
    ' Set when the user confirms leaving from Home.
    scene.observeField("exitApp", port)
    while true
        msg = wait(0, port)
        closed = type(msg) = "roSGScreenEvent" and msg.IsScreenClosed()
        if type(msg) = "roSGNodeEvent" and msg.getField() = "exitApp" then closed = true
        if closed then
            ' Leaving with Back: close the stream's browser session if one is
            ' open. (Home kills the app outright; the next launch and the
            ' server's idle timeout cover that.)
            closeRememberedSession()
            return
        end if
    end while
end sub
