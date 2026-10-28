' args: a deep link straight into a stream, from ECP (see MainScene's
' openStream): /launch/dev?match=<id>&sport=<sport id>&stream=<embed address>.
sub Main(args as Dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)
    scene = screen.CreateScene("MainScene")
    screen.Show()
    ' Set when the user confirms leaving from Home.
    scene.observeField("exitApp", port)
    ' The same link while it's running comes as input (ECP /input or /launch).
    input = CreateObject("roInput")
    input.SetMessagePort(port)
    if type(args) = "roAssociativeArray" and args.match <> invalid then scene.deepLink = args
    while true
        msg = wait(0, port)
        if type(msg) = "roInputEvent" and msg.IsInput() then
            info = msg.GetInfo()
            if info.match <> invalid then scene.deepLink = info
        end if
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
