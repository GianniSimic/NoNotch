// ZoomShellApp.swift
// Final version with HotKey, ScreenCaptureKit, retained stream output, and window exclusion to prevent infinite zoom

import SwiftUI
import AppKit
import ScreenCaptureKit
import CoreImage
import CoreGraphics
import HotKey

@main
struct NoNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var zoomView: NSImageView!
    var shouldZoom = false

    let zoomFactor: CGFloat = 1.03
    var stream: SCStream?
    var outputHandler: StreamOutputHandler?
    var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKey = HotKey(key: .space, modifiers: [.control, .option, .command])
        hotKey?.keyDownHandler = {
            self.toggleZoom()
        }
    }

    func toggleZoom() {
        if shouldZoom {
            stopZoomOverlay()
        } else {
            Task {
                await self.startZoomOverlay()
            }
        }
        shouldZoom.toggle()
    }

    func startZoomOverlay() async {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame

        DispatchQueue.main.async {
            self.window = NSWindow(
                contentRect: screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )

            self.window.level = .screenSaver
            self.window.ignoresMouseEvents = true
            self.window.isOpaque = false
            self.window.backgroundColor = NSColor.clear
            self.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            self.zoomView = NSImageView(frame: screenFrame)
            self.zoomView.imageScaling = .scaleAxesIndependently
            self.zoomView.imageAlignment = .alignCenter
            self.window.contentView = self.zoomView
            self.window.makeKeyAndOrderFront(nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Task {
                await self.startScreenCapture()
            }
        }
    }

    func stopZoomOverlay() {
        stream?.stopCapture(completionHandler: { error in
            if let error = error {
                print("Stop error: \(error.localizedDescription)")
            }
        })
        DispatchQueue.main.async {
            self.window?.orderOut(nil)
            self.window = nil
        }
        stream = nil
    }

    func startScreenCapture() async {
        do {
            let config = SCStreamConfiguration()
            config.width = Int(NSScreen.main!.frame.width)
            config.height = Int(NSScreen.main!.frame.height)
            config.showsCursor = false

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let display = content.displays.first!

            guard let captureWindow = self.window else { return }
            let allWindows = content.windows
            let overlayID = CGWindowID(captureWindow.windowNumber)

            let excludedWindows = allWindows.filter { $0.windowID == overlayID }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)


            let output = StreamOutputHandler(view: zoomView, zoomFactor: zoomFactor)
            self.outputHandler = output

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            self.stream = stream
            try stream.addStreamOutput(output, type: SCStreamOutputType.screen, sampleHandlerQueue: DispatchQueue.main)
            try await stream.startCapture()

        } catch {
            print("Error starting stream: \(error)")
        }
    }
}

class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    let view: NSImageView
    let zoomFactor: CGFloat
    let context = CIContext(options: [.useSoftwareRenderer: false, .highQualityDownsample: false])


    init(view: NSImageView, zoomFactor: CGFloat) {
        self.view = view
        self.zoomFactor = zoomFactor
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvImageBuffer: imageBuffer)

        // Apply scaling first
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: zoomFactor, y: zoomFactor))

        // Now calculate the visible viewport to crop
        let width = ciImage.extent.width
        let height = ciImage.extent.height
        let visibleArea = CGRect(
            x: (width * zoomFactor - width) / 2,
            y: 0,  // bottom of the zoomed screen
            width: width,
            height: height
        )

        guard let croppedCGImage = context.createCGImage(scaledImage, from: visibleArea) else { return }
        let nsImage = NSImage(cgImage: croppedCGImage, size: visibleArea.size)

        DispatchQueue.main.async {
            self.view.image = nsImage
        }
    }

}
