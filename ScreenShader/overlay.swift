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

  private var targetScreen: NSScreen
  private var targetDisplayID: CGDirectDisplayID

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
    
    self.window.isOpaque = false
    self.window.backgroundColor = .clear
    self.window.hasShadow = false
    self.window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
    self.window.ignoresMouseEvents = true
    self.window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .transient]

    let metalView = MetalView(frame: contentRect)
    metalView.delegate = self
    metalView.wantsLayer = true
    metalView.isPaused = false
    metalView.enableSetNeedsDisplay = false
    self.window.contentView = metalView
    self.window.makeKeyAndOrderFront(nil)

    self.renderer = self.makeRenderer(metalLayer: metalView.metalLayer)

    self.screenCapture = ScreenCapture()
    self.screenCapture.config = self.config
    self.screenCapture.targetDisplayID = self.targetDisplayID
    self.screenCapture.targetScaleFactor = self.targetScreen.backingScaleFactor
    self.screenCapture.targetColorSpaceName = self.targetScreen.colorSpace?.cgColorSpace?.name
    self.screenCapture.excludedWindowIDs = [CGWindowID(self.window.windowNumber)]
    self.screenCapture.onFrameReceived = { [weak self] contentBuffer in
      self?.receiveFrame(contentBuffer: contentBuffer)
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
      captureTexturePixelFormat: captureTexturePixelFormat
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
      self.screenCapture.stopCapture()
      self.window.orderOut(nil)
      self.window = nil
  }

  func restartCapture() {
      self.screenCapture.restartCapture()
      self.window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
      self.window.orderFrontRegardless()
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
      
      if self.config.useCustomCursor && self.renderer.cursorTracker == nil {
          self.renderer.cursorTracker = CursorTracker(device: self.renderer.device)
      } else if !self.config.useCustomCursor {
          self.renderer.cursorTracker = nil
      }
      
      self.errorMessage.clear()
    } catch {
      print("Effect shader error: \(error.localizedDescription)")
      self.errorMessage.set(error.localizedDescription)
    }

    // TODO: The window is briefly visible with the previous effect applied.
    self.window.setIsVisible(active)
    self.screenCapture.setCapturing(active)

    if let metalView = self.window.contentView as? MetalView {
      metalView.isPaused = !active
    }
  }
}
