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
- **Right-click the icon** (or control-click) for **Calibrate…**, **Train (100 dots)…**, **Settings…** and **Quit**.
- The first time you turn it on, macOS asks for **Camera** and **Accessibility** access. Accessibility is what lets Vizor move the pointer and click. After allowing Accessibility in System Settings, click the icon again.
- **Calibration** runs the first time: 12 red dots appear one at a time around the screen. Look at each dot and **tap Space**. The dot turns green ("Saved") and the next one appears. 4 more dots then check the accuracy and show it in points (lower is better). Recalibrate whenever you change your seat, screen or lighting.
- **Training** is the long calibration: 96 dots plus the 4 accuracy checks, about 3 minutes. Move your head a little now and then so it learns how that shifts things. If you stop partway with Esc, the dots you've done are kept.
- **It learns as you use it.** Every real mouse or trackpad click teaches Vizor where you were looking. So does correcting it: if the pointer lands in the wrong spot, move it by hand to where you're looking and let go. It also learns how moving your head shifts things. Settings shows how accurate it's been at your recent clicks.
- **The pointer stays put** until your eyes really move. Small eye flicks and camera noise are ignored. If you move the pointer with your mouse or trackpad, it stays where you put it until you look somewhere else.
- **Esc always stops Vizor**, from any app: the pointer, the camera and any calibration in progress.
- **Blink twice** quickly to left click. **Blink three times** to right click. Single blinks are ignored, so normal blinking doesn't click. The pointer holds still while you blink, so the click lands where you were looking.

## Settings
- **On/off shortcut**: click the button and press a new key combination. It must include ⌃, ⌥ or ⌘.
- **Pointer smoothing**: higher is steadier, lower reacts faster.
- **Hold still within**: how far your eyes must move (in points) before the pointer follows. Raise it if the pointer still wanders, lower it if small moves are ignored.
- **Blink sensitivity**: raise it if blinks aren't detected, lower it if looking down causes clicks.
- **Time between blinks**: how long Vizor waits for the next blink before deciding it was a double or triple blink.
- **Zoom to click (experimental, macOS 14+)**: blinking twice magnifies the area you're looking at instead of clicking. Look at the target in the magnified view and blink twice again to click it (three times to right-click). Small buttons become big targets, which makes up for webcam inaccuracy. It needs the Screen Recording permission to take the picture it magnifies; **Zoom level** sets how much.

## Good to know
- Webcam eye tracking puts the pointer in the right area, not on an exact pixel. Good, even light on your face and sitting a little closer help the most. Vizor uses your camera at 1080p when it can and turns off Center Stage while it runs.
- Only the main display is supported.
- Updating from an earlier version asks you to calibrate again. Recalibrating also clears what it learned from your clicks.
- Without a signing certificate (below), each build gets a new stand-in signature and macOS forgets the Accessibility permission. If it asks again even though Vizor is switched on in the list, select Vizor in System Settings → Privacy & Security → Accessibility, click −, then turn Vizor on and allow it again.

## Keep permissions across updates
macOS remembers the Accessibility permission for one exact app signature. Set up a free signing certificate once and every GitHub build is signed the same way, so updates keep the permission:

1. Open **Keychain Access** (search for it with Spotlight). In the menu bar choose **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name it **Vizor Signing**, set Identity Type to **Self-Signed Root** and Certificate Type to **Code Signing**, then click **Create**.
3. In the **login** keychain, open **My Certificates**, right-click **Vizor Signing** → **Export "Vizor Signing"…**, choose **Personal Information Exchange (.p12)**, save it to the Desktop as `VizorSigning.p12`, and set a password.
4. Copy the file as text:

   ```bash
   base64 -i ~/Desktop/VizorSigning.p12 | pbcopy
   ```

5. On GitHub, open the repo's **Settings → Secrets and variables → Actions** and add two repository secrets: `SIGNING_CERT_P12` (paste) and `SIGNING_CERT_PASSWORD` (the password).
6. Delete `VizorSigning.p12` from the Desktop.
7. Open the latest **Build** run under the repo's **Actions** tab and click **Re-run all jobs**. Install that build and allow Accessibility one last time, after removing the old Vizor entry with −.

To sign local builds the same way: `SIGN_IDENTITY="Vizor Signing" ./build.sh`. The "can't verify" warning still appears once per download; only a paid Apple Developer ID removes it. Anyone who can edit this repo's workflows could use the certificate, so keep the repo's write access to people you trust.

## Self-test
Checks the gaze model (calibration, learning from clicks, head movement, ignoring stray clicks), blink counting, how the pointer holds still and the zoom-to-click math:

```bash
swiftc Sources/Gaze.swift Tests/main.swift -o /tmp/vizor-selftest && /tmp/vizor-selftest
```

## Credits
Learning from clicks follows the approach of WebGazer ("WebGazer: Scalable Webcam Eye Tracking Using User Interactions", IJCAI 2016).

The iris model is Google's [MediaPipe](https://github.com/google-ai-edge/mediapipe) iris landmark model, Apache License 2.0 (see `Models/NOTICE` and `Models/LICENSE-mediapipe.txt`). `tools/convert_iris.py` rebuilds `Models/IrisLandmark.mlpackage` from Google's original file and checks the result against Google's runtime.
