' What an MPEG-TS segment's H.264 video is: width and height from its sequence
' parameter set (SPS), and the frame rate, from the SPS if it states one or
' else from the first frames' timestamps. Zeros for anything not found. The
' Roku's Video node reports segment sizes but not resolution or frame rate, so
' the stream proxy reads them itself.
'
' This runs on the proxy's thread, which serves the player, so it stops as soon
' as it has its answers: the SPS and a few frames sit in the first few dozen
' packets. (Walking a whole 6 MB segment took long enough that the player ran
' dry.)
function tsVideoInfo(ba as Object) as Object
    info = {width: 0, height: 0, fps: 0}
    n = ba.Count()
    vpid = -1
    buf = CreateObject("roByteArray")
    collecting = false
    stamps = []
    i = 0
    while i + 188 <= n and i < 188 * 3000
        if ba[i] = &h47 then
            pusi = (ba[i + 1] and &h40) <> 0
            pid = (ba[i + 1] and &h1F) * 256 + ba[i + 2]
            p = i + 4
            if (ba[i + 3] and &h20) <> 0 then p = p + 1 + ba[i + 4]
            if pusi and p + 18 < i + 188 then
                ' The first PES with a video stream id (0xE0-0xEF) names the video PID.
                if vpid < 0 and ba[p] = 0 and ba[p + 1] = 0 and ba[p + 2] = 1 and ba[p + 3] >= &hE0 and ba[p + 3] <= &hEF then vpid = pid
                if pid = vpid then
                    ' Decode timestamps (or presentation ones when there are no
                    ' B-frames) step by one frame each, in 90 kHz ticks.
                    flags = Int(ba[p + 7] / 64)
                    at = p + 9
                    if flags = 3 then at = p + 14
                    if flags >= 2 and stamps.Count() < 6 then stamps.Push(timestamp(ba, at))
                    if buf.Count() = 0 then
                        collecting = true
                        p = p + 9 + ba[p + 8]   ' past the PES header
                    end if
                end if
            end if
            ' The start of the first video PES, which carries the SPS.
            if collecting and pid = vpid then
                for j = p to i + 187
                    buf.Push(ba[j])
                end for
                if buf.Count() >= 2048 then collecting = false
            end if
            if not collecting and buf.Count() > 0 and stamps.Count() >= 6 then exit while
        end if
        i = i + 188
    end while

    ' Frame rate from the smallest step between timestamps (one frame).
    stepMin = 0
    for k = 1 to stamps.Count() - 1
        d = stamps[k] - stamps[k - 1]
        if d > 0 and (stepMin = 0 or d < stepMin) then stepMin = d
    end for
    if stepMin > 0 then info.fps = 90000 / stepMin

    ' SPS: a NAL unit of type 7 after a 00 00 01 start code.
    cnt = buf.Count()
    for k = 0 to cnt - 5
        if buf[k] = 0 and buf[k + 1] = 0 and buf[k + 2] = 1 and (buf[k + 3] and &h1F) = 7 then
            rbsp = []
            zeros = 0
            last = k + 200
            if last > cnt - 1 then last = cnt - 1
            for j = k + 4 to last
                b = buf[j]
                ' 00 00 03 is an escape: drop the 03.
                if not (zeros >= 2 and b = 3) then
                    rbsp.Push(b)
                    if b = 0 then zeros = zeros + 1 else zeros = 0
                else
                    zeros = 0
                end if
            end for
            sps = spsInfo(rbsp)
            info.width = sps.width
            info.height = sps.height
            if sps.fps > 0 then info.fps = sps.fps
            exit for
        end if
    end for
    return info
end function

' A 33-bit PES timestamp at ba[at], in 90 kHz ticks.
function timestamp(ba as Object, at as Integer) as Double
    t = Int((ba[at] and &h0E) / 2) * 1073741824#
    t = t + ba[at + 1] * 4194304# + Int(ba[at + 2] / 2) * 32768# + ba[at + 3] * 128# + Int(ba[at + 4] / 2)
    return t
end function

