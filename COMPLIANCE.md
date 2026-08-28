# App Store Compliance — Camera for macOS

Status: **code-side ready and sandbox-verified**; the remaining steps are Apple
Developer account actions listed below.

## Done in this repository

- **App Sandbox** enabled for App Store builds (`scripts/appstore.entitlements`):
  camera, microphone, Pictures read-write, user-selected files read-write,
  app-scoped bookmarks, Photos library.
  Verified locally: the sandboxed build launches, runs the capture session,
  keeps its settings in its container, and the default save location resolves
  through the container symlink to the real `~/Pictures/Camera`.
- **Security-scoped bookmarks** — a custom media folder chosen in Settings
  keeps working across launches under the sandbox.
- **Info.plist** — usage descriptions for camera, microphone, screen capture,
  and Photos; `LSApplicationCategoryType = public.app-category.photography`;
  copyright; `ITSAppUsesNonExemptEncryption = false`; Continuity Camera opt-in;
  minimum macOS 13.0.
- **App icon** — original artwork (light tile, camera glyph, yellow lens),
  deliberately *not* a copy of Apple's Camera icon (guideline 4.1).
- **API usage** — public frameworks only (AVFoundation, SwiftUI/AppKit,
  CoreAudio, ImageIO, Photos). No networking, no analytics, no third-party SDKs.
- **Packaging** — `./scripts/package_macos_app.sh --appstore` produces a
  distribution-signed app + installer pkg via `productbuild`.

## Submitting (recommended: the Xcode project)

`CameraForMacOS.xcodeproj` (regenerable from `project.yml` via `xcodegen`) is
configured for submission: automatic signing with team `C7F9H59JYH`, the sandbox
entitlements, the asset-catalog app icon, and the full Info.plist.

1. Paid Apple Developer Program membership, signed into Xcode
   (Settings → Accounts).
2. In App Store Connect: create the app record for bundle id
   `com.yurika.mbCamera`, add screenshots and description, and fill the privacy
   label — accurate answer today is **"Data Not Collected"** (the app has no
   network code at all).
3. Open `CameraForMacOS.xcodeproj` → select the `CameraForMacOS` scheme →
   **Product ▸ Archive** → **Distribute App ▸ App Store Connect**. Xcode creates
   the distribution certificate and provisioning profile automatically.
4. For each release, bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
   (in `project.yml`, then `xcodegen generate` — or edit the build settings in
   Xcode directly).

The CLI alternative (`./scripts/package_macos_app.sh --appstore` + Transporter)
still works but requires creating the distribution certificates and profile by
hand.

## Review risks — honest assessment

- **App name.** "Camera for macOS" is a generic category name plus a platform
  name; App Review regularly pushes back on both (and "macOS" in a product name
  conflicts with Apple trademark guidance). Recommendation: pick a distinctive
  product name and use "Camera for your Mac" as the subtitle instead. The
  in-bundle display name is easy to change in `scripts/package_macos_app.sh`.
- **Icon similarity (4.1).** The icon is original artwork in the system-camera
  visual genre. If review objects, shift the palette/background further from
  Apple's.
- **Deprecated APIs.** `AVCaptureScreenInput` and `CGDisplayCreateImage` are
  deprecated but public and currently accepted. A ScreenCaptureKit migration is
  the long-term path (it would also unlock true system-audio capture).
- **Screen recording UX.** The system permission for screen sources requires an
  app relaunch after granting; mention it in the review notes so the reviewer
  isn't surprised.
- **System audio.** Direct system-audio capture needs a loopback driver; the
  Settings sheet says so. Disclose the same in review notes to avoid a
  "misleading feature" reading of the System Audio toggle.

## Disclosures for the review notes

- Screen-recording features require the Screen Recording permission.
- Mixing system output audio into recordings requires a third-party loopback
  audio driver (e.g. BlackHole); microphones work out of the box.
