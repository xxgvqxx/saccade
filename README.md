# Saccade

Gaze-based window focus for macOS. Look at a window, tap **Right Option**, and
keyboard focus jumps there — no mouse. Named after the rapid eye movement
between fixation points.

Everything runs locally. Camera frames are processed in memory with Apple's
Vision framework and never stored or transmitted.

## How it works

1. The webcam feed goes through Vision face-landmark detection (~30 fps).
2. Pupil position within each eye + head pose (yaw/pitch/roll) + face position
   become a feature vector.
3. A ridge regression fitted during calibration maps features → screen point.
4. The window under your (smoothed) gaze gets a teal border highlight.
5. Tap **Right Option**: the window is raised, the cursor warps to your gaze
   point, and — in Ghostty only — one click is synthesized so the correct
   *split* gets focus. Other apps get focus + cursor, never a click.

## Build and run

```sh
./scripts/make-app.sh
open build/Saccade.app
```

Grant when prompted (System Settings → Privacy & Security):

- **Camera** — for gaze estimation.
- **Accessibility** — for raising windows and the Right Option hotkey.
  After granting Accessibility, quit and relaunch Saccade.

`make-app.sh` signs with a local "Saccade Dev" certificate when one exists in
the keychain (falling back to ad-hoc), so TCC grants survive rebuilds. If the
Accessibility toggle looks on but does nothing, the grant is keyed to an older
signature: run `tccutil reset Accessibility dev.alexhanvey.saccade`, relaunch,
and grant again.

## First use

1. Menu bar → eye icon → **Camera** → pick your webcam if it was not
   auto-picked (external cameras are preferred by default).
2. **Calibrate Screen** → pick a display — follow the dot through both phases.
   Esc cancels.
3. The alert reports fit error in pixels. Under ~250 px RMS feels reliable for
   window-sized targets on an ultrawide. If it is much worse, recalibrate with
   more even lighting and the camera centered above the screen.
4. Look around; the teal border shows the current target. Tap Right Option to
   jump. The orange dot (toggle in menu) shows the raw gaze estimate — useful
   to judge accuracy.

## Scope and behavior

- **Multi-screen**: calibrate each display separately via menu →
  **Calibrate Screen**. At runtime every calibrated screen's model predicts,
  and the screen whose prediction lands inside its own bounds owns the gaze —
  head pose differences between monitors make this detection reliable. Screen
  switches confirm over a few frames to avoid flapping. Looking at an
  uncalibrated screen drops the gaze instead of pinning it to an edge.
- Calibration is two-phase per screen: eyes-only dots, then head-pointing dots
  (Space starts each phase). Portrait monitors get a transposed grid.
- **Refine with Cursor** (menu): after grid-calibrating, turn this on and work
  normally while keeping your eyes on the pointer whenever it moves. Frames
  where you are plausibly fixating your own cursor (it moved recently, at a
  followable speed — flicks and warps are rejected) become extra training
  samples, and the model refits live every ~200 samples. Grid samples count
  double in the refit so cursor data densifies the map between dots without
  dragging the anchors. Stop via the same menu item to get a before/after fit
  report; refined models persist. Screens calibrated before grid samples were
  saved must be recalibrated once before they can be refined.
- **Add Posture Pass** (menu): the model learns your head *position* during
  calibration, so moving your chair, leaning back, or raising a standing desk
  shifts predictions. Instead of recalibrating, get into the new position and
  run a quick 12-dot eyes-only pass — its samples join the originals and one
  model is refitted across all postures, interpolating between them via the
  head-position features. Add a pass per posture you actually use (your face
  must still be well in the camera frame). The reported fit error then spans
  every posture, so it reads a little higher than a single-posture score. A
  full recalibration starts over and discards passes.
- Calibrations persist in `~/Library/Application Support/Saccade/calibrations.json`
  and reload on launch. Recalibrate a screen fully whenever you move the
  camera or lighting changes significantly — posture passes cover *you*
  moving, not the camera.
- **Winks** (menu): wink an eye to trigger an action — either eye can select
  the gazed window (so a wink can fully replace the Right Option key; there's
  a toggle to turn the key off) or pause/resume tracking. Off until you run
  the guided **Calibrate Winks** flow, which learns your open/closed eye
  shape, watches real blinks, then watches three winks per eye — from that it
  knows which landmark region is *your* left eye (immune to camera mirroring)
  and how much your other eye droops when you wink. Detection then requires
  one eye held closed ~0.2 s while the other stays clearly open the whole
  time, so blinks — both eyes dropping together, and over faster than the
  hold — can't fire it. If your winks are too blink-like, calibration says so
  instead of saving garbage. Selection uses your gaze from just before the
  eyelid started moving, because a closing lid corrupts the landmarks.
- **Smoothing** (menu): presets from Responsive to Very Steady. Under the
  hood: median-of-5 pre-filter → One Euro filter (normalized coordinates) →
  a fixation stabilizer that pins the dot while predictions stay within a
  small radius, so fixations are rock-steady but real gaze shifts stay
  instant.
- The jump clicks only after verifying (up to ~0.5 s) that the target window
  really is frontmost under the click point — never into the wrong window.
- **Turn Camera Off** (menu) stops capture and the webcam LED without
  quitting; the menu-bar eye stays so you can turn it back on.
- Live diagnostics in `~/Library/Application Support/Saccade/state.json`
  (refreshed every 2 s): permission status, camera, face detection, gaze
  screen, current target, and the outcome of recent jumps.
- Blinks are rejected; losing the face for >0.6 s clears the highlight.
- If you sit noticeably differently (lean back, slouch), accuracy degrades —
  head position is part of the model, which also means small natural head turns
  toward a window *help* accuracy on an ultrawide.

## Config

`~/Library/Application Support/Saccade/config.json`:

- `cameraName` — substring match for the preferred camera ("NexiGo").
- `clickBundleIDs` — apps that get the synthesized click on jump (default
  Ghostty). Add e.g. tmux-in-iTerm style apps here if wanted.
- `calibrationColumns` / `calibrationRows` — default 5×3 (dense horizontally
  for ultrawide).
- `smoothing` — One Euro filter parameters. Raise `minCutoff` for less lag,
  lower it for less jitter.
- `targetSwitchFrames` — frames a new window must be gazed at before the
  highlight switches (default 3).
- `winksEnabled` / `winkLeftAction` / `winkRightAction` / `optionKeySelects` /
  `winkCalibration` — wink control state; manage these from the Winks menu
  rather than by hand.

## Known limits (v1)

- Vision's pupil landmarks are coarse; expect window-level accuracy, not
  text-level. If accuracy disappoints, the planned v2 upgrade is MediaPipe
  Iris-quality landmarks or a small ONNX gaze model.
- Windows on other Spaces: the jump raises the window only if it is on the
  current Space.
- A click in Ghostty can interact with terminal apps that enable mouse
  reporting (e.g. repositioning in some TUIs). Harmless for Claude Code
  prompts, but worth knowing.
