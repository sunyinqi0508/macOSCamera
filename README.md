# Camera for macOS

An iPhone-style camera app for the Mac (package name `mbCamera`): photo and
video capture from any camera
(including iPhone Continuity Camera), screen recording with a picture-in-picture
camera overlay, tap-to-focus/exposure, on-screen quality controls, and quick access
to captured media.

## Build & run

```sh
swift build                        # debug build (works with Command Line Tools)
./scripts/package_macos_app.sh     # release "Camera for macOS.app" + zip in dist/
open "dist/Camera for macOS.app"
```

For App Store work use the Xcode project: open `CameraForMacOS.xcodeproj`
(regenerate anytime with `xcodegen generate` from `project.yml`) and archive the
`CameraForMacOS` scheme. Submission steps live in `COMPLIANCE.md`.

Run the packaged app (not the bare `swift run` binary) when testing camera,
microphone, screen-recording, or Photos-library permissions — macOS attributes
those permissions to the app bundle.

The packaging script signs with your first available codesigning identity
(override with `MBCAMERA_SIGN_IDENTITY="…"`). A stable identity matters:
ad-hoc signatures change on every build, which makes macOS forget permission
grants — screen recording in particular would re-prompt after each rebuild.

## Tests

The test suite uses the toolchain-bundled Swift Testing module, which the plain
Command Line Tools toolchain does not ship. Run tests through the Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

(VS Code's Swift extension test runner works as-is.)

## Behavior notes

- **Quick controls** — the yellow on-screen values (source, format/quality or
  resolution/fps) work iPhone-style: click to cycle, scroll to step through values.
  Session-restarting changes apply after a short quiet period so cycling stays smooth.
- **Window** — drag anywhere on the preview to move the window; a plain click (no
  movement) sets focus/exposure at that point.
- **Mobile devices** — iPhone/iPad Continuity cameras and microphones are selectable
  sources but are never chosen automatically, so the app never wakes your phone.
- **Media location** — files go to `~/Photos` by default (configurable), or into the
  Photos library. Filenames are timestamped and never overwrite each other.
- **Photo format/quality** — HEIC/JPEG/PNG are encoded for real (a `.png` file is
  actual PNG data); quality maps to encoder compression and sensor-quality
  prioritization. HEIC falls back to JPEG (with a truthful `.jpg` extension) on
  machines without HEVC hardware.
- **Mode switching** — photo mode uses the sensor's native photo format; video mode
  applies the selected resolution/fps (clamped to what the device supports).
  Resolution/fps changes made while recording are applied when the recording stops.
- **Device hotplug** — cameras, microphones, and displays are re-discovered on
  connect/disconnect; if the active device disappears the app falls over to a
  surviving one, and an interrupted recording is finalized and kept.
- **Window** — the window tracks the real aspect ratio of the video feed. Title-bar
  hiding and drag-by-content live in Settings; with the title bar hidden an
  on-screen ✕ appears. Closing the window quits the app unless a recording is
  running (a recording keeps running headless; reopen from the Dock).
- **System audio** — macOS has no public API for recording another app's audio
  directly into an AVFoundation session. To mix system output into a recording,
  install a loopback driver (e.g. BlackHole), route output through it, and enable
  it as an input under Settings → Audio Muxing.