' The fields of an H.264 SPS (ITU-T H.264 7.3.2.1.1) up to the VUI timing info.
function spsInfo(d as Object) as Object
    r = {d: d, pos: 0, pow: [1, 2, 4, 8, 16, 32, 64, 128]}
    profile = bitsU(r, 8)
    bitsU(r, 16)                                ' constraint flags, level
    ue(r)                                       ' seq_parameter_set_id
    chroma = 1
    if profile = 100 or profile = 110 or profile = 122 or profile = 244 or profile = 44 or profile = 83 or profile = 86 or profile = 118 or profile = 128 or profile = 138 or profile = 139 or profile = 134 or profile = 135 then
        chroma = ue(r)
        if chroma = 3 then bitsU(r, 1)          ' separate_colour_plane_flag
        ue(r)                                   ' bit_depth_luma_minus8
        ue(r)                                   ' bit_depth_chroma_minus8
        bitsU(r, 1)                             ' qpprime_y_zero_transform_bypass_flag
        if bitsU(r, 1) = 1 then                 ' seq_scaling_matrix_present_flag
            lists = 8
            if chroma = 3 then lists = 12
            for li = 0 to lists - 1
                if bitsU(r, 1) = 1 then
                    size = 16
                    if li >= 6 then size = 64
                    lastScale = 8
                    nextScale = 8
                    for jj = 1 to size
                        if nextScale <> 0 then nextScale = (lastScale + se(r) + 256) mod 256
                        if nextScale <> 0 then lastScale = nextScale
                    end for
                end if
            end for
        end if
    end if
    ue(r)                                       ' log2_max_frame_num_minus4
    poc = ue(r)
    if poc = 0 then
        ue(r)                                   ' log2_max_pic_order_cnt_lsb_minus4
    else if poc = 1 then
        bitsU(r, 1)
        se(r)
        se(r)
        cycle = ue(r)
        for k = 1 to cycle
            se(r)
        end for
    end if
    ue(r)                                       ' max_num_ref_frames
    bitsU(r, 1)                                 ' gaps_in_frame_num_value_allowed_flag
    widthMbs = ue(r) + 1
    heightMapUnits = ue(r) + 1
    frameMbsOnly = bitsU(r, 1)
    if frameMbsOnly = 0 then bitsU(r, 1)        ' mb_adaptive_frame_field_flag
    bitsU(r, 1)                                 ' direct_8x8_inference_flag
    cropL = 0
    cropR = 0
    cropT = 0
    cropB = 0
    if bitsU(r, 1) = 1 then
        cropL = ue(r)
        cropR = ue(r)
        cropT = ue(r)
        cropB = ue(r)
    end if
    cropX = 2
    cropY = 2
    if chroma = 0 or chroma = 3 then cropX = 1
    if chroma <> 1 then cropY = 1
    cropY = cropY * (2 - frameMbsOnly)
    width = widthMbs * 16 - (cropL + cropR) * cropX
    height = (2 - frameMbsOnly) * heightMapUnits * 16 - (cropT + cropB) * cropY

    fps = 0
    if bitsU(r, 1) = 1 then                     ' vui_parameters_present_flag
        if bitsU(r, 1) = 1 then                 ' aspect_ratio_info_present_flag
            if bitsU(r, 8) = 255 then bitsU(r, 32)
        end if
        if bitsU(r, 1) = 1 then bitsU(r, 1)     ' overscan
        if bitsU(r, 1) = 1 then                 ' video_signal_type_present_flag
            bitsU(r, 4)
            if bitsU(r, 1) = 1 then bitsU(r, 24)
        end if
        if bitsU(r, 1) = 1 then                 ' chroma_loc_info_present_flag
            ue(r)
            ue(r)
        end if
        if bitsU(r, 1) = 1 then                 ' timing_info_present_flag
            units = bitsU(r, 32)
            scale = bitsU(r, 32)
            ' Two ticks per frame for progressive video.
            if units > 0 then fps = scale / (2 * units)
        end if
    end if
    return {width: Int(width), height: Int(height), fps: fps}
end function

' n bits, most significant first (as a Double, so 32 bits fit).
function bitsU(r as Object, n as Integer) as Double
    v = 0#
    for k = 1 to n
        idx = r.pos \ 8
        if idx >= r.d.Count() then return v
        bit = Int(r.d[idx] / r.pow[7 - (r.pos mod 8)]) mod 2
        v = v * 2 + bit
        r.pos = r.pos + 1
    end for
    return v
end function

' Exp-Golomb, unsigned and signed.
function ue(r as Object) as Double
    zeros = 0
    while bitsU(r, 1) = 0 and zeros < 31
        zeros = zeros + 1
    end while
    p = 1#
    for k = 1 to zeros
        p = p * 2
    end for
    return p - 1 + bitsU(r, zeros)
end function

function se(r as Object) as Double
    k = ue(r)
    if Int(k) mod 2 = 1 then return (k + 1) / 2
    return -k / 2
end function
