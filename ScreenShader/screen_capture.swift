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
  var onCaptureFailed: (() -> Void)? = nil
  var onCaptureRestored: (() -> Void)? = nil

  private var capturing: Bool = false
  private var stream: SCStream?
  private var streamOutput: StreamOutput?
  private let streamQueue = DispatchQueue(label: "ScreenCaptureKitStreamQueue")
  private var retryTimer: Timer?
  private var isStarting: Bool = false
  private var activeStopTask: Task<Void, Never>?

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    Logger.shared.log("ScreenCapture[display \(targetDisplayID)]: Stream stopped with error: \(error.localizedDescription)")
    self.handleCaptureFailure()
  }

  private func handleCaptureFailure() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.onCaptureFailed?()
      self.scheduleRetry()
    }
  }

  private func scheduleRetry() {
    guard self.capturing else { return }
    if self.retryTimer != nil { return }

    Logger.shared.log("ScreenCapture[display \(self.targetDisplayID)]: Scheduling background retry every 2 seconds...")
    let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
      guard let self = self else {
        timer.invalidate()
        return
      }
      guard self.capturing else {
        timer.invalidate()
        self.retryTimer = nil
        return
      }

      Logger.shared.log("ScreenCapture[display \(self.targetDisplayID)]: Retrying display detection in background...")
      let targetDisplayID = self.targetDisplayID
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        do {
          let content = try await SCShareableContent.current
          guard self.capturing else { return }
          if content.displays.contains(where: { $0.displayID == targetDisplayID }) {
            self.retryTimer?.invalidate()
            self.retryTimer = nil
            Logger.shared.log("ScreenCapture[display \(targetDisplayID)]: Target display reappeared! Restarting capture...")
            self.executeStartCapture()
          }
        } catch {
          // Keep retrying on next interval
        }
      }
    }
    self.retryTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func startCapture() {
    if self.capturing {
      return
    }
    self.capturing = true
    self.executeStartCapture()
  }

  private func executeStartCapture() {
    guard !self.isStarting && self.capturing else { return }
    self.isStarting = true

    let targetDisplayID = self.targetDisplayID
    let scaleFactor = self.targetScaleFactor
    let colorSpaceName = self.targetColorSpaceName
    let excludedIDs = self.excludedWindowIDs
    let targetFPS = self.config.targetFPS

    Task { @MainActor [weak self] in
      guard let self = self else { return }
      do {
        let content = try await SCShareableContent.current
        guard self.capturing else {
          self.isStarting = false
          return
        }

        guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
          Logger.shared.log("ScreenCapture[display \(targetDisplayID)]: Target display not found in SCShareableContent. Available IDs: \(content.displays.map { $0.displayID })")
          self.isStarting = false
          self.handleCaptureFailure()
          return
        }

        let excludedWindows = content.windows.filter { excludedIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = Int(CGFloat(display.width) * scaleFactor)
        streamConfig.height = Int(CGFloat(display.height) * scaleFactor)
        streamConfig.minimumFrameInterval = CMTime(
          value: 1, timescale: CMTimeScale(targetFPS))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.queueDepth = 5

        if let csName = colorSpaceName {
          streamConfig.colorSpaceName = csName
        }

        streamConfig.capturesAudio = false
        streamConfig.showsCursor = false

        Logger.shared.log("ScreenCapture[display \(targetDisplayID)]: Starting capture (\(streamConfig.width)x\(streamConfig.height) @ \(scaleFactor)x)")

        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        let output = StreamOutput(displayID: targetDisplayID, onFrameReceived: { [weak self] buffer, time in
          self?.onFrameReceived(buffer, time)
        })

        try newStream.addStreamOutput(
          output, type: .screen, sampleHandlerQueue: self.streamQueue)

        try await newStream.startCapture()

        guard self.capturing else {
          self.isStarting = false
          Task {
            try? await newStream.stopCapture()
          }
          return
        }

        self.stream = newStream
        self.streamOutput = output
        self.isStarting = false

        Logger.shared.log("ScreenCapture[display \(targetDisplayID)]: Stream capture started successfully.")

        self.retryTimer?.invalidate()
        self.retryTimer = nil
        self.onCaptureRestored?()
      } catch {
        Logger.shared.log("ScreenCapture[display \(targetDisplayID)]: Failed to start screen capture: \(error.localizedDescription)")
        self.isStarting = false
        self.handleCaptureFailure()
      }
    }
  }

  func stopCapture(completion: (() -> Void)? = nil) {
    self.capturing = false
    self.retryTimer?.invalidate()
    self.retryTimer = nil

    guard let currentStream = self.stream else {
      self.streamOutput = nil
      completion?()
      return
    }
    self.stream = nil
    self.streamOutput = nil

    let displayID = self.targetDisplayID
    let task = Task {
      do {
        try await currentStream.stopCapture()
        Logger.shared.log("ScreenCapture[display \(displayID)]: Stream stopped cleanly.")
      } catch let error as NSError where error.domain == SCStreamErrorDomain && error.code == -3808 {
        // SCStreamErrorAttemptToStopStreamState (-3808): already stopped or in stopping state; safe to ignore
      } catch {
        Logger.shared.log("ScreenCapture[display \(displayID)]: Stop capture error: \(error.localizedDescription)")
      }
      DispatchQueue.main.async {
        completion?()
      }
    }
    self.activeStopTask = task
  }

  func setCapturing(_ capturing: Bool) {
    if capturing {
      self.startCapture()
    } else {
      self.stopCapture()
    }
  }

  func restartCapture() {
    self.stopCapture { [weak self] in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self?.startCapture()
      }
    }
  }
}

private class StreamOutput: NSObject, SCStreamOutput {
  private let displayID: CGDirectDisplayID
  private let onFrameReceived: (CVPixelBuffer, Double) -> Void

  init(displayID: CGDirectDisplayID, onFrameReceived: @escaping (CVPixelBuffer, Double) -> Void) {
    self.displayID = displayID
    self.onFrameReceived = onFrameReceived
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen else { return }

    // Per-frame log commented out to prevent disk write saturation (gigabytes of log data)
    // Logger.shared.log("StreamOutput[display \(displayID)] FRAME ...")

    if let buffer = sampleBuffer.imageBuffer {
      let captureTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
      self.onFrameReceived(buffer, captureTime)
    }
  }
}
