@preconcurrency import AVFoundation
import AppKit
import QuartzCore
import SwiftUI

struct CapturePreviewView: NSViewRepresentable {
    let controller: VisionProCaptureController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        controller.attachRenderLayer(view.videoLayer)
        context.coordinator.controller = controller
        return view
    }

    func updateNSView(_ nsView: PreviewContainerView, context: Context) {
        guard context.coordinator.controller?.id != controller.id else {
            return
        }

        if let oldController = context.coordinator.controller {
            oldController.detachRenderLayer(nsView.videoLayer)
        }

        controller.attachRenderLayer(nsView.videoLayer)
        context.coordinator.controller = controller
    }

    static func dismantleNSView(_ nsView: PreviewContainerView, coordinator: Coordinator) {
        coordinator.controller?.detachRenderLayer(nsView.videoLayer)
    }

    final class Coordinator {
        var controller: VisionProCaptureController?

        init(controller: VisionProCaptureController) {
            self.controller = controller
        }
    }
}

final class PreviewContainerView: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
        videoLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}
