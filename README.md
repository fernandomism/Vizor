# Vizor
Control your mouse with your eyes. Look to move the pointer, then click or right click without touching anything.

Vizor lives in the menu bar. It uses your Mac's camera, Apple's Vision framework to find your face and eyes, and Google's MediaPipe iris model (running on-device through Core ML) to find your pupils. No video leaves your Mac.

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
- **Calibration** runs the first time: a red dot appears in the center and then in each corner. Keep your head still and look at the dot until it moves. Recalibrate whenever you change your seat, screen or lighting.
- **Blink twice** quickly to left click. **Blink three times** to right click. Single blinks are ignored, so normal blinking doesn't click. The pointer holds still while you blink, so the click lands where you were looking.

## Settings
- **On/off shortcut**: click the button and press a new key combination. It must include ⌃, ⌥ or ⌘.
- **Pointer smoothing**: higher is steadier, lower reacts faster.
- **Blink sensitivity**: raise it if blinks aren't detected, lower it if looking down causes clicks.
- **Time between blinks**: how long Vizor waits for the next blink before deciding it was a double or triple blink.

## Good to know
- Webcam eye tracking puts the pointer in the right area, not on an exact pixel. Good, even light on your face helps the most.
- Only the main display is supported.
- Each rebuild gets a new ad-hoc signature, so macOS may forget the Accessibility permission. If the pointer stops moving after a rebuild, remove Vizor from System Settings → Privacy & Security → Accessibility and add it again.

## Self-test
Checks the calibration math and blink counting:

```bash
swiftc Sources/Gaze.swift Tests/main.swift -o /tmp/vizor-selftest && /tmp/vizor-selftest
```

## Credits
The iris model is Google's [MediaPipe](https://github.com/google-ai-edge/mediapipe) iris landmark model, Apache License 2.0 (see `Models/NOTICE` and `Models/LICENSE-mediapipe.txt`). `tools/convert_iris.py` rebuilds `Models/IrisLandmark.mlpackage` from Google's original file and checks the result against Google's runtime.
