# Drives and captures the Windows app for README screenshots, in the background:
# it never moves the real mouse or brings the window forward, so you can keep
# using the PC. See README.md in this folder for the whole process.
#
#   powershell -File docs/screenshots/wincap.ps1 size    -X 1296 -Y 719    # window size, incl. borders
#   powershell -File docs/screenshots/wincap.ps1 click   -X 200  -Y 96     # client coordinates
#   powershell -File docs/screenshots/wincap.ps1 hover   -X 640  -Y 660    # park the pointer somewhere empty
#   powershell -File docs/screenshots/wincap.ps1 capture -Out shot.png     # whole window, incl. title bar
#
# Run it with Windows PowerShell (powershell.exe), not pwsh: PowerShell 7 has no
# System.Drawing.
param([string]$Action, [string]$Out, [int]$X = 0, [int]$Y = 0)
Add-Type -ReferencedAssemblies System.Drawing @"
using System; using System.Drawing; using System.Runtime.InteropServices;
public class BG {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool r);
  [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string w);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public struct RECT { public int L, T, R, B; }
  public static void Capture(IntPtr h, string path) {
    RECT r; GetWindowRect(h, out r);
    using (var bmp = new Bitmap(r.R - r.L, r.B - r.T)) using (var g = Graphics.FromImage(bmp)) {
      // PW_RENDERFULLCONTENT (2): Flutter draws with the GPU; without it the capture is black.
      IntPtr dc = g.GetHdc(); PrintWindow(h, dc, 2); g.ReleaseHdc(dc); bmp.Save(path);
    }
  }
  static IntPtr View(IntPtr top) { return FindWindowEx(top, IntPtr.Zero, "FLUTTERVIEW", null); }
  static IntPtr At(int x, int y) { return (IntPtr)((y << 16) | (x & 0xFFFF)); }
  public static void Hover(IntPtr top, int x, int y) { PostMessage(View(top), 0x0200, IntPtr.Zero, At(x, y)); }
  public static void Click(IntPtr top, int x, int y) {
    IntPtr v = View(top), l = At(x, y);
    PostMessage(v, 0x0200, IntPtr.Zero, l); PostMessage(v, 0x0201, (IntPtr)1, l); PostMessage(v, 0x0202, IntPtr.Zero, l);
  }
}
"@
[BG]::SetProcessDPIAware() | Out-Null
# Found by class and title, not Get-Process's MainWindowHandle: a tooltip can
# become the process's "main window". The title matters too: every Flutter app
# on Windows uses this class.
$h = [BG]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, 'FLUTTER_RUNNER_WIN32_WINDOW', 'sports')
if ($h -eq [IntPtr]::Zero) { throw 'The Sports window is not open.' }
switch ($Action) {
  'size'    { [BG]::MoveWindow($h, 0, 0, $X, $Y, $true) | Out-Null; 'sized' }
  'click'   { [BG]::Click($h, $X, $Y); 'clicked' }
  'hover'   { [BG]::Hover($h, $X, $Y); 'hovered' }
  'capture' { [BG]::Capture($h, $Out); "saved $Out" }
  default   { throw "Unknown action '$Action' (size, click, hover, capture)." }
}
