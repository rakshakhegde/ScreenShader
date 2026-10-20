import AppKit
import CoreGraphics
import Metal
import MetalKit

class OverlayController: NSObject, MTKViewDelegate {
  private var config: Config
  private var metrics: Metrics
  private var errorMessage: ErrorMessage
  private var window: NSWindow!
  private var screenCapture: ScreenCapture!
  private var renderer: MetalRenderer!
  private var displayLink: CVDisplayLink?
  private var contentBuffer: CVPixelBuffer?
  private var frameID: Int?
  private var lastRenderedMouseLocation: NSPoint?
  private var lastRenderTime: Double = CACurrentMediaTime()
  private var renderFrameCount: Int = 0
  private let dispatchQueue = DispatchQueue(label: "overlayController.queue")

  private var targetScreen: NSScreen
  private var targetDisplayID: CGDirectDisplayID

  var onCompilationError: ((UUID) -> Void)?

  init(targetScreen: NSScreen, targetDisplayID: CGDirectDisplayID, config: Config, metrics: Metrics, errorMessage: ErrorMessage) {
    self.targetScreen = targetScreen
    self.targetDisplayID = targetDisplayID
    self.config = config
    self.metrics = metrics
    self.errorMessage = errorMessage
    super.init()

    let contentRect = self.targetScreen.frame

    self.window = NSPanel(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    let panel = self.window as! NSPanel
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    
    self.window.isOpaque = true
    self.window.backgroundColor = .black
    self.window.hasShadow = false
    self.window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
//    self.window.level = .normal
    self.window.ignoresMouseEvents = true
    self.window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

    let metalView = MetalView(frame: contentRect)
    metalView.delegate = self
    metalView.wantsLayer = true
    metalView.isPaused = true // Pause internal timer
    metalView.enableSetNeedsDisplay = false
    self.window.contentView = metalView

    self.renderer = self.makeRenderer(metalLayer: metalView.metalLayer)

    // Bypass macOS MTKView throttling using a raw CVDisplayLink bound to the display
    CVDisplayLinkCreateWithCGDisplay(self.targetDisplayID, &self.displayLink)
    if let displayLink = self.displayLink {
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkSetOutputCallback(displayLink, { (_, _, _, _, _, userInfo) -> CVReturn in
            if let userInfo = userInfo {
                let controller = Unmanaged<OverlayController>.fromOpaque(userInfo).takeUnretainedValue()
                controller.render()
            }
            return kCVReturnSuccess
        }, userInfo)
        CVDisplayLinkStart(displayLink)
    }

    self.screenCapture = ScreenCapture()
    self.screenCapture.config = self.config
    self.screenCapture.targetDisplayID = self.targetDisplayID
    self.screenCapture.targetScaleFactor = self.targetScreen.backingScaleFactor
    self.screenCapture.targetColorSpaceName = self.targetScreen.colorSpace?.cgColorSpace?.name
    self.screenCapture.excludedWindowIDs = [CGWindowID(self.window.windowNumber)]
    self.screenCapture.onFrameReceived = { [weak self] contentBuffer, captureTime in
      self?.receiveFrame(contentBuffer: contentBuffer, captureTime: captureTime)
    }
    self.screenCapture.onCaptureFailed = { [weak self] in
      guard let self = self else { return }
      Logger.shared.log("OverlayController[display \(self.targetDisplayID)]: Capture failed/halted - turning off effect overlay for this display.")
      self.window?.orderOut(nil)
    }
    self.screenCapture.onCaptureRestored = { [weak self] in
      guard let self = self else { return }
      if self.config.effects.anyEffectActive() && self.errorMessage.get() == nil {
        Logger.shared.log("OverlayController[display \(self.targetDisplayID)]: Capture restored - revealing effect overlay.")
        self.window?.orderFrontRegardless()
      }
    }
  }

  private func usesSRGBTransfer(colorSpaceName: CFString?) -> Bool {
    guard let name = colorSpaceName else { return false }
    return name == CGColorSpace.sRGB
      || name == CGColorSpace.displayP3
      || name == CGColorSpace.extendedSRGB
      || name == CGColorSpace.extendedDisplayP3
  }

  private func makeRenderer(metalLayer: CAMetalLayer) -> MetalRenderer {
    let screenColorSpace: CGColorSpace =
      (self.targetScreen.colorSpace?.cgColorSpace) ?? (CGColorSpace(name: CGColorSpace.sRGB)!)

    let colorSpaceName = screenColorSpace.name
    let wantsEDR = (self.targetScreen.maximumPotentialExtendedDynamicRangeColorComponentValue) > 1.0
    let srgbTransfer = usesSRGBTransfer(colorSpaceName: colorSpaceName)

    let drawablePixelFormat: MTLPixelFormat = {
      if wantsEDR {
        return srgbTransfer ? .bgra10_xr_srgb : .bgra10_xr
      }
      return srgbTransfer ? .bgra8Unorm_srgb : .bgra8Unorm
    }()

    let captureTexturePixelFormat: MTLPixelFormat = srgbTransfer ? .bgra8Unorm_srgb : .bgra8Unorm

    let screenName = self.targetScreen.localizedName
    let csNameString = colorSpaceName.map { $0 as String } ?? "(nil)"
    Logger.shared.log(
      "display config: screen=\(screenName), colorSpaceName=\(csNameString), wantsEDR=\(wantsEDR), drawablePF=\(pixelFormatName(drawablePixelFormat)), captureTexPF=\(pixelFormatName(captureTexturePixelFormat))"
    )

    return MetalRenderer(
      metalLayer: metalLayer,
      drawablePixelFormat: drawablePixelFormat,
      colorspace: screenColorSpace,
      wantsEDR: wantsEDR,
      captureTexturePixelFormat: captureTexturePixelFormat,
      backingScaleFactor: self.targetScreen.backingScaleFactor,
      screenFrame: self.targetScreen.frame
    )
  }
  
  func pixelFormatName(_ format: MTLPixelFormat) -> String {
      switch format {
      case .bgra8Unorm:       return ".bgra8Unorm"
      case .bgra8Unorm_srgb:  return ".bgra8Unorm_srgb"
      case .bgra10_xr:        return ".bgra10_xr"
      case .bgra10_xr_srgb:   return ".bgra10_xr_srgb"
      default:                return "unknown(\(format.rawValue))"
      }
  }

  func stopAndTearDown() {
      if let displayLink = self.displayLink {
          CVDisplayLinkStop(displayLink)
          self.displayLink = nil
      }
      self.screenCapture.stopCapture()
      self.window?.orderOut(nil)
      self.window = nil
  }

  deinit {
      if let displayLink = self.displayLink {
          CVDisplayLinkStop(displayLink)
      }
  }

  func pause() {
      if let displayLink = self.displayLink, CVDisplayLinkIsRunning(displayLink) {
          CVDisplayLinkStop(displayLink)
      }
      self.screenCapture.stopCapture()
  }

  func restartCapture() {
      guard self.config.effects.anyEffectActive() && self.errorMessage.get() == nil else { return }
      if let displayLink = self.displayLink, !CVDisplayLinkIsRunning(displayLink) {
          CVDisplayLinkStart(displayLink)
      }
      self.screenCapture.restartCapture()
      self.window?.orderFrontRegardless()
  }

  func receiveFrame(contentBuffer: CVPixelBuffer, captureTime: Double) {
    let frameID = self.metrics.newFrameID()
    self.metrics.recordScreenCapture(frameID: frameID, captureTime: captureTime)

    self.dispatchQueue.async {
      self.frameID = frameID
      self.contentBuffer = contentBuffer
    }

    // self.render()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    // Rendering is driven exclusively by CVDisplayLink on a background thread.
  }

  func render() {
    autoreleasepool {
      var contentBufferToRender: CVPixelBuffer?
      var frameIDToRender: Int?

      self.dispatchQueue.sync {
          contentBufferToRender = self.contentBuffer
          frameIDToRender = self.frameID
          // Clear frameID immediately so concurrent CVDisplayLink threads don't double-render
          self.frameID = nil
      }

      guard let contentBuffer = contentBufferToRender,
            let renderer = self.renderer else {
        return
      }

      if frameIDToRender == nil {
        guard renderer.cursorTracker != nil else {
          return
        }
        let cgLoc = CGEvent(source: CGEventSource(stateID: .hidSystemState))?.location ?? .zero
        let mainScreenHeight = CGDisplayBounds(CGMainDisplayID()).height
        let globalMouse = NSPoint(x: cgLoc.x, y: CGFloat(mainScreenHeight) - cgLoc.y)

        // Skip render if the mouse is outside this display, or if mouse hasn't moved since last render
        let screenBounds = self.targetScreen.frame.insetBy(dx: -2.0, dy: -2.0)
        if !screenBounds.contains(globalMouse) || globalMouse == self.lastRenderedMouseLocation {
          return
        }
      }

      let cgLoc = CGEvent(source: CGEventSource(stateID: .hidSystemState))?.location ?? .zero
      let mainScreenHeight = CGDisplayBounds(CGMainDisplayID()).height
      self.lastRenderedMouseLocation = NSPoint(x: cgLoc.x, y: CGFloat(mainScreenHeight) - cgLoc.y)

      renderer.renderContentBuffer(contentBuffer: contentBuffer)
      if let frameID = frameIDToRender {
          let now = CACurrentMediaTime()
          self.lastRenderTime = now
          self.renderFrameCount += 1
          // Commented out render gap log to prevent disk write saturation
          // if dt > 0.05 && self.renderFrameCount > 5 {
          //   Logger.shared.log("OverlayController[display \(self.targetDisplayID)] render GAP: \(Int(dt * 1000))ms! renderCount=\(self.renderFrameCount)")
          // }
          self.metrics.recordRender(frameID: frameID)
      }
    }
  }

  func refreshConfig() {
    let activeEffects = self.config.effects.getActiveEffects()
    let active = !activeEffects.isEmpty

    let activeSources: [(id: UUID, source: String)] = activeEffects.map {
      ($0, self.config.effects.getShader(effect: $0))
    }

    var compilationFailed = false
    do {
      try self.renderer.setEffectSources(activeSources)
      
      if self.config.useCustomCursor && self.renderer.cursorTracker == nil {
          self.renderer.cursorTracker = CursorTracker(device: self.renderer.device)
      } else if !self.config.useCustomCursor {
          self.renderer.cursorTracker = nil
      }
      self.renderer.customCursorScale = self.config.customCursorScale
      
      self.errorMessage.clear()
    } catch let error as ShaderCompilationError {
      compilationFailed = true
      print("Effect shader error: \(error.localizedDescription)")
      self.errorMessage.set(error.localizedDescription)
      self.onCompilationError?(error.effectID)
      CursorHider.shared.stopHiding()
    } catch {
      compilationFailed = true
      print("Effect shader error: \(error.localizedDescription)")
      self.errorMessage.set(error.localizedDescription)
      CursorHider.shared.stopHiding()
    }

    let shouldShow = active && !compilationFailed

    // If compilation succeeded and we should show the effect with custom cursor, ensure cursor hiding starts
    if shouldShow && self.config.useCustomCursor {
      CursorHider.shared.startHiding()
    }

    if shouldShow {
      if !self.window.isVisible {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
          guard let self = self else { return }
          if self.config.effects.anyEffectActive() && self.errorMessage.get() == nil {
            self.window?.setIsVisible(true)
          }
        }
      }
    } else {
      self.window.setIsVisible(false)
    }
    self.screenCapture.setCapturing(shouldShow)

    if let displayLink = self.displayLink {
      if shouldShow && !CVDisplayLinkIsRunning(displayLink) {
        CVDisplayLinkStart(displayLink)
      } else if !shouldShow && CVDisplayLinkIsRunning(displayLink) {
        CVDisplayLinkStop(displayLink)
      }
    }
  }
}
