# HeadMouse for AirPods

**A hands-free mouse for the Mac that runs on the AirPods you already own.**
Turn and nod your head to move the pointer. Tilt your head to scroll. Hold
still to click. No camera, no extra hardware, no cost.

> Early prototype. It works day to day for its author, but it has not yet been
> tested with disabled users. Feedback from people who rely on assistive
> technology is the most valuable contribution this project can get.

*Not affiliated with Origin Instruments' HeadMouse® products.*

---

## Why this matters as assistive technology

Many people can't use a mouse or trackpad comfortably, or at all. Spinal cord
injury, ALS, muscular dystrophy, multiple sclerosis, cerebral palsy, arthritis,
repetitive strain injury, limb difference, a broken wrist: the reasons vary,
and so does how long they last. For many of them, head movement is the most
reliable movement they have.

Head pointing is a proven idea. The tools for it usually have a catch:

| Approach | The catch |
|---|---|
| Dedicated head-tracking mice | Specialist hardware, often hundreds of dollars, a reflective dot on your forehead |
| Camera-based head pointers (including the one built into macOS) | Need good lighting, a clear view of your face, and a camera that's always watching |
| Eye trackers | Expensive, need calibration, tiring for long sessions |
| Mouth sticks, sip-and-puff | Physically demanding, highly visible |

AirPods change the economics. They hold a gyroscope and an accelerometer
that Apple already uses for spatial audio, and an app can read them.
That makes HeadMouse:

- **Free to try.** No purchase, no prescription, no waiting for a device.
  Lots of people already own compatible earbuds.
- **Private.** No camera, no video, nothing about your face is ever captured.
- **Robust.** It works in the dark, in bright sun, from a bed or a wheelchair,
  in any posture, whether or not your face is in frame.
- **Discreet.** Earbuds are ordinary. Nobody looks twice.
- **Portable.** It's tied to your head, not your desk. Move rooms, change seats,
  and it still works.

HeadMouse also helps people without a disability: anyone whose hands are busy,
injured, or tired.

## What it does

| Action | How |
|---|---|
| Move the pointer | Turn your head left and right, nod up and down |
| Scroll | Tilt an ear toward your shoulder. Tilt further to scroll faster. Straighten up to stop |
| Click | Hold the pointer still. A ring fills beside it, then it clicks once |
| Double-click, right-click, drag | Pick the next action from a small floating palette, by dwelling on it |
| Pause | Dwell on the pause button, so you can rest or read without clicking anything |

Dwell clicking is a standard technique in assistive technology. HeadMouse
clicks only once per stop, and only after you have moved the pointer with your
head, so resting on a page doesn't produce a stream of clicks.

### Built for precision

Small targets are the hardest part of head pointing. The close button on a
window is about 12 points across. HeadMouse attacks this from several sides:

- **Adaptive smoothing.** A One Euro filter smooths heavily when your head
  moves slowly, removing jitter, and barely at all when it moves fast, so big
  moves don't lag.
- **Pointer acceleration.** Slow, careful head movement is geared down to about
  15% of full speed for fine aiming. Quick sweeps get full speed to cross the
  screen.
- **Sticky buttons.** The pointer slows down while it's over a small button.
  This is a known idea from accessibility research, often called semantic
  pointing.
- **Click assist.** If a click lands just next to a small button, HeadMouse
  clicks the button.
- **Smooth output.** The sensors report about 50 times a second. HeadMouse
  glides the pointer at 120 frames a second in between, so it never jumps.
- **Relative pointing.** HeadMouse works like a mouse rather than a laser
  pointer, so sensor drift never accumulates, and there's nothing to recenter
  or calibrate.

## Quality

The pointer math and the gesture logic are covered by tests that run on
synthetic head motion, so anyone can reproduce them:

```bash
./test.sh
```

The logic tests check that slow posture changes and brief head flicks don't
scroll, that a held tilt scrolls and straightening up stops it, and that dwell
clicks once per stop and never without prior head movement.

The benchmark compares the current pointer pipeline with the first version of
the project:

| Scenario | First version | Now |
|---|---|---|
| Pointer wander while holding your head still for 5 s | 17 px | 0.3 px |
| Pointer travel for a slow 2° head turn | 47 px | 11 px |
| Overshoot after a fast sweep stops | 115 px | 20 px |
| Pointer travel for a fast 25° sweep | 957 px | 1,322 px |

Lower wander and lower overshoot mean steadier, more accurate aiming. Less
travel for a slow turn means finer control. Fast sweeps still cover the screen.
These numbers come from simulated sensor noise, not from human trials.

