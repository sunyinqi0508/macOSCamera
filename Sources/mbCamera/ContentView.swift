import AppKit
import CameraCore
import SwiftUI

/// Reports the `NSWindow` hosting this view hierarchy, so window operations always
/// target the right window (never a sheet or alert that happens to be frontmost).
private struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            onResolve(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            onResolve(nsView?.window)
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var hostWindow: NSWindow?
    @State private var shutterFlashOpacity: Double = 0
    @State private var thumbnailScale: CGFloat = 1.0
    @State private var animateAspectChanges = false
    @State private var pipDragOffset: CGSize = .zero
    @State private var isPiPHovered = false

    var body: some View {
        ZStack {
            // A camera surface is black regardless of the system theme.
            Color.black
                .ignoresSafeArea()

            previewArea
                .ignoresSafeArea()
        }
        .frame(minWidth: 980, minHeight: 540)
        .background(WindowAccessor { window in
            guard hostWindow !== window else {
                return
            }
            hostWindow = window
        })
        .sheet(isPresented: $viewModel.isSettingsPresented) {
            SettingsView(viewModel: viewModel)
        }
        .onChange(of: hostWindow) { _ in
            hostWindow?.backgroundColor = .black
            applyChromeAndAspectNow(animated: false, allowComfortableGrowth: true)
            animateAspectChanges = true
        }
        .onChange(of: previewAspectRatio) { ratio in
            applyWindowAspectRatio(ratio, animated: animateAspectChanges)
        }
        .onChange(of: viewModel.settings.windowOptions.hideTitleBar) { _ in
            applyChromeAndAspectNow(animated: false)
        }
        .onChange(of: viewModel.settings.windowOptions.allowBackgroundDrag) { _ in
            applyWindowChromeOptions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // SwiftUI occasionally reasserts its own window chrome; put ours back.
            guard let window = note.object as? NSWindow, window === hostWindow else {
                return
            }
            reassertChromeIfNeeded(window)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            // Catches frame changes we didn't make (state restoration, SwiftUI
            // clamps) and snaps them back to the video's ratio.
            guard let window = note.object as? NSWindow, window === hostWindow, !window.inLiveResize else {
                return
            }
            snapWindowToAspectIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { note in
            // User drags aren't reliably ratio-constrained by AppKit under SwiftUI
            // window scenes; snap once the drag ends.
            guard let window = note.object as? NSWindow, window === hostWindow else {
                return
            }
            snapWindowToAspectIfNeeded()
        }
        .onChange(of: viewModel.isCapturingPhoto) { capturing in
            if capturing {
                triggerShutterFlash()
            }
        }
        .onChange(of: viewModel.lastThumbnail) { _ in
            popThumbnail()
        }
        .alert("Capture Error", isPresented: errorBinding, presenting: viewModel.errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Preview

    private var previewArea: some View {
        GeometryReader { proxy in
            let fittedRect = PreviewLayout.aspectFitRect(
                containerSize: proxy.size,
                aspectRatio: previewAspectRatio
            )

            ZStack {
                CameraPreviewView(previewLayer: viewModel.previewLayer, onTap: { point, size in
                    Task { await viewModel.focus(at: point, in: size) }
                })
                    .overlay {
                        #if DEBUG
                        // Screenshot mode: covers the live feed with a demo scene.
                        if let backdrop = DebugDemoBackdrop.main {
                            Image(nsImage: backdrop)
                                .resizable()
                                .scaledToFill()
                                .allowsHitTesting(false)
                                .clipped()
                        }
                        #endif
                    }
                    .overlay(alignment: pipAlignment) {
                        if viewModel.settings.selectedInput?.type == .screen,
                           viewModel.settings.screenRecording.isPiPEnabled {
                            pipOverlay(previewSize: fittedRect.size)
                        }
                    }
                    .overlay {
                        // Drawn in the preview's own coordinate space so the reticle
                        // lands exactly under the tap even when letterboxed.
                        ZStack {
                            if let indicator = viewModel.focusIndicatorPoint {
                                FocusReticle(position: indicator)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeOut(duration: 0.25), value: viewModel.focusIndicatorPoint)
                    }
                    .overlay {
                        // Subtle scrims so the yellow controls stay readable over
                        // bright scenes.
                        VStack(spacing: 0) {
                            LinearGradient(
                                colors: [.black.opacity(0.32), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 90)
                            Spacer(minLength: 0)
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.34)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 120)
                        }
                        .allowsHitTesting(false)
                    }
                    .overlay {
                        Rectangle()
                            .fill(Color.black)
                            .opacity(shutterFlashOpacity)
                            .allowsHitTesting(false)
                    }
                    .frame(width: fittedRect.width, height: fittedRect.height)
                    .position(x: fittedRect.midX, y: fittedRect.midY)

                if !viewModel.isInitialized {
                    startupIndicator
                }

                controlsOverlay(in: fittedRect.size)
                    .frame(width: fittedRect.width, height: fittedRect.height)
                    .position(x: fittedRect.midX, y: fittedRect.midY)
            }
            // Controls float over live video: always render them dark, iPhone-style.
            .environment(\.colorScheme, .dark)
        }
    }

    // MARK: - PiP overlay

    /// The screen-recording camera overlay: drag it anywhere and it snaps to the
    /// nearest corner (like FaceTime); hover reveals a close button.
    private func pipOverlay(previewSize: CGSize) -> some View {
        let pipSize = CGSize(
            width: min(previewSize.width * 0.24, 280),
            height: min(previewSize.height * 0.22, 180)
        )

        return PiPCameraPreview(
            onDragDelta: { delta in
                pipDragOffset.width += delta.width
                pipDragOffset.height += delta.height
            },
            onDragEnded: {
                snapPiPToNearestCorner(previewSize: previewSize, pipSize: pipSize)
            }
        )
        .frame(width: pipSize.width, height: pipSize.height)
        .overlay(alignment: .topLeading) {
            if isPiPHovered {
                Button {
                    Task { await viewModel.setPiPEnabled(false) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(7)
                .transition(.opacity)
                .help("Hide camera overlay")
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isPiPHovered = hovering
            }
        }
        .offset(pipDragOffset)
        .padding(16)
    }

    private func snapPiPToNearestCorner(previewSize: CGSize, pipSize: CGSize) {
        let inset: CGFloat = 16
        let corner = viewModel.settings.screenRecording.pipCorner

        let anchorX = (corner == .topLeft || corner == .bottomLeft)
            ? inset + pipSize.width / 2
            : previewSize.width - inset - pipSize.width / 2
        let anchorY = (corner == .topLeft || corner == .topRight)
            ? inset + pipSize.height / 2
            : previewSize.height - inset - pipSize.height / 2

        let centerX = anchorX + pipDragOffset.width
        let centerY = anchorY + pipDragOffset.height

        let newCorner: PiPCorner = centerY < previewSize.height / 2
            ? (centerX < previewSize.width / 2 ? .topLeft : .topRight)
            : (centerX < previewSize.width / 2 ? .bottomLeft : .bottomRight)

        Task { @MainActor in
            if newCorner != corner {
                // Re-express the current visual position relative to the new
                // anchor so the switch itself is invisible, then glide home.
                let newAnchorX = (newCorner == .topLeft || newCorner == .bottomLeft)
                    ? inset + pipSize.width / 2
                    : previewSize.width - inset - pipSize.width / 2
                let newAnchorY = (newCorner == .topLeft || newCorner == .topRight)
                    ? inset + pipSize.height / 2
                    : previewSize.height - inset - pipSize.height / 2
                pipDragOffset = CGSize(width: centerX - newAnchorX, height: centerY - newAnchorY)
                await viewModel.setPiPCorner(newCorner)
            }

            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                pipDragOffset = .zero
            }
        }
    }

    private var startupIndicator: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Starting camera…")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    // MARK: - Controls

    private func controlsOverlay(in previewSize: CGSize) -> some View {
        let horizontalPadding = max(12, min(26, previewSize.width * 0.03))
        let verticalPadding = max(10, min(20, previewSize.height * 0.03))

        return VStack(spacing: 14) {
            topControls
            if viewModel.isRecording, let startedAt = viewModel.recordingStartedAt {
                RecordingTimeBadge(startedAt: startedAt)
                    .transition(.opacity)
            }
            Spacer()
            bottomControls
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        // The title bar overlays the content when visible; keep controls below it.
        .padding(.top, viewModel.settings.windowOptions.hideTitleBar ? 0 : 26)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isRecording)
    }

    private var topControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                if viewModel.settings.windowOptions.hideTitleBar {
                    iconButton("xmark.circle.fill", help: "Close window") {
                        hostWindow?.performClose(nil)
                    }
                }
                sourceQuickControl
                    .opacity(viewModel.isRecording ? 0.4 : 1.0)
                    .allowsHitTesting(!viewModel.isRecording)
                Spacer()
                if viewModel.settings.selectedInput?.type == .screen {
                    iconButton(
                        viewModel.settings.screenRecording.isPiPEnabled ? "pip.fill" : "pip",
                        help: viewModel.settings.screenRecording.isPiPEnabled
                            ? "Hide the camera overlay"
                            : "Show the camera overlay"
                    ) {
                        Task {
                            await viewModel.setPiPEnabled(!viewModel.settings.screenRecording.isPiPEnabled)
                        }
                    }
                }
                audioSourcesMenu
                iconButton("gearshape.fill", help: "Settings") {
                    viewModel.isSettingsPresented = true
                }
            }

            HStack(spacing: 18) {
                quickModeControls
                Spacer()
            }
        }
    }

    /// The capture source. Click/scroll cycles the Mac's own cameras only;
    /// ⌥-click/⌥-scroll includes screens and phone-backed sources; right-click or
    /// long-press opens the full menu. Casual interaction can therefore never
    /// trigger a screen-recording prompt or wake a phone.
    private var sourceQuickControl: some View {
        let allInputs = viewModel.inventory.selectableVideoInputs
        let mobileIDs = viewModel.inventory.mobileDeviceIDs
        let localCameras = allInputs.filter { $0.type == .camera && !mobileIDs.contains($0.id) }
        let currentID = viewModel.settings.selectedInput?.id

        return WheelValueControl(
            primary: .init(
                entries: localCameras.isEmpty ? ["No Camera"] : localCameras.map(\.name),
                selectedIndex: localCameras.firstIndex { $0.id == currentID }
            ),
            full: .init(
                entries: allInputs.isEmpty ? ["No Source"] : allInputs.map(\.name),
                selectedIndex: allInputs.firstIndex { $0.id == currentID }
            ),
            help: "Source — click/scroll cycles this Mac's cameras; ⌥ includes screens and phones; right-click for the full menu",
            onCommit: { [viewModel] index, inFullList in
                Task { @MainActor in
                    let all = viewModel.inventory.selectableVideoInputs
                    let mobile = viewModel.inventory.mobileDeviceIDs
                    let list = inFullList ? all : all.filter { $0.type == .camera && !mobile.contains($0.id) }
                    guard list.indices.contains(index) else {
                        return
                    }
                    await viewModel.selectInput(id: list[index].id)
                }
            }
        )
    }

    @ViewBuilder
    private var quickModeControls: some View {
        if viewModel.settings.mode == .photo {
            simpleWheelControl(
                entries: PhotoFormat.allCases.map { $0.rawValue.uppercased() },
                selectedIndex: PhotoFormat.allCases.firstIndex(of: viewModel.settings.photoFormat),
                help: "Photo format — click or scroll to change, right-click for all"
            ) { [viewModel] index in
                guard PhotoFormat.allCases.indices.contains(index) else {
                    return
                }
                await viewModel.setPhotoFormat(PhotoFormat.allCases[index])
            }

            simpleWheelControl(
                entries: PhotoQuality.allCases.map { $0.rawValue.uppercased() },
                selectedIndex: PhotoQuality.allCases.firstIndex(of: viewModel.settings.photoQuality),
                help: "Photo quality — click or scroll to change, right-click for all"
            ) { [viewModel] index in
                guard PhotoQuality.allCases.indices.contains(index) else {
                    return
                }
                await viewModel.setPhotoQuality(PhotoQuality.allCases[index])
            }
        } else {
            simpleWheelControl(
                entries: VideoResolution.allCases.map(Self.resolutionText),
                selectedIndex: VideoResolution.allCases.firstIndex(of: viewModel.settings.videoResolution),
                help: "Resolution — click or scroll to change, right-click for all"
            ) { [viewModel] index in
                guard VideoResolution.allCases.indices.contains(index) else {
                    return
                }
                await viewModel.setVideoResolution(VideoResolution.allCases[index])
            }

            simpleWheelControl(
                entries: VideoFrameRate.allCases.map { "\($0.rawValue) FPS" },
                selectedIndex: VideoFrameRate.allCases.firstIndex(of: viewModel.settings.videoFrameRate),
                help: "Frame rate — click or scroll to change, right-click for all"
            ) { [viewModel] index in
                guard VideoFrameRate.allCases.indices.contains(index) else {
                    return
                }
                await viewModel.setVideoFrameRate(VideoFrameRate.allCases[index])
            }
        }
    }

    /// A wheel control whose quick list and full list are the same.
    private func simpleWheelControl(
        entries: [String],
        selectedIndex: Int?,
        help: String,
        commit: @escaping (Int) async -> Void
    ) -> some View {
        let choices = WheelValueControl.Choices(entries: entries, selectedIndex: selectedIndex)
        return WheelValueControl(
            primary: choices,
            full: choices,
            help: help,
            onCommit: { index, _ in
                Task { @MainActor in
                    await commit(index)
                }
            }
        )
    }

    private static func resolutionText(_ resolution: VideoResolution) -> String {
        switch resolution {
        case .hd720:
            return "720P"
        case .hd1080:
            return "1080P"
        case .uhd4k:
            return "4K"
        }
    }

    /// On-display audio control: a native menu with a checkmark per source —
    /// check to add a source to recordings, uncheck to remove it.
    private var audioSourcesMenu: some View {
        let sources = viewModel.settings.selectedAudioSources
        let hasLiveMicrophone = sources.contains { $0.isEnabled && $0.kind == .microphone }

        return Menu {
            if sources.isEmpty {
                Text("No audio sources found")
            }
            ForEach(sources) { source in
                Toggle(
                    source.name,
                    isOn: Binding(
                        get: { source.isEnabled },
                        set: { enabled in
                            Task { await viewModel.setAudioSourceEnabled(id: source.id, isEnabled: enabled) }
                        }
                    )
                )
            }
            Divider()
            Button("Audio Settings…") {
                viewModel.isSettingsPresented = true
            }
        } label: {
            Image(systemName: hasLiveMicrophone ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hasLiveMicrophone ? Color.white : Color.red)
                .shadow(color: .black.opacity(0.6), radius: 3)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(HoverScale())
        .help("Audio sources — check to record from a device")
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        OverlayIconButton(systemName: systemName, help: help, action: action)
    }

    private var bottomControls: some View {
        VStack(spacing: 14) {
            if !viewModel.isRecording {
                modeSwitcher
                    .transition(.opacity)
            }

            ZStack {
                HStack {
                    ThumbnailView(image: viewModel.lastThumbnail)
                        .scaleEffect(thumbnailScale)
                        .onTapGesture {
                            viewModel.openLastMediaInFinder()
                        }
                        .help(viewModel.lastMediaIsInPhotoLibrary ? "Open Photos" : "Show last capture in Finder")

                    Spacer()

                    iconButton("folder.fill", help: "Open the media folder") {
                        viewModel.openMediaDirectory()
                    }
                }

                captureButton
            }
        }
    }

    /// iPhone-style PHOTO | VIDEO switcher above the shutter.
    private var modeSwitcher: some View {
        HStack(spacing: 26) {
            modeSwitcherButton("PHOTO", mode: .photo)
            modeSwitcherButton("VIDEO", mode: .video)
        }
    }

    private func modeSwitcherButton(_ title: String, mode: CaptureMode) -> some View {
        Button {
            Task { await viewModel.setMode(mode) }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(viewModel.settings.mode == mode ? Color.yellow : Color.white.opacity(0.75))
                .shadow(color: .black.opacity(0.6), radius: 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: viewModel.settings.mode)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var captureButton: some View {
        let isRecordingVideo = viewModel.settings.mode == .video && viewModel.isRecording
        let isBusy = viewModel.settings.mode == .photo && viewModel.isCapturingPhoto

        return Button {
            Task { await viewModel.captureButtonPressed() }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 78, height: 78)

                RoundedRectangle(cornerRadius: isRecordingVideo ? 8 : 32, style: .continuous)
                    .fill(viewModel.settings.mode == .video ? Color.red : Color.white)
                    .frame(
                        width: isRecordingVideo ? 30 : 64,
                        height: isRecordingVideo ? 30 : 64
                    )
            }
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(ShutterButtonStyle())
        .keyboardShortcut(.space, modifiers: [])
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1.0)
        .help(shutterHelp)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: viewModel.isRecording)
    }

    private var shutterHelp: String {
        if viewModel.settings.mode == .photo {
            return "Take photo (Space)"
        }
        return viewModel.isRecording ? "Stop recording (Space)" : "Start recording (Space)"
    }

    // MARK: - Layout helpers

    private var pipAlignment: Alignment {
        switch viewModel.settings.screenRecording.pipCorner {
        case .topLeft:
            return .topLeading
        case .topRight:
            return .topTrailing
        case .bottomLeft:
            return .bottomLeading
        case .bottomRight:
            return .bottomTrailing
        }
    }

    private var previewAspectRatio: CGFloat {
        // Prefer the aspect of the frames actually being delivered.
        if let active = viewModel.activeVideoAspectRatio, active > 0 {
            return active
        }

        if let selected = viewModel.settings.selectedInput,
           selected.type == .screen,
           let displayID = UInt32(selected.id),
           let screen = NSScreen.screens.first(where: { screen in
               guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                   return false
               }
               return number.uint32Value == displayID
           }) {
            let frame = screen.frame
            if frame.height > 0 {
                return frame.width / frame.height
            }
        }

        switch viewModel.settings.mode {
        case .photo:
            return 4.0 / 3.0
        case .video:
            let dimensions = viewModel.settings.videoResolution.dimensions
            return CGFloat(dimensions.width) / CGFloat(dimensions.height)
        }
    }

    // MARK: - Effects

    private func triggerShutterFlash() {
        shutterFlashOpacity = 1
        withAnimation(.easeOut(duration: 0.25).delay(0.04)) {
            shutterFlashOpacity = 0
        }
    }

    private func popThumbnail() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.55)) {
            thumbnailScale = 1.12
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.14)) {
            thumbnailScale = 1.0
        }
    }

    // MARK: - Window management

    private func applyWindowAspectRatio(_ ratio: CGFloat, animated: Bool, allowComfortableGrowth: Bool = false) {
        guard ratio > 0, let window = hostWindow else {
            return
        }

        // The window is always full-size-content, so the video fills the whole
        // FRAME in both title-bar modes. Constrain and size the frame directly:
        // AppKit's "content rect" math still subtracts a title bar and would leave
        // a 28-point letterbox.
        window.aspectRatio = NSSize(width: ratio, height: 1.0)

        let minFrameWidth: CGFloat = 980
        let minFrameHeight: CGFloat = 540
        let currentFrame = window.frame.size
        var targetWidth = max(currentFrame.width, minFrameWidth)

        // First placement only: open at a comfortable fraction of the screen
        // instead of the bare minimum; later changes keep the user's size.
        if allowComfortableGrowth, let screen = window.screen ?? NSScreen.main {
            targetWidth = max(targetWidth, (screen.visibleFrame.width * 0.55).rounded())
        }

        var targetHeight = targetWidth / ratio
        if targetHeight < minFrameHeight {
            targetHeight = minFrameHeight
            targetWidth = targetHeight * ratio
        }

        // Never outgrow the screen.
        if let screen = window.screen ?? NSScreen.main {
            let available = screen.visibleFrame.size
            let scale = min(1.0, available.width / targetWidth, available.height / targetHeight)
            targetWidth *= scale
            targetHeight *= scale
        }

        guard abs(currentFrame.width - targetWidth) > 1
            || abs(currentFrame.height - targetHeight) > 1 else {
            return
        }

        // Anchor the top-left corner so the window grows downward, and animate
        // the transition instead of jumping.
        var targetFrame = window.frame
        targetFrame.origin.y = window.frame.maxY - targetHeight
        targetFrame.size = NSSize(width: targetWidth, height: targetHeight)
        window.setFrame(targetFrame, display: true, animate: animated)
    }

    private func applyWindowChromeOptions() {
        guard let window = hostWindow else {
            return
        }

        let options = viewModel.settings.windowOptions
        window.isMovableByWindowBackground = options.allowBackgroundDrag

        // The window is always full-size-content (scene windowStyle). The toggle
        // only draws or hides the bar's material and buttons over the content, so
        // the layout and aspect never shift.
        window.styleMask.insert(.fullSizeContentView)
        if options.hideTitleBar {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        } else {
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
        }

        window.standardWindowButton(.closeButton)?.isHidden = options.hideTitleBar
        window.standardWindowButton(.miniaturizeButton)?.isHidden = options.hideTitleBar
        window.standardWindowButton(.zoomButton)?.isHidden = options.hideTitleBar
    }

    /// Applies chrome, snaps the aspect immediately, and re-snaps on the next
    /// runloop turn once AppKit has settled the style-mask change — toggling
    /// `.fullSizeContentView` moves the frame↔content relationship after the
    /// current pass, which used to leave a stale strip and a mismatched aspect.
    private func applyChromeAndAspectNow(animated: Bool, allowComfortableGrowth: Bool = false) {
        applyWindowChromeOptions()
        applyWindowAspectRatio(previewAspectRatio, animated: animated, allowComfortableGrowth: allowComfortableGrowth)
        DispatchQueue.main.async {
            hostWindow?.contentView?.needsLayout = true
            applyWindowAspectRatio(previewAspectRatio, animated: false)
        }
    }

    /// Re-snaps only when the frame has actually drifted from the video's ratio.
    private func snapWindowToAspectIfNeeded() {
        guard let window = hostWindow else {
            return
        }

        let ratio = previewAspectRatio
        let frame = window.frame.size
        guard ratio > 0, frame.height > 0 else {
            return
        }

        if abs(frame.width / frame.height - ratio) > 0.005 {
            applyWindowAspectRatio(ratio, animated: false)
        }
    }

    /// Cheap mismatch check so chrome is only rewritten when something undid it.
    private func reassertChromeIfNeeded(_ window: NSWindow) {
        let hide = viewModel.settings.windowOptions.hideTitleBar
        let matches = (window.titleVisibility == (hide ? .hidden : .visible))
            && window.styleMask.contains(.fullSizeContentView)
            && (window.titlebarAppearsTransparent == hide)
            && (window.standardWindowButton(.closeButton)?.isHidden == hide)
        if !matches {
            applyChromeAndAspectNow(animated: false)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    viewModel.errorMessage = nil
                }
            }
        )
    }
}

