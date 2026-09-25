# README screenshots

The images in this folder are the ones the READMEs show. Retake them whenever
the UI changes noticeably, and on **every platform together**, so the READMEs
never show one app newer than another.

| File | Shows | Size |
|---|---|---|
| `android-home.png` | Home: shortcuts, Most watched, all sports | 540×1170 |
| `android-live.png` | Live: sport chips and the list of games | 540×1170 |
| `android-streams.png` | One game's streams (the most-watched game) | 540×1170 |
| `windows-home.png` | Home at 1280 px wide | 1280×630 |
| `windows-matches.png` | A sport's games beside the chosen game's streams | 1280×831 |
| `roku-home.png` | Home on the TV | 1200×675 |
| `roku-live.png` | Live: games beside the chosen game's streams | 1200×675 |

The main README uses the Android and Windows images; `roku/README.md` uses the
Roku ones.

## Before you start

- **Take them on an evening with a full slate** (weeknights about 7–10 pm
  Eastern). An afternoon slate looks empty and the viewer numbers are small.
- **Check the viewer counts are working.** If this prints `0`, streamed.pk's
  view counting is down: Home loses its Most watched row and every stream shows
  0 viewers. Wait for it to come back.

  ```bash
  curl -s https://streamed.pk/api/matches/live/popular-viewcount | python -c "import json,sys; print(len(json.load(sys.stdin)))"
  ```
- **A big game may not be on Live yet.** The site adds games to its live list
  late (on 2026-09-24 an NFL game with 17k viewers was missing well after
  kickoff), though Most watched already has it. To feature it, open its sport
  instead of Live, as `windows-matches.png` does.
- Debug builds are fine: the app turns off Flutter's DEBUG banner
  (`debugShowCheckedModeBanner: false` in `lib/main.dart`).

## Android

Use an emulator, not a phone: a clean status bar, and nothing personal on
screen. Any phone-sized AVD with a 1080×2340 screen keeps the images the same
size (these came from a Pixel 5 image, Android 13), halved to 540×1170.

The commands below use `emulator-5554`, which is adb's name for the first
emulator running; `adb devices` lists yours. Name it every time: with a phone
also plugged in, a bare `adb` or `flutter run` may pick the phone.

1. Start the app on the emulator:

   ```bash
   fvm flutter run -d emulator-5554 --flavor development
   ```
2. Put the status bar in demo mode: fixed clock, full signal and battery, no
   notification icons.

   ```bash
   adb -s emulator-5554 shell settings put global sysui_demo_allowed 1
   adb -s emulator-5554 shell am broadcast -a com.android.systemui.demo -e command enter
   adb -s emulator-5554 shell am broadcast -a com.android.systemui.demo -e command clock -e hhmm 2015
   adb -s emulator-5554 shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false
   adb -s emulator-5554 shell am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4 -e mobile show -e datatype none -e level 4
   adb -s emulator-5554 shell am broadcast -a com.android.systemui.demo -e command notifications -e visible false
   ```

   (`-e command exit` turns demo mode off again.)
3. Capture each screen. Taps are in screen pixels, so these coordinates only
   hold at 1080×2340 and the current layout. Check a capture to find the spots
   on another screen size or after a redesign.

   ```bash
   adb -s emulator-5554 exec-out screencap -p > home.png      # Home, scrolled to the top
   adb -s emulator-5554 shell input tap 198 330                # the Live now tile
   adb -s emulator-5554 exec-out screencap -p > live.png
   adb -s emulator-5554 shell input keyevent KEYCODE_BACK
   adb -s emulator-5554 shell input tap 540 690                # the first Most watched game
   adb -s emulator-5554 exec-out screencap -p > streams.png
   ```
4. Halve them (Pillow):

   ```bash
   python -c "from PIL import Image; import sys; [Image.open(f).convert('RGB').resize((540,1170), Image.LANCZOS).save(f'docs/screenshots/android-{f[:-4]}.png', optimize=True) for f in ('home.png','live.png','streams.png')]"
   ```

## Windows

[`wincap.ps1`](wincap.ps1) sizes, clicks and captures the app window **in the
background**: it posts messages to the window and uses `PrintWindow`, so it
never moves your mouse or brings the window forward, and you can keep using the
PC. Run it with `powershell.exe` (Windows PowerShell), not `pwsh`.

