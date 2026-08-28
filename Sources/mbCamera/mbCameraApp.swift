import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: CameraViewModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running with the window closed only while a recording is active
        // (e.g. a screen recording deliberately left unattended).
        viewModel?.isRecording != true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.isRecording else {
            return .terminateNow
        }

        // Finish and persist the in-flight recording instead of losing it.
        Task { @MainActor in
            await viewModel.finishActiveRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MBCameraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = CameraViewModel()

    var body: some Scene {
        // A single reusable window: the preview layer can only live in one place.
        // Full-size content from birth (hiddenTitleBar) so toggling the title bar
        // at runtime never migrates the layout — the bar just overlays the video.
        Window("Camera", id: "main") {
            ContentView(viewModel: viewModel)
                .task {
                    appDelegate.viewModel = viewModel
                    await viewModel.initialize()
                    #if DEBUG
                    // Automated UI checks: runtime title-bar toggle / mode switch.
                    if ProcessInfo.processInfo.environment["MBCAMERA_DEBUG_TOGGLE_TITLEBAR"] != nil {
                        try? await Task.sleep(for: .seconds(6))
                        await viewModel.setHideTitleBar(!viewModel.settings.windowOptions.hideTitleBar)
                    }
                    if ProcessInfo.processInfo.environment["MBCAMERA_DEBUG_SWITCH_MODE"] != nil {
                        try? await Task.sleep(for: .seconds(6))
                        await viewModel.setMode(viewModel.settings.mode == .photo ? .video : .photo)
                    }
                    if ProcessInfo.processInfo.environment["MBCAMERA_DEBUG_OPEN_SETTINGS"] != nil {
                        try? await Task.sleep(for: .seconds(3))
                        viewModel.isSettingsPresented = true
                    }
                    if ProcessInfo.processInfo.environment["MBCAMERA_DEBUG_BREAK_ASPECT"] != nil {
                        // Simulates a frame stomp (state restoration / SwiftUI clamp).
                        try? await Task.sleep(for: .seconds(5))
                        NSApp.windows.first { $0.styleMask.contains(.titled) }?
                            .setFrame(NSRect(x: 200, y: 100, width: 1253, height: 732), display: true)
                    }
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