// MARK: - Components

#if DEBUG
/// Env-provided stand-in imagery for App Store screenshots
/// (`MBCAMERA_DEBUG_DEMO_BACKDROP` / `MBCAMERA_DEBUG_DEMO_PIP`); DEBUG-only,
/// never part of release builds.
enum DebugDemoBackdrop {
    static let main: NSImage? = ProcessInfo.processInfo
        .environment["MBCAMERA_DEBUG_DEMO_BACKDROP"]
        .flatMap { NSImage(contentsOfFile: $0) }
    static let pip: NSImage? = ProcessInfo.processInfo
        .environment["MBCAMERA_DEBUG_DEMO_PIP"]
        .flatMap { NSImage(contentsOfFile: $0) }
}
#endif

/// Gentle grow-on-hover feedback shared by the floating controls.
private struct HoverScale: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovered ? 1.12 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
            .onHover { hovered = $0 }
    }
}

private struct OverlayIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverScale())
        .help(help)
    }
}

/// iPhone-style quick setting rendered as a picker wheel. Idle it is just the
/// value in yellow; while scrolling it becomes a smooth, momentum-tracking wheel
/// with neighboring options dimmed above and below, snapping on release.
/// Click steps to the next value in the primary list; ⌥-click/⌥-scroll use the
/// full list; right-click or long-press opens a native menu of every option.
private struct WheelValueControl: View {
    struct Choices {
        var entries: [String]
        var selectedIndex: Int?
    }