1. Start the app: `fvm flutter run -d windows`.

   Sizes and click positions below assume Windows display scaling at 100%; at
   another scale, the window and the positions scale with it. Click positions
   also move with the layout, so check a capture after a redesign.
2. Home: 1280 px wide shows the content at its capped width with some margin.
   Sizes include the window's invisible 8 px borders and the 31 px title bar.

   ```bash
   powershell -File docs/screenshots/wincap.ps1 size -X 1296 -Y 719
   powershell -File docs/screenshots/wincap.ps1 hover -X 640 -Y 660      # pointer off the tiles
   powershell -File docs/screenshots/wincap.ps1 capture -Out w_home.png
   ```
3. A sport beside its streams: taller, then open the sport. Click coordinates are
   the window's client area (below the title bar); these hit the Football tile
   at 1296 px. The first game is selected and its streams show on the right;
   click another game to feature that one instead.

   ```bash
   powershell -File docs/screenshots/wincap.ps1 size -X 1296 -Y 839
   powershell -File docs/screenshots/wincap.ps1 click -X 776 -Y 343      # Football
   powershell -File docs/screenshots/wincap.ps1 hover -X 1200 -Y 790     # pointer on empty space
   powershell -File docs/screenshots/wincap.ps1 capture -Out w_matches.png
   ```

   (The back arrow is at `click -X 28 -Y 28`; Live now is at `click -X 200 -Y 96`.)
4. Trim the borders (8 px left, right and bottom), and Home's empty space at the
   bottom:

   ```bash
   python -c "from PIL import Image; i=Image.open('w_home.png'); w,h=i.size; i.crop((8,0,w-8,630)).save('docs/screenshots/windows-home.png', optimize=True)"
   python -c "from PIL import Image; i=Image.open('w_matches.png'); w,h=i.size; i.crop((8,0,w-8,h-8)).save('docs/screenshots/windows-matches.png', optimize=True)"
   ```

Things that went wrong before, and why the script is the way it is:
- **Always park the pointer** (`hover`) somewhere empty before `capture`: a
  hovered button shows a tooltip, and a hovered row its highlight.
- The window is found by class *and* title. `Get-Process sports` →
  `MainWindowHandle` can return a tooltip window instead; the class alone
  matches any Flutter app you have open.
- PowerShell passes `$null` to a .NET string parameter as `""`, so a `$null`
  window title only matches untitled windows (`[NullString]::Value` passes a
  real null).
- `PrintWindow` is called with flag 2 (`PW_RENDERFULLCONTENT`), the flag for
  windows drawn by the GPU, as Flutter's are.

## Roku

`roku/tools/roku.ps1 screenshot out/file.jpg` saves the TV's screen at
1920×1080; scale it to 1200×675 for the README. It needs `ROKU_HOST` and
`ROKU_DEV_PASSWORD` set, like `npm run deploy` (see `roku/README.md`), and the
dev app running.

**Captures come out completely black once an event poster has been on screen**
(the round images for matches without two teams: racing, "NFL Network" and
the like), and stay black until the app is restarted. The TV itself shows
everything fine. It's the posters (lossy WebP; a build with them turned off
captured fine), not the round mask or their size, and the server only has
them as WebP. Opening the on-screen keyboard does the same. So:

1. **Restart the app before capturing** (ECP needs no login):

   ```bash
   curl -X POST http://$ROKU_HOST:8060/keypress/Home
   curl -X POST http://$ROKU_HOST:8060/launch/dev
   ```
2. **Capture screens whose rows are all two-team games.** Home usually is. Live
   usually is too, because the most-watched games sort to the top, and that's
   where the cursor starts.
3. **Check each capture isn't black**; the script's "Saved" only means a JPEG
   came back:

   ```bash
   python -c "from PIL import Image; print(max(Image.open('roku/out/shot.jpg').convert('L').getdata()))"   # 0 = black
   ```
4. If a screen you need has a poster on it, make a temporary build that leaves
   posters out: in `roku/app/components/widgets/TeamBadge.brs`, `update()`,
   change `if m.top.cover <> "" then` to `if false then`. Deploy, capture,
   then change it back and deploy again.

Move around with ECP keypresses (`Up`, `Down`, `Left`, `Right`, `Select`,
`Back`, `Home`), e.g. `curl -X POST http://$ROKU_HOST:8060/keypress/Select`.
From a fresh launch the cursor is on Live now, so `Select` opens Live.
