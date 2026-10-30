# Vizor
Control your mouse with your eyes. Look to move the pointer, then click or right click without touching anything.

Vizor lives in the menu bar. It uses your Mac's camera, Apple's Vision framework to find your face and eyes, and Google's MediaPipe iris model (running on-device through Core ML) to find your pupils. No video leaves your Mac.

## Download
GitHub builds Vizor on every push. Open the repo's **Actions** tab, click the latest **Build** run, and download **Vizor** under Artifacts. Unzip it (twice: GitHub wraps the zip in a zip) and move `Vizor.app` to Applications. It runs on Apple Silicon and Intel Macs with macOS 13 or later.

The app isn't signed with an Apple Developer ID, so the first time you open it macOS says it can't verify the app. Go to System Settings → Privacy & Security, scroll down, and click **Open Anyway**. Or run this once in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Vizor.app
```

## Build
Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

```bash
open build/Vizor.app
```

Move `build/Vizor.app` to Applications if you want to keep it.

## Use
- **Click the eye icon** in the menu bar (or press **⌃⌥E**) to turn tracking on or off. The icon shows an eye when on and a crossed-out eye when off.
- **Right-click the icon** (or control-click) for **Calibrate…**, **Settings…** and **Quit**.
- The first time you turn it on, macOS asks for **Camera** and **Accessibility** access. Accessibility is what lets Vizor move the pointer and click. After allowing Accessibility in System Settings, click the icon again.
- **Calibration** runs the first time: 12 red dots appear one at a time around the screen. Keep your head still, look at each dot and **tap Space**. The dot turns green ("Saved") and the next one appears. Recalibrate whenever you change your seat, screen or lighting.
- **The pointer stays put** until your eyes really move. Small eye flicks and camera noise are ignored. If you move the pointer with your mouse or trackpad, it stays where you put it until you look somewhere else.
- **Esc always stops Vizor**, from any app: the pointer, the camera and any calibration in progress.
- **Blink twice** quickly to left click. **Blink three times** to right click. Single blinks are ignored, so normal blinking doesn't click. The pointer holds still while you blink, so the click lands where you were looking.

## Settings
- **On/off shortcut**: click the button and press a new key combination. It must include ⌃, ⌥ or ⌘.
- **Pointer smoothing**: higher is steadier, lower reacts faster.
- **Hold still within**: how far your eyes must move (in points) before the pointer follows. Raise it if the pointer still wanders, lower it if small moves are ignored.
- **Blink sensitivity**: raise it if blinks aren't detected, lower it if looking down causes clicks.
- **Time between blinks**: how long Vizor waits for the next blink before deciding it was a double or triple blink.

## Good to know
- Webcam eye tracking puts the pointer in the right area, not on an exact pixel. Good, even light on your face helps the most.
- Only the main display is supported.
- Updating from the first version asks you to calibrate again, because calibration now saves more points.
- Each rebuild gets a new ad-hoc signature, so macOS may forget the Accessibility permission. If the pointer stops moving after a rebuild, remove Vizor from System Settings → Privacy & Security → Accessibility and add it again.

## Self-test
Checks the calibration math, blink counting and how the pointer holds still:

```bash
swiftc Sources/Gaze.swift Tests/main.swift -o /tmp/vizor-selftest && /tmp/vizor-selftest
```

## Credits
The iris model is Google's [MediaPipe](https://github.com/google-ai-edge/mediapipe) iris landmark model, Apache License 2.0 (see `Models/NOTICE` and `Models/LICENSE-mediapipe.txt`). `tools/convert_iris.py` rebuilds `Models/IrisLandmark.mlpackage` from Google's original file and checks the result against Google's runtime.