    /// List used by plain click/scroll.
    var primary: Choices
    /// List used with ⌥ held, and by the options menu. Same as `primary` for
    /// controls without a restricted quick list.
    var full: Choices
    var help: String
    var onCommit: (_ index: Int, _ inFullList: Bool) -> Void

    private static let rowHeight: CGFloat = 20

    @State private var isInteracting = false
    @State private var wheelOffset: CGFloat = 0
    /// Index the wheel is visually on during a gesture (commits can lag a frame).
    @State private var virtualIndex: Int?
    @State private var gestureUsesFullList = false
    @State private var idleToken = 0

    private var activeChoices: Choices {
        gestureUsesFullList ? full : primary
    }

    private var idleText: String {
        if let index = full.selectedIndex, full.entries.indices.contains(index) {
            return full.entries[index]
        }
        return full.entries.first ?? "—"
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Width anchor: every option rendered invisibly at the selected-value
            // font, so the control always occupies the width of its WIDEST entry
            // and never shifts position while scrolling or after a change.
            ForEach(Array(Set(primary.entries + full.entries)).sorted(), id: \.self) { entry in
                Text(entry)
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(1.1)
                    .lineLimit(1)
                    .opacity(0)
                    .accessibilityHidden(true)
            }

            Text(idleText)
                .font(.system(size: 13, weight: .semibold))
                .kerning(1.1)
                .lineLimit(1)
                .foregroundStyle(.yellow)
                .shadow(color: .black.opacity(0.65), radius: 3)
                .opacity(isInteracting ? 0 : 1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .overlay(alignment: .leading) {
            // Out of layout flow: the wheel overflows vertically without moving
            // the control or its neighbors.
            if isInteracting {
                wheelRows
                    .padding(.horizontal, 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isInteracting)
        .overlay(
            WheelEventCatcher(
                menuTitles: full.entries,
                menuSelectedIndex: full.selectedIndex,
                onClick: handleClick,
                onScroll: handleScroll,
                onMenuSelect: { index in
                    onCommit(index, true)
                }
            )
        )
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(help)
    }

    private var wheelRows: some View {
        let entries = activeChoices.entries
        let center = virtualIndex ?? activeChoices.selectedIndex ?? 0
        let count = max(entries.count, 1)
        let maxRel = count >= 5 ? 2 : 1

        return ZStack(alignment: .leading) {
            ForEach(-maxRel...maxRel, id: \.self) { rel in
                wheelRow(rel: rel, center: center, entries: entries, count: count)
            }
        }
        .frame(height: Self.rowHeight * 3)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.22),
                    .init(color: .black, location: 0.78),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Precomputed into typed locals: the inline ternary version of this row
    /// exceeds the type-checker budget on some build hosts (Xcode Cloud, x86_64).
    private func wheelRow(rel: Int, center: Int, entries: [String], count: Int) -> some View {
        let index = ((center + rel) % count + count) % count
        let position: CGFloat = CGFloat(rel) - wheelOffset
        let distance: CGFloat = min(abs(position), 2)
        let isCurrent = distance < 0.5

        let text: String = entries.indices.contains(index) ? entries[index] : ""
        let fontSize: CGFloat = isCurrent ? 13 : 11
        let fontWeight: Font.Weight = isCurrent ? .semibold : .medium
        let color: Color = isCurrent ? .yellow : .white
        let rowOpacity: Double = max(0.12, 1.0 - Double(distance) * 0.55)
        let yOffset: CGFloat = position * Self.rowHeight

        return Text(text)
            .font(.system(size: fontSize, weight: fontWeight))
            .kerning(1.0)
            .lineLimit(1)
            .foregroundStyle(color)
            .opacity(rowOpacity)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .offset(y: yOffset)
    }

    // MARK: Interaction

    private func handleClick(optionHeld: Bool) {
        beginGestureIfNeeded(useFullList: optionHeld)
        step(1)
        settle()
    }

    private func handleScroll(deltaY: CGFloat, optionHeld: Bool, phase: WheelScrollPhase) {
        switch phase {
        case .began:
            beginGestureIfNeeded(useFullList: optionHeld, forceRelock: true)

        case .changed, .momentum:
            beginGestureIfNeeded(useFullList: optionHeld)
            // Content follows the fingers: scrolling up moves toward previous.
            wheelOffset -= deltaY / 34
            while wheelOffset >= 0.5 {
                step(1)
                wheelOffset -= 1
            }
            while wheelOffset <= -0.5 {
                step(-1)
                wheelOffset += 1
            }

        case .ended:
            settle()

        case .discrete:
            beginGestureIfNeeded(useFullList: optionHeld)
            step(deltaY < 0 ? 1 : -1)
            settle()
        }
    }

    private func beginGestureIfNeeded(useFullList: Bool, forceRelock: Bool = false) {
        if !isInteracting || forceRelock {
            gestureUsesFullList = useFullList
            virtualIndex = activeChoices.selectedIndex ?? 0
        }
        if !isInteracting {
            withAnimation(.easeOut(duration: 0.12)) {
                isInteracting = true
            }
        }
    }

    private func step(_ direction: Int) {
        let entries = activeChoices.entries
        guard !entries.isEmpty else {
            return
        }

        let count = entries.count
        let current = virtualIndex ?? activeChoices.selectedIndex ?? 0
        let next = ((current + direction) % count + count) % count
        virtualIndex = next
        onCommit(next, gestureUsesFullList)
    }

    /// Snaps the wheel to rest and fades it out after a moment of quiet.
    private func settle() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            wheelOffset = 0
        }

        idleToken += 1
        let token = idleToken
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard token == idleToken else {
                return
            }
            withAnimation(.easeOut(duration: 0.3)) {
                isInteracting = false
            }
            wheelOffset = 0
            virtualIndex = nil
        }
    }
}

