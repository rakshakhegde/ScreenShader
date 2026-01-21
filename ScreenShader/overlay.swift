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
  private var contentBuffer: CVPixelBuffer?
  private var frameID: Int?
  private let dispatchQueue = DispatchQueue(label: "overlayController.queue")

  init(config: Config, metrics: Metrics, errorMessage: ErrorMessage) {
    self.config = config
    self.metrics = metrics
    self.errorMessage = errorMessage
    super.init()

    guard let screen = NSScreen.main else {
      fatalError("No main screen found")
    }

    let contentRect = screen.frame

    self.window = NSWindow(
      contentRect: contentRect,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    self.window.isOpaque = false
    self.window.backgroundColor = .clear
    self.window.level = .screenSaver
    self.window.ignoresMouseEvents = true
    self.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let metalView = MetalView(frame: contentRect)
    metalView.delegate = self
    metalView.wantsLayer = true
    self.window.contentView = metalView
    self.window.makeKeyAndOrderFront(nil)

    self.renderer = self.makeRendererForCurrentScreen(metalLayer: metalView.metalLayer)

    self.screenCapture = ScreenCapture()
    self.screenCapture.config = self.config
    self.screenCapture.excludedWindowIDs = [CGWindowID(self.window.windowNumber)]
    self.screenCapture.onFrameReceived = { [weak self] contentBuffer in
      self?.receiveFrame(contentBuffer: contentBuffer)
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleScreenChange),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )

    // Handle sleep/wake - listen to multiple notifications
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(handleWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )

    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(handleScreensWake),
      name: NSWorkspace.screensDidWakeNotification,
      object: nil
    )

    // Also listen for app becoming active (might be more reliable)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidBecomeActive),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )

    // Log when screens sleep to confirm notifications work
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(handleScreensSleep),
      name: NSWorkspace.screensDidSleepNotification,
      object: nil
    )
  }

  private func usesSRGBTransfer(colorSpaceName: CFString?) -> Bool {
    guard let name = colorSpaceName else { return false }
    return name == CGColorSpace.sRGB
      || name == CGColorSpace.displayP3
      || name == CGColorSpace.extendedSRGB
      || name == CGColorSpace.extendedDisplayP3
  }

  private func makeRendererForCurrentScreen(metalLayer: CAMetalLayer) -> MetalRenderer {
    // Prefer the actual screen the window is on when available.
    let screen = self.window.screen ?? NSScreen.main

    // Fall back to sRGB if AppKit doesn't provide a color space.
    let screenColorSpace: CGColorSpace =
      (screen?.colorSpace?.cgColorSpace) ?? (CGColorSpace(name: CGColorSpace.sRGB)!)

    let colorSpaceName = screenColorSpace.name
    let wantsEDR = (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0
    let srgbTransfer = usesSRGBTransfer(colorSpaceName: colorSpaceName)

    let drawablePixelFormat: MTLPixelFormat = {
      if wantsEDR {
        return srgbTransfer ? .bgra10_xr_srgb : .bgra10_xr
      }
      return srgbTransfer ? .bgra8Unorm_srgb : .bgra8Unorm
    }()

    let captureTexturePixelFormat: MTLPixelFormat = srgbTransfer ? .bgra8Unorm_srgb : .bgra8Unorm

    let screenName = screen?.localizedName ?? "(unknown)"
    let csNameString = colorSpaceName.map { $0 as String } ?? "(nil)"
    Logger.shared.log(
      "display config: screen=\(screenName), colorSpaceName=\(csNameString), wantsEDR=\(wantsEDR), drawablePF=\(pixelFormatName(drawablePixelFormat)), captureTexPF=\(pixelFormatName(captureTexturePixelFormat))"
    )

    return MetalRenderer(
      metalLayer: metalLayer,
      drawablePixelFormat: drawablePixelFormat,
      colorspace: screenColorSpace,
      wantsEDR: wantsEDR,
      captureTexturePixelFormat: captureTexturePixelFormat
    )
  }
  
  func pixelFormatName(_ format: MTLPixelFormat) -> String {
      switch format {
      case .bgra8Unorm:       return ".bgra8Unorm"
      case .bgra8Unorm_srgb:  return ".bgra8Unorm_srgb"
      case .bgra10_xr:        return ".bgra10_xr"
      case .bgra10_xr_srgb:   return ".bgra10_xr_srgb"
      // add more cases as needed
      default:                return "unknown(\(format.rawValue))"
      }
  }

  @objc private func handleWake() {
    Logger.shared.log("handleWake: System woke from sleep")
    triggerRebuild()
  }

  @objc private func handleScreensWake() {
    Logger.shared.log("handleScreensWake: Screens woke up")
    lastScreenConfig = ""
    triggerRebuild()
  }

  @objc private func handleScreensSleep() {
    Logger.shared.log("handleScreensSleep: Screens going to sleep")
  }

  @objc private func handleAppDidBecomeActive() {
    Logger.shared.log("handleAppDidBecomeActive: App became active")
    triggerRebuild()
  }

  private func triggerRebuild() {
    // Reset config to force rebuild
    // Use debounced screen change handler
    handleScreenChange()
  }

  private var pendingScreenChange: DispatchWorkItem?
  private var lastScreenConfig: String = ""

  @objc private func handleScreenChange() {
    // Debounce: cancel pending and schedule new
    pendingScreenChange?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.applyScreenChange()
    }
    pendingScreenChange = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
  }

  private func applyScreenChange() {
    guard let screen = NSScreen.main else {
      Logger.shared.log("applyScreenChange: No main screen found")
      return
    }

    // Check if config actually changed
    let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    let newConfig = "\(displayID)-\(screen.frame)-\(screen.backingScaleFactor)"
    
    Logger.shared.log("applyScreenChange: lastScreenConfig: \(lastScreenConfig);; newConfig: \(newConfig)")
    
    if newConfig == lastScreenConfig {
      Logger.shared.log("applyScreenChange: Config unchanged, skipping")
      return
    }
    lastScreenConfig = newConfig

    Logger.shared.log("applyScreenChange: displayID=\(displayID), frame=\(screen.frame), scale=\(screen.backingScaleFactor)")

    // Stop capture first
    screenCapture.stopCapture()

    // Recreate Metal view fresh for the new screen
    let contentRect = screen.frame

    let metalView = MetalView(frame: contentRect)
    metalView.delegate = self
    metalView.wantsLayer = true
    metalView.isPaused = false
    metalView.enableSetNeedsDisplay = false  // Use internal display link

    // Update window
    window.contentView = metalView
    window.setFrame(contentRect, display: true)

    // Recreate renderer for the new Metal layer (match current display)
    self.renderer = self.makeRendererForCurrentScreen(metalLayer: metalView.metalLayer)

    // Reapply current effect
    let activeEffect = self.config.effects.getActiveEffect()
    if let effect = activeEffect {
      let shader = self.config.effects.getShader(effect: effect)
      try? self.renderer.setEffectSource(shader)
    }

    // Restart capture
    screenCapture.excludedWindowIDs = [CGWindowID(self.window.windowNumber)]
    screenCapture.startCapture()

    // Re-assert window properties (may be lost after sleep/wake)
    window.level = .screenSaver
    window.isOpaque = false
    window.backgroundColor = .clear
    window.orderFrontRegardless()

    Logger.shared.log("applyScreenChange: Rebuilt Metal view and renderer, re-asserted window properties")
  }

  func receiveFrame(contentBuffer: CVPixelBuffer) {
    let frameID = self.metrics.newFrameID()
    self.metrics.recordScreenCapture(frameID: frameID)

    self.dispatchQueue.async {
      self.frameID = frameID
      self.contentBuffer = contentBuffer
    }

    // self.render()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    self.render()
  }

  func render() {
    var contentBuffer: CVPixelBuffer?
    var frameID: Int?

    self.dispatchQueue.sync {
        contentBuffer = self.contentBuffer
        frameID = self.frameID
        self.frameID = nil
        self.contentBuffer = nil
    }
    
    if let contentBuffer = contentBuffer, let frameID = frameID {
      self.renderer.renderContentBuffer(window: self.window, contentBuffer: contentBuffer)
      self.metrics.recordRender(frameID: frameID)
    }
  }

  func refreshConfig() {
    let activeEffect = self.config.effects.getActiveEffect()
    let active = activeEffect != nil

    let activeEffectShader = active ? self.config.effects.getShader(effect: activeEffect!) : nil

    do {
      try self.renderer.setEffectSource(activeEffectShader)
      self.errorMessage.clear()
    } catch {
      print("Effect shader error: \(error.localizedDescription)")
      self.errorMessage.set(error.localizedDescription)
    }

    // TODO: The window is briefly visible with the previous effect applied.
    // self.window.setIsVisible(active)
    // self.screenCapture.setCapturing(active)

    self.window.setIsVisible(true)
    self.screenCapture.setCapturing(true)
  }
}
