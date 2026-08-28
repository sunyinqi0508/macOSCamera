import AVFoundation
import AppKit
import SwiftUI

struct CameraPreviewView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    /// Called with a top-left-origin point and the view size when the user taps
    /// (as opposed to drags) the preview.
    var onTap: ((CGPoint, CGSize) -> Void)?
    /// When set, drags report incremental top-left-space deltas here instead of
    /// moving the window (used by the draggable PiP overlay).
    var onDragDelta: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?

    init(
        previewLayer: AVCaptureVideoPreviewLayer,
        onTap: ((CGPoint, CGSize) -> Void)? = nil,
        onDragDelta: ((CGSize) -> Void)? = nil,
        onDragEnded: (() -> Void)? = nil
    ) {
        self.previewLayer = previewLayer
        self.onTap = onTap
        self.onDragDelta = onDragDelta
        self.onDragEnded = onDragEnded
    }

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView(previewLayer: previewLayer)
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        nsView.updateLayer(previewLayer)
        apply(to: nsView)
    }

    private func apply(to view: PreviewHostView) {
        view.onTap = onTap
        view.onDragDelta = onDragDelta
        view.onDragEnded = onDragEnded
    }
}

/// Hosts the capture preview layer and handles mouse input directly:
/// a small click is a tap (focus/exposure); dragging either moves the window
/// (main preview) or reports deltas to the owner (PiP overlay).
final class PreviewHostView: NSView {
    var onTap: ((CGPoint, CGSize) -> Void)?
    var onDragDelta: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?

    private var previewLayer: AVCaptureVideoPreviewLayer
    private var mouseDownLocation: NSPoint?
    private var lastDragLocation: NSPoint?
    private var isDraggingWindow = false
    private var isCustomDragging = false

    private static let dragThreshold: CGFloat = 4

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateLayer(_ previewLayer: AVCaptureVideoPreviewLayer) {
        if self.previewLayer !== previewLayer {
            self.previewLayer.removeFromSuperlayer()
            self.previewLayer = previewLayer
            layer?.addSublayer(previewLayer)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Without this the preview rubber-bands behind live window resizes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        lastDragLocation = event.locationInWindow
        isDraggingWindow = false
        isCustomDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else {
            return
        }

        let location = event.locationInWindow

        if onDragDelta != nil {
            let movedFarEnough = hypot(location.x - start.x, location.y - start.y) > Self.dragThreshold
            guard isCustomDragging || movedFarEnough else {
                return
            }

            let reference = isCustomDragging ? (lastDragLocation ?? start) : start
            isCustomDragging = true
            lastDragLocation = location
            // Window coordinates are y-up; the SwiftUI overlay works y-down.
            onDragDelta?(CGSize(
                width: location.x - reference.x,
                height: -(location.y - reference.y)
            ))
            return
        }

        guard !isDraggingWindow else {
            return
        }

        let distance = hypot(location.x - start.x, location.y - start.y)
        guard distance > Self.dragThreshold else {
            return
        }

        isDraggingWindow = true
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            lastDragLocation = nil
            isDraggingWindow = false
            isCustomDragging = false
        }

        if isCustomDragging {
            onDragEnded?()
            return
        }

        guard !isDraggingWindow, mouseDownLocation != nil else {
            return
        }

        let local = convert(event.locationInWindow, from: nil)
        // NSView coordinates are bottom-left; the app works in top-left space.
        let topLeftPoint = CGPoint(x: local.x, y: bounds.height - local.y)
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        onTap?(topLeftPoint, bounds.size)
    }
}