private enum WheelScrollPhase {
    case began
    case changed
    case momentum
    case ended
    case discrete
}

/// Transparent AppKit layer providing what SwiftUI can't on macOS: phase-aware
/// scroll-wheel deltas, ⌥-modified clicks, long-press detection, and a native
/// options menu.
private struct WheelEventCatcher: NSViewRepresentable {
    var menuTitles: [String]
    var menuSelectedIndex: Int?
    var onClick: (_ optionHeld: Bool) -> Void
    var onScroll: (_ deltaY: CGFloat, _ optionHeld: Bool, _ phase: WheelScrollPhase) -> Void
    var onMenuSelect: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        update(nsView)
    }

    private func update(_ view: CatcherView) {
        view.menuTitles = menuTitles
        view.menuSelectedIndex = menuSelectedIndex
        view.onClick = onClick
        view.onScroll = onScroll
        view.onMenuSelect = onMenuSelect
    }

    final class CatcherView: NSView {
        var menuTitles: [String] = []
        var menuSelectedIndex: Int?
        var onClick: ((Bool) -> Void)?
        var onScroll: ((CGFloat, Bool, WheelScrollPhase) -> Void)?
        var onMenuSelect: ((Int) -> Void)?

        private var downLocation: NSPoint?
        private var menuDidShow = false

        override func mouseDown(with event: NSEvent) {
            downLocation = event.locationInWindow
            menuDidShow = false
            if !menuTitles.isEmpty {
                perform(#selector(longPressFired), with: nil, afterDelay: 0.45)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let downLocation else {
                return
            }
            let location = event.locationInWindow
            if hypot(location.x - downLocation.x, location.y - downLocation.y) > 4 {
                cancelLongPress()
            }
        }

        override func mouseUp(with event: NSEvent) {
            cancelLongPress()
            defer { downLocation = nil }

            guard !menuDidShow, let downLocation else {
                return
            }

            let location = event.locationInWindow
            guard hypot(location.x - downLocation.x, location.y - downLocation.y) < 4 else {
                return
            }

            onClick?(event.modifierFlags.contains(.option))
        }

        override func rightMouseDown(with event: NSEvent) {
            showOptionsMenu(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            let optionHeld = event.modifierFlags.contains(.option)

            let phase: WheelScrollPhase
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                phase = .began
            } else if event.phase.contains(.changed) {
                phase = .changed
            } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                // Momentum may still follow; the wheel settles again on its end.
                phase = .ended
            } else if event.momentumPhase.contains(.changed) || event.momentumPhase.contains(.began) {
                phase = .momentum
            } else if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                phase = .ended
            } else {
                // Classic mouse wheel: line-based discrete clicks.
                phase = .discrete
            }

            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 8
            onScroll?(delta, optionHeld, phase)
        }

        @objc private func longPressFired() {
            menuDidShow = true
            showOptionsMenu(with: nil)
        }

        @objc private func pickMenuItem(_ item: NSMenuItem) {
            onMenuSelect?(item.tag)
        }

        private func cancelLongPress() {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(longPressFired), object: nil)
        }

        private func showOptionsMenu(with event: NSEvent?) {
            guard !menuTitles.isEmpty else {
                return
            }

            let menu = NSMenu()
            for (index, title) in menuTitles.enumerated() {
                let item = NSMenuItem(title: title, action: #selector(pickMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.state = index == menuSelectedIndex ? .on : .off
                menu.addItem(item)
            }

            if let event {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            } else {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
            }
        }
    }
}