Other details that matter for reliability:

- Accessibility lookups use a 50 ms timeout, so a frozen app can never freeze
  the pointer.
- The pointer is clamped to your displays and picks up from wherever the
  trackpad leaves it.
- Removing an AirPod or a dropped connection cancels any drag in progress.
- Everything runs locally. No network access, no analytics.

## Getting started

You need a Mac with Apple silicon running macOS 14 or later, and AirPods with
spatial-audio head tracking: AirPods 4, AirPods Pro, AirPods (3rd generation),
AirPods Max, or a supported Beats model. You also need Xcode or the Command
Line Tools.

```bash
git clone https://github.com/sinem-unlu-sf/airpods-headmouse.git
cd airpods-headmouse
./build.sh
open build/HeadMouse.app
```

1. A face icon appears in the menu bar. If your Mac has a notch and a crowded
   menu bar, open HeadMouse.app again to get the menu at your pointer.
2. Allow **Motion** access when macOS asks.
3. Allow **Accessibility** access: System Settings → Privacy & Security →
   Accessibility → HeadMouse. If clicks stay blocked, choose
   **Fix Accessibility Permission…** from the HeadMouse menu.
4. Connect your AirPods to the Mac and choose **Head Control**.

### Settings

All in the menu bar menu: pointer speed, dwell time, scroll speed, scroll
direction, sticky buttons, click assist, and inverted axes. Settings are not
saved between launches yet.

## How it works

`CMHeadphoneMotionManager` streams the AirPods' fused motion data, from both
the gyroscope and the accelerometer.

| Signal | Use |
|---|---|
| Yaw (turning) | Horizontal pointer movement |
| Pitch (nodding) | Vertical pointer movement |
| Roll (tilting) | Scrolling, measured from your neutral posture, which slowly adapts |
| Rotation rate | Optional nod-to-click gesture |

Clicks, scrolls and pointer movement are posted as ordinary system mouse events
through Quartz, which is why the app needs Accessibility permission. Button
detection for sticky buttons and click assist uses the macOS Accessibility API.

| File | Role |
|---|---|
| `HeadTracker.swift` | Reads AirPods motion and turns it into per-frame changes |
| `MotionShaper.swift` | Filtering, pointer acceleration, tilt scrolling |
| `CursorController.swift` | 120 Hz pointer output, clicks, drags, scrolling |
| `DwellLogic.swift`, `DwellController.swift` | Dwell clicking, progress ring, action palette |
| `AX.swift` | Finds buttons under the pointer |
| `JawRecorder.swift` | Guided recording for jaw-gesture research |
| `AppDelegate.swift` | Menu bar app and wiring |

## Limitations

- **Head movement is required.** Turning, nodding and tilting all need some
  neck mobility. HeadMouse won't help people who have none.
- **Dwell can click by accident** when you stop to read. Use pause, or a longer
  dwell time.
- **Only one AirPod's sensor is read at a time.** macOS picks which.
- **No user testing yet.** The defaults are tuned by one person.
- **Unsigned build.** You build it yourself. There's no notarized download yet.

## Roadmap

- **Jaw-gesture clicking.** The AirPods sit right next to the jaw joint, so a
  teeth tap or clench may show up in the motion data. The built-in calibration
  recorder (**Record Jaw Calibration…**) collects data to find out. If it works,
  it would give a fast, deliberate, invisible click.
- Saved settings and a first-run walkthrough.
- Per-user calibration of speed and range for people with limited range of
  motion.
- A keyboard shortcut to pause or resume.
- Testing with assistive technology users and occupational therapists.

## Contributing

Issues and pull requests are welcome, especially from people who use assistive
technology or work with those who do. Tell us what's hard, what's tiring, and
what's missing.

For development, there are a few environment variables, passed with
`open --env NAME=1 build/HeadMouse.app`:

- `HEADMOUSE_DRYRUN` logs clicks and scrolls instead of performing them.
- `HEADMOUSE_AUTOSTART` turns on Head Control at launch.
- `HEADMOUSE_RECORD_JAW` starts the jaw calibration at launch.
- `HEADMOUSE_JAW_QUICK` makes the calibration ten times shorter, for smoke tests.

Launch through `open`, not by running the binary directly. Otherwise macOS
kills the process on its Motion privacy check. The log is at
`~/Library/Logs/HeadMouse.log`.

## License

MIT. See [LICENSE](LICENSE).
