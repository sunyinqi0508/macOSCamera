import CameraCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isResetConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Form {
                mediaSection
                captureSection
                audioSection
                screenRecordingSection
                windowSection
                resetSection
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 620, height: 700)
        .task {
            await viewModel.refreshDevices()
        }
        .alert("Reset all settings?", isPresented: $isResetConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task {
                    await viewModel.resetAllSettings()
                }
            }
        } message: {
            Text("This restores capture settings and device selections to defaults.")
        }
    }

    // MARK: - Media

    private var mediaSection: some View {
        Section {
            Picker(
                "Save To",
                selection: Binding(
                    get: { viewModel.settings.mediaDestination },
                    set: { newValue in
                        Task { await viewModel.setMediaDestination(newValue) }
                    }
                )
            ) {
                Text("Folder").tag(MediaDestination.photosDirectory)
                Text("Photos Library").tag(MediaDestination.photoLibrary)
            }
            .pickerStyle(.segmented)

            if viewModel.settings.mediaDestination == .photosDirectory {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text((viewModel.settings.mediaDirectoryPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)

                        Button("Choose…") {
                            viewModel.chooseMediaDirectoryFromPanel()
                        }
                    }
                }
            }
        } header: {
            Label("Media", systemImage: "folder")
        } footer: {
            if viewModel.settings.mediaDestination == .photosDirectory {
                Text("Photos and videos are saved with timestamped names; existing files are never overwritten.")
            } else {
                Text("Captures are imported directly into your Photos library.")
            }
        }
    }

    // MARK: - Capture

    private var captureSection: some View {
        Section {
            Picker(
                "Photo Format",
                selection: Binding(
                    get: { viewModel.settings.photoFormat },
                    set: { newValue in
                        Task { await viewModel.setPhotoFormat(newValue) }
                    }
                )
            ) {
                ForEach(PhotoFormat.allCases) { format in
                    Text(format.rawValue.uppercased()).tag(format)
                }
            }

            Picker(
                "Photo Quality",
                selection: Binding(
                    get: { viewModel.settings.photoQuality },
                    set: { newValue in
                        Task { await viewModel.setPhotoQuality(newValue) }
                    }
                )
            ) {
                ForEach(PhotoQuality.allCases) { quality in
                    Text(quality.rawValue.capitalized).tag(quality)
                }
            }

            Picker(
                "Video Resolution",
                selection: Binding(
                    get: { viewModel.settings.videoResolution },
                    set: { newValue in
                        Task { await viewModel.setVideoResolution(newValue) }
                    }
                )
            ) {
                Text("720p").tag(VideoResolution.hd720)
                Text("1080p").tag(VideoResolution.hd1080)
                Text("4K").tag(VideoResolution.uhd4k)
            }

            Picker(
                "Frame Rate",
                selection: Binding(
                    get: { viewModel.settings.videoFrameRate },
                    set: { newValue in
                        Task { await viewModel.setVideoFrameRate(newValue) }
                    }
                )
            ) {
                ForEach(VideoFrameRate.allCases) { fps in
                    Text("\(fps.rawValue) fps").tag(fps)
                }
            }
        } header: {
            Label("Capture", systemImage: "camera.aperture")
        } footer: {
            Text("Unsupported combinations fall back to the closest the selected camera can deliver.")
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        Section {
            if viewModel.settings.selectedAudioSources.isEmpty {
                Text("No audio sources found")
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.settings.selectedAudioSources) { source in
                audioSourceRow(source)
            }
        } header: {
            Label("Audio Sources", systemImage: "waveform")
        } footer: {
            Text("Enabled sources are mixed into recordings; gains are normalized. Capturing a system output directly requires a loopback driver (e.g. BlackHole), which then appears here as an input.")
        }
    }

    private func audioSourceRow(_ source: AudioSourceSelection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                isOn: Binding(
                    get: { source.isEnabled },
                    set: { newValue in
                        Task { await viewModel.setAudioSourceEnabled(id: source.id, isEnabled: newValue) }
                    }
                )
            ) {
                Label {
                    Text(source.name)
                } icon: {
                    Image(systemName: source.kind == .microphone ? "mic" : "speaker.wave.2")
                        .foregroundStyle(source.isEnabled ? Color.accentColor : Color.secondary)
                }
            }

            HStack(spacing: 10) {
                Text("Gain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { source.gain },
                        set: { newValue in
                            Task { await viewModel.setAudioSourceGain(id: source.id, gain: newValue) }
                        }
                    ),
                    in: 0...2
                )
                .controlSize(.small)

                Text(String(format: "%.2f", source.gain))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .disabled(!source.isEnabled)
            .opacity(source.isEnabled ? 1.0 : 0.4)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Screen recording

    private var screenRecordingSection: some View {
        Section {
            Toggle(
                "Include Microphone Audio",
                isOn: Binding(
                    get: { viewModel.settings.screenRecording.includeMicrophoneAudio },
                    set: { newValue in
                        Task { await viewModel.setIncludeMicrophoneAudio(newValue) }
                    }
                )
            )

            Toggle(
                "Include System Audio",
                isOn: Binding(
                    get: { viewModel.settings.screenRecording.includeSystemAudio },
                    set: { newValue in
                        Task { await viewModel.setIncludeSystemAudio(newValue) }
                    }
                )
            )

            Toggle(
                "Camera Overlay (PiP)",
                isOn: Binding(
                    get: { viewModel.settings.screenRecording.isPiPEnabled },
                    set: { newValue in
                        Task { await viewModel.setPiPEnabled(newValue) }
                    }
                )
            )

            Picker(
                "Overlay Corner",
                selection: Binding(
                    get: { viewModel.settings.screenRecording.pipCorner },
                    set: { newValue in
                        Task { await viewModel.setPiPCorner(newValue) }
                    }
                )
            ) {
                Text("Top Left").tag(PiPCorner.topLeft)
                Text("Top Right").tag(PiPCorner.topRight)
                Text("Bottom Left").tag(PiPCorner.bottomLeft)
                Text("Bottom Right").tag(PiPCorner.bottomRight)
            }
            .disabled(!viewModel.settings.screenRecording.isPiPEnabled)
        } header: {
            Label("Screen Recording", systemImage: "rectangle.inset.filled.and.cursorarrow")
        } footer: {
            Text("The camera overlay can also be dragged between corners or closed directly on the preview.")
        }
    }

    // MARK: - Window

    private var windowSection: some View {
        Section {
            Toggle(
                "Hide Title Bar",
                isOn: Binding(
                    get: { viewModel.settings.windowOptions.hideTitleBar },
                    set: { newValue in
                        Task { await viewModel.setHideTitleBar(newValue) }
                    }
                )
            )

            Toggle(
                "Drag Window By Background",
                isOn: Binding(
                    get: { viewModel.settings.windowOptions.allowBackgroundDrag },
                    set: { newValue in
                        Task { await viewModel.setAllowBackgroundDrag(newValue) }
                    }
                )
            )
        } header: {
            Label("Window", systemImage: "macwindow")
        } footer: {
            Text("Dragging anywhere on the preview always moves the window; a tap sets focus and exposure.")
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                isResetConfirmationPresented = true
            } label: {
                Label("Reset All Settings…", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
        } footer: {
            Text("Restores capture settings and device selections to their defaults.")
        }
    }
}