/// Presses shrink the shutter slightly, like a physical button.
private struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct RecordingTimeBadge: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt).rounded(.down)))
            HStack(spacing: 7) {
                PulsingDot()
                Text(Self.format(elapsed))
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.red.opacity(0.88))
            )
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
    }

    private static func format(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

private struct PulsingDot: View {
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 7, height: 7)
            .opacity(dimmed ? 0.35 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

private struct ThumbnailView: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.12))
                    Image(systemName: "photo")
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
        }
        .frame(width: 84, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// iPhone-style focus indicator: a yellow rounded square with edge ticks that
/// scales in on tap and fades away.
private struct FocusReticle: View {
    let position: CGPoint
    @State private var appeared = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(Color.yellow, lineWidth: 1.5)
            .overlay(alignment: .top) { verticalTick }
            .overlay(alignment: .bottom) { verticalTick }
            .overlay(alignment: .leading) { horizontalTick }
            .overlay(alignment: .trailing) { horizontalTick }
            .frame(width: 78, height: 78)
            .shadow(color: .black.opacity(0.35), radius: 2)
            .scaleEffect(appeared ? 1.0 : 1.4)
            .position(position)
            .onAppear {
                withAnimation(.easeOut(duration: 0.22)) {
                    appeared = true
                }
            }
    }

    private var verticalTick: some View {
        Rectangle()
            .fill(Color.yellow)
            .frame(width: 1.5, height: 7)
    }

    private var horizontalTick: some View {
        Rectangle()
            .fill(Color.yellow)
            .frame(width: 7, height: 1.5)
    }
}
