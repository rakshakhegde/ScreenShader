import ScreenCaptureKit
import AppKit
import CoreGraphics

class ScreenCapture: NSObject, SCStreamDelegate {
  var config: Config! = nil
  var targetDisplayID: CGDirectDisplayID = 0
  var targetScaleFactor: CGFloat = 1.0
  var targetColorSpaceName: CFString? = nil
  var excludedWindowIDs: [CGWindowID] = []
  var onFrameReceived: (CVPixelBuffer, Double) -> Void = { _, _ in }
  private var capturing: Bool = false
  private var stream: SCStream?
  private var streamOutput: StreamOutput?
  private let streamQueue = DispatchQueue(label: "ScreenCaptureKitStreamQueue")

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    Logger.shared.log("ScreenCapture: Stream stopped with error: \(error.localizedDescription)")
    self.restartCapture()
  }

  func startCapture() {
    if self.capturing {
      return
    }
    self.capturing = true

    Task {
      do {
        let content = try await SCShareableContent.current

        Logger.shared.log("startCapture: Available displays from SCShareableContent:")
        for d in content.displays {
          Logger.shared.log("  - displayID: \(d.displayID), width: \(d.width), height: \(d.height)")
        }

        Logger.shared.log("startCapture: Available NSScreens:")
        for screen in NSScreen.screens {
          let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
          Logger.shared.log("  - displayID: \(displayID), frame: \(screen.frame), isMain: \(screen == NSScreen.main)")
        }

        guard let display = content.displays.first(where: { $0.displayID == self.targetDisplayID }) else {
          Logger.shared.log("startCapture: Target displayID \(self.targetDisplayID) not found in SCShareableContent, skipping capture.")
          self.capturing = false
          return
        }

        Logger.shared.log("startCapture: Selected display - displayID: \(display.displayID), width: \(display.width), height: \(display.height)")

        let excludedWindows = content.windows.filter { window in
          self.excludedWindowIDs.contains(window.windowID)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let scaleFactor = self.targetScaleFactor

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = Int(CGFloat(display.width) * scaleFactor)
        streamConfig.height = Int(CGFloat(display.height) * scaleFactor)
        Logger.shared.log("startCapture: Stream config - width: \(streamConfig.width), height: \(streamConfig.height), scaleFactor: \(scaleFactor)")
        streamConfig.minimumFrameInterval = CMTime(
          value: 1, timescale: CMTimeScale(self.config.targetFPS))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA

        if let csName = self.targetColorSpaceName {
          streamConfig.colorSpaceName = csName
          Logger.shared.log("startCapture: Set streamConfig.colorSpaceName=\(csName as String)")
        } else {
          Logger.shared.log("startCapture: No named colorspace provided; leaving streamConfig.colorSpaceName unset")
        }

        Logger.shared.log("startCapture: streamConfig.pixelFormat=\(streamConfig.pixelFormat)")

        streamConfig.capturesAudio = false
        streamConfig.showsCursor = false

        self.stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        self.streamOutput = StreamOutput(onFrameReceived: self.onFrameReceived)

        try self.stream!.addStreamOutput(
          self.streamOutput!, type: .screen, sampleHandlerQueue: self.streamQueue)

        try await self.stream!.startCapture()
        print("Started screen capture")
      } catch {
        print("Failed to start screen capture: \(error.localizedDescription)")
        self.capturing = false
      }
    }
  }

  func stopCapture() {
    if !self.capturing {
      return
    }
    self.capturing = false

    Task {
      do {
        try await self.stream?.stopCapture()
        self.stream = nil
        self.streamOutput = nil
        print("Stopped screen capture.")
      } catch {
        print("Failed to stop screen capture: \(error.localizedDescription)")
      }
    }
  }

  func setCapturing(_ capturing: Bool) {
    if capturing {
      self.startCapture()
    } else {
      self.stopCapture()
    }
  }

  func restartCapture() {
    stopCapture()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.startCapture()
    }
  }
}

private class StreamOutput: NSObject, SCStreamOutput {
  private let onFrameReceived: (CVPixelBuffer, Double) -> Void

  init(onFrameReceived: @escaping (CVPixelBuffer, Double) -> Void) {
    self.onFrameReceived = onFrameReceived
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen else { return }
    if let buffer = sampleBuffer.imageBuffer {
      let captureTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
      self.onFrameReceived(buffer, captureTime)
    }
  }
}
