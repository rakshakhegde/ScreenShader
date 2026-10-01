import AppKit
import CoreGraphics
import Metal
import MetalKit
import ApplicationServices

class MetalView: MTKView {
  var metalLayer: CAMetalLayer {
    return self.layer as! CAMetalLayer
  }
  override func makeBackingLayer() -> CALayer {
    return CAMetalLayer()
  }
}

class MetalRenderer {
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private var textureCache: CVMetalTextureCache!
  
  private var activeEffectSource: String? = nil
  private var renderPipeline: MTLRenderPipelineState? = nil
  
  private var passthroughPipeline: MTLRenderPipelineState? = nil
  private var cursorPipeline: MTLRenderPipelineState? = nil
  var cursorTracker: CursorTracker? = nil
  private var cursorTextures: [String: MTLTexture] = [:]
  
  private var intermediateTexture: MTLTexture? = nil

  private let renderTargetPixelFormat: MTLPixelFormat
  private let captureTexturePixelFormat: MTLPixelFormat

  init(
    metalLayer: CAMetalLayer,
    drawablePixelFormat: MTLPixelFormat,
    colorspace: CGColorSpace,
    wantsEDR: Bool,
    captureTexturePixelFormat: MTLPixelFormat
  ) {
    guard let device = MTLCreateSystemDefaultDevice() else {
      fatalError("Unable to access a Metal device on this system.")
    }
    self.device = device

    guard let queue = self.device.makeCommandQueue() else {
      fatalError("Could not create command queue.")
    }
    self.commandQueue = queue

    self.renderTargetPixelFormat = drawablePixelFormat
    self.captureTexturePixelFormat = captureTexturePixelFormat

    metalLayer.device = self.device
    metalLayer.pixelFormat = drawablePixelFormat
    metalLayer.colorspace = colorspace
    metalLayer.wantsExtendedDynamicRangeContent = wantsEDR
    metalLayer.framebufferOnly = true
    metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 1.0
    metalLayer.isOpaque = false
    metalLayer.backgroundColor = NSColor.clear.cgColor

    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, self.device, nil, &cache)
    if let createdCache = cache {
      self.textureCache = createdCache
    } else {
      fatalError("Could not create CVMetalTextureCache.")
    }
    
    do {
      self.passthroughPipeline = try Self.buildPassthroughPipeline(device: self.device, pixelFormat: captureTexturePixelFormat)
      self.cursorPipeline = try Self.buildCursorRenderPipeline(device: self.device, pixelFormat: captureTexturePixelFormat)
    } catch {
      print("Failed to build base pipelines: \(error)")
    }
  }

  static func buildRenderPipeline(
    device: MTLDevice,
    effectSource: String,
    pixelFormat: MTLPixelFormat
  ) throws -> MTLRenderPipelineState {
    let librarySource = """
      #include <metal_stdlib>
      using namespace metal;

      struct TextureWrapper {
        texture2d<float> tex;
        float2 screenSize;

        float4 sample(sampler s, float2 coord) const {
          float2 pixelOffset = 2.0 / screenSize;
          float2 insetCoord = clamp(coord, pixelOffset, 1.0 - pixelOffset);
          return tex.sample(s, insetCoord);
        }
      };

      struct ShaderInput {
        TextureWrapper inputTexture;
        float2 texCoord;
        float2 screenPosition;
        float2 screenSize;
        float2 mousePosition;
        float time;
      };

      float2 texToScreen(float2 texCoord, float2 screenSize) {
        return float2(texCoord.x * screenSize.x, (1 - texCoord.y) * screenSize.y);
      }

      float2 screenToTex(float2 screenPosition, float2 screenSize) {
        return float2(screenPosition.x / screenSize.x, 1 - screenPosition.y / screenSize.y);
      }

      \(effectSource)

      struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
      };

      vertex VertexOut vertex_main(uint vertexId [[vertex_id]]) {
        float2 quadVertices[6] = {
          float2(-1.0, -1.0),
          float2( 1.0, -1.0),
          float2(-1.0,  1.0),
          float2(-1.0,  1.0),
          float2( 1.0, -1.0),
          float2( 1.0,  1.0)
        };

        VertexOut out;
        out.position = float4(quadVertices[vertexId], 0.0, 1.0);
        out.texCoord = float2(
          (quadVertices[vertexId].x + 1.0) * 0.5,
          (-quadVertices[vertexId].y + 1.0) * 0.5);
        return out;
      }

      fragment float4 fragment_main(
        VertexOut in [[stage_in]],
        texture2d<float> inTexture [[texture(0)]],
        constant float2 *screenSize [[buffer(0)]],
        constant float2 *mousePosition [[buffer(1)]],
        constant float *time [[buffer(2)]]
      ) {
        ShaderInput shaderInput;
        shaderInput.inputTexture = TextureWrapper{inTexture, *screenSize};
        shaderInput.texCoord = in.texCoord;
        shaderInput.screenPosition = texToScreen(in.texCoord, *screenSize);
        shaderInput.screenSize = *screenSize;
        shaderInput.mousePosition = *mousePosition;
        shaderInput.time = *time;

        return shaderFunction(shaderInput);
      }
    """

    let library = try device.makeLibrary(source: librarySource, options: nil)
    let vertexFunction = library.makeFunction(name: "vertex_main")
    let fragmentFunction = library.makeFunction(name: "fragment_main")

    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = vertexFunction
    pipelineDescriptor.fragmentFunction = fragmentFunction
    pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat

    return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
  }
  
  static func buildPassthroughPipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
    let librarySource = """
      #include <metal_stdlib>
      using namespace metal;
      
      struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
      };
      
      vertex VertexOut pt_vertex_main(uint vertexId [[vertex_id]]) {
        float2 quadVertices[6] = {
          float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
          float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)
        };
        VertexOut out;
        out.position = float4(quadVertices[vertexId], 0.0, 1.0);
        out.texCoord = float2((quadVertices[vertexId].x + 1.0) * 0.5, (-quadVertices[vertexId].y + 1.0) * 0.5);
        return out;
      }
      
      fragment float4 pt_fragment_main(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        return tex.sample(s, in.texCoord);
      }
    """
    let library = try device.makeLibrary(source: librarySource, options: nil)
    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = library.makeFunction(name: "pt_vertex_main")
    pipelineDescriptor.fragmentFunction = library.makeFunction(name: "pt_fragment_main")
    pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
    return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
  }
  
  static func buildCursorRenderPipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
    let librarySource = """
      #include <metal_stdlib>
      using namespace metal;
      
      struct CursorVertexOut {
        float4 position [[position]];
        float2 texCoord;
      };
      
      vertex CursorVertexOut cursor_vertex_main(uint vertexId [[vertex_id]], constant float2 *quadVertices [[buffer(0)]], constant float2 *texCoords [[buffer(1)]]) {
        CursorVertexOut out;
        out.position = float4(quadVertices[vertexId], 0.0, 1.0);
        out.texCoord = texCoords[vertexId];
        return out;
      }
      
      fragment float4 cursor_fragment_main(CursorVertexOut in [[stage_in]], texture2d<float> cursorTexture [[texture(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        return cursorTexture.sample(s, in.texCoord);
      }
    """
    let library = try device.makeLibrary(source: librarySource, options: nil)
    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = library.makeFunction(name: "cursor_vertex_main")
    pipelineDescriptor.fragmentFunction = library.makeFunction(name: "cursor_fragment_main")
    pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
    
    // Enable alpha blending
    pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
    pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
    pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    
    return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
  }

  private func getCursorTexture(cursor: NSCursor) -> MTLTexture? {
    let key = "\(cursor.hash)"
    if let tex = cursorTextures[key] { return tex }
    
    guard let tiffData = cursor.image.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData) else { return nil }
    
    let width = bitmapRep.pixelsWide
    let height = bitmapRep.pixelsHigh
    guard width > 0 && height > 0 else { return nil }
    
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    
    let bytesPerRow = bitmapRep.bytesPerRow
    if let data = bitmapRep.bitmapData {
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        cursorTextures[key] = texture
        return texture
    }
    return nil
  }

  func setEffectSource(_ effectSource: String?) throws {
    guard let effectSource = effectSource else {
      self.activeEffectSource = nil
      self.renderPipeline = nil
      return
    }
    self.activeEffectSource = effectSource
    do {
      self.renderPipeline = try Self.buildRenderPipeline(
        device: self.device,
        effectSource: effectSource,
        pixelFormat: self.renderTargetPixelFormat
      )
    } catch {
      self.renderPipeline = nil
      throw error
    }
  }

  func renderContentBuffer(window: NSWindow, contentBuffer: CVPixelBuffer) {
    guard let metalView = window.contentView as? MetalView,
          let drawable = metalView.metalLayer.nextDrawable() else {
      return
    }

    let width = CVPixelBufferGetWidth(contentBuffer)
    let height = CVPixelBufferGetHeight(contentBuffer)

    var tempTextureRef: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault,
      self.textureCache,
      contentBuffer,
      nil,
      self.captureTexturePixelFormat,
      width,
      height,
      0,
      &tempTextureRef)

    guard status == kCVReturnSuccess, let textureRef = tempTextureRef,
      let texture = CVMetalTextureGetTexture(textureRef)
    else {
      return
    }
    
    if intermediateTexture?.width != width || intermediateTexture?.height != height {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: self.captureTexturePixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        self.intermediateTexture = self.device.makeTexture(descriptor: desc)
    }
    
    guard let intermediateTexture = self.intermediateTexture,
          let commandBuffer = self.commandQueue.makeCommandBuffer() else {
      return
    }

    let pass1Descriptor = MTLRenderPassDescriptor()
    pass1Descriptor.colorAttachments[0].texture = intermediateTexture
    pass1Descriptor.colorAttachments[0].loadAction = .dontCare
    pass1Descriptor.colorAttachments[0].storeAction = .store
    
    if let encoder1 = commandBuffer.makeRenderCommandEncoder(descriptor: pass1Descriptor) {
        if let screen = window.screen {
            if let ptPipeline = self.passthroughPipeline {
                encoder1.setRenderPipelineState(ptPipeline)
                encoder1.setFragmentTexture(texture, index: 0)
                encoder1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            
            if let cursorPipeline = self.cursorPipeline, let tracker = self.cursorTracker {
                let cursorType = tracker.currentCursorType()
                let cursor = cursorType.cursor
                if let cursorTex = getCursorTexture(cursor: cursor) {
                    let globalMouse = NSEvent.mouseLocation
                    let mx = Float(globalMouse.x - screen.frame.origin.x)
                    let my = Float(globalMouse.y - screen.frame.origin.y)
                    let sw = Float(screen.frame.width)
                    let sh = Float(screen.frame.height)
                    
                    let cw_points = Float(cursor.image.size.width)
                    let ch_points = Float(cursor.image.size.height)
                    let hsX = Float(cursor.hotSpot.x)
                    let hsY = Float(cursor.hotSpot.y)
                    
                    let ndcWidth = 2.0 / sw
                    let ndcHeight = 2.0 / sh
                    
                    let left = (mx - hsX) * ndcWidth - 1.0
                    let right = (mx - hsX + cw_points) * ndcWidth - 1.0
                    
                    let top = (my + hsY) * ndcHeight - 1.0
                    let bottom = (my + hsY - ch_points) * ndcHeight - 1.0
                    
                    var quadVertices: [vector_float2] = [
                        vector_float2(left, bottom),
                        vector_float2(right, bottom),
                        vector_float2(left, top),
                        vector_float2(left, top),
                        vector_float2(right, bottom),
                        vector_float2(right, top)
                    ]
                    
                    var texCoords: [vector_float2] = [
                        vector_float2(0, 1),
                        vector_float2(1, 1),
                        vector_float2(0, 0),
                        vector_float2(0, 0),
                        vector_float2(1, 1),
                        vector_float2(1, 0)
                    ]
                    
                    encoder1.setRenderPipelineState(cursorPipeline)
                    encoder1.setFragmentTexture(cursorTex, index: 0)
                    encoder1.setVertexBytes(&quadVertices, length: MemoryLayout<vector_float2>.stride * 6, index: 0)
                    encoder1.setVertexBytes(&texCoords, length: MemoryLayout<vector_float2>.stride * 6, index: 1)
                    encoder1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                }
            }
        }
        encoder1.endEncoding()
    }
    
    let pass2Descriptor = MTLRenderPassDescriptor()
    pass2Descriptor.colorAttachments[0].texture = drawable.texture
    pass2Descriptor.colorAttachments[0].loadAction = .clear
    pass2Descriptor.colorAttachments[0].storeAction = .store
    pass2Descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    
    if let encoder2 = commandBuffer.makeRenderCommandEncoder(descriptor: pass2Descriptor) {
        if let screen = window.screen {
            if let renderPipeline = self.renderPipeline {
                var screenSize = vector_float2(Float(screen.frame.width), Float(screen.frame.height))
                let globalMouse = NSEvent.mouseLocation
                var mousePosition = vector_float2(
                  Float(globalMouse.x - screen.frame.origin.x), 
                  Float(globalMouse.y - screen.frame.origin.y))
                var time = Float(ProcessInfo.processInfo.systemUptime)

                encoder2.setRenderPipelineState(renderPipeline)
                encoder2.setFragmentTexture(intermediateTexture, index: 0)
                encoder2.setFragmentBytes(&screenSize, length: MemoryLayout<vector_float2>.stride, index: 0)
                encoder2.setFragmentBytes(
                  &mousePosition, length: MemoryLayout<vector_float2>.stride, index: 1)
                encoder2.setFragmentBytes(&time, length: MemoryLayout<Float>.stride, index: 2)

                encoder2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }
        encoder2.endEncoding()
    }

    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  func updateScaleFactor(metalLayer: CAMetalLayer) {
    metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 1.0
  }

  func flushTextureCache() {
    CVMetalTextureCacheFlush(self.textureCache, 0)
  }
}

class CursorTracker {
    enum CursorType: String {
        case arrow = "arrow"
        case text = "text"
        case pointer = "pointer"
        case crosshair = "crosshair"
        case openHand = "open-hand"
        case closedHand = "closed-hand"
        case resizeEW = "resize-ew"
        case resizeNS = "resize-ns"
        case notAllowed = "not-allowed"
        
        var cursor: NSCursor {
            switch self {
            case .arrow: return .arrow
            case .text: return .iBeam
            case .pointer: return .pointingHand
            case .crosshair: return .crosshair
            case .openHand: return .openHand
            case .closedHand: return .closedHand
            case .resizeEW: return .resizeLeftRight
            case .resizeNS: return .resizeUpDown
            case .notAllowed: return .operationNotAllowed
            }
        }
    }

    private let signatureAcceptanceThreshold = 12000
    private let relaxedSignatureAcceptanceThresholds: [String: Int] = [
        "text": 28000,
        "crosshair": 32000,
    ]
    private let strictSignatureAcceptanceThresholds: [String: Int] = [
        "open-hand": 3200,
        "closed-hand": 3200,
    ]

    private let systemWideElement = AXUIElementCreateSystemWide()
    private let totalScreenHeight = NSScreen.screens.reduce(CGFloat(0)) { max($0, $1.frame.maxY) }
    private let axEditableAttribute = "AXEditable"
    private let axLinkRole = "AXLink"

    private struct CursorSignature {
        let aspectRatio: Double
        let hotspotXRatio: Double
        let hotspotYRatio: Double
        let shapeSamples: [UInt8]
    }

    private lazy var knownCursorSignatures: [(String, CursorSignature)] = {
        var candidates: [(String, NSCursor)] = [
            ("arrow", .arrow),
            ("text", .iBeam),
            ("pointer", .pointingHand),
            ("pointer", .dragCopy),
            ("pointer", .dragLink),
            ("pointer", .contextualMenu),
            ("crosshair", .crosshair),
            ("open-hand", .openHand),
            ("closed-hand", .closedHand),
            ("resize-ew", .resizeLeft),
            ("resize-ew", .resizeRight),
            ("resize-ew", .resizeLeftRight),
            ("resize-ns", .resizeUp),
            ("resize-ns", .resizeDown),
            ("resize-ns", .resizeUpDown),
            ("not-allowed", .operationNotAllowed),
        ]

        if #available(macOS 10.13, *) {
            candidates.append(("text", .iBeamCursorForVerticalLayout))
        }

        return candidates.compactMap { entry in
            guard let cursorSignature = self.signature(for: entry.1) else { return nil }
            return (entry.0, cursorSignature)
        }
    }()

    private func signature(for cursor: NSCursor, sampleSize: Int = 32) -> CursorSignature? {
        let image = cursor.image
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: sampleSize, pixelsHigh: sampleSize,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = NSSize(width: sampleSize, height: sampleSize)

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let scale = min(CGFloat(sampleSize) / sourceSize.width, CGFloat(sampleSize) / sourceSize.height)
        let drawWidth = sourceSize.width * scale
        let drawHeight = sourceSize.height * scale
        let drawRect = NSRect(
            x: (CGFloat(sampleSize) - drawWidth) / 2,
            y: (CGFloat(sampleSize) - drawHeight) / 2,
            width: drawWidth, height: drawHeight
        )
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.bitmapData else { return nil }

        var alphaSamples: [UInt8] = []
        alphaSamples.reserveCapacity(sampleSize * sampleSize)
        let bytesPerRow = bitmap.bytesPerRow

        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                let offset = y * bytesPerRow + x * 4
                let alpha = data[offset + 3]
                alphaSamples.append(alpha > 24 ? 255 : 0)
            }
        }

        let hotspot = cursor.hotSpot
        return CursorSignature(
            aspectRatio: Double(sourceSize.width / max(1, sourceSize.height)),
            hotspotXRatio: Double(hotspot.x / max(1, sourceSize.width)),
            hotspotYRatio: Double(hotspot.y / max(1, sourceSize.height)),
            shapeSamples: alphaSamples
        )
    }

    private func signatureScore(_ lhs: CursorSignature, _ rhs: CursorSignature) -> Int {
        let count = min(lhs.shapeSamples.count, rhs.shapeSamples.count)
        var imageDifference = 0
        for index in 0..<count {
            imageDifference += abs(Int(lhs.shapeSamples[index]) - Int(rhs.shapeSamples[index]))
        }
        let aspectPenalty = Int(abs(lhs.aspectRatio - rhs.aspectRatio) * 1800)
        let hotspotPenalty = Int((abs(lhs.hotspotXRatio - rhs.hotspotXRatio) + abs(lhs.hotspotYRatio - rhs.hotspotYRatio)) * 2200)
        return imageDifference + aspectPenalty + hotspotPenalty
    }

    private func attributeString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? String
    }

    private func attributeBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? Bool
    }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        guard error == .success, let actions = names as? [String] else { return [] }
        return actions
    }

    private func currentElement() -> AXUIElement? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        var element: AXUIElement?
        let y = totalScreenHeight > 0 ? totalScreenHeight - location.y : location.y
        let error = AXUIElementCopyElementAtPosition(systemWideElement, Float(location.x), Float(y), &element)
        guard error == .success else { return nil }
        return element
    }

    private func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func parentElement(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard error == .success, let value else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func hasAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    }

    private func ancestorChain(startingAt element: AXUIElement?, maxDepth: Int = 4) -> [AXUIElement] {
        guard let element else { return [] }
        var elements: [AXUIElement] = [element]
        var current = element
        var depth = 0
        while depth < maxDepth, let parent = parentElement(of: current) {
            elements.append(parent)
            current = parent
            depth += 1
        }
        return elements
    }

    private func metadataString(for element: AXUIElement) -> String {
        return [
            attributeString(element, kAXRoleAttribute),
            attributeString(element, kAXSubroleAttribute),
            attributeString(element, kAXRoleDescriptionAttribute),
            attributeString(element, kAXDescriptionAttribute),
            attributeString(element, kAXHelpAttribute),
            attributeString(element, kAXTitleAttribute),
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    }

    private func elementLooksTextual(_ element: AXUIElement) -> Bool {
        let role = attributeString(element, kAXRoleAttribute)
        let subrole = attributeString(element, kAXSubroleAttribute)
        let editable = attributeBool(element, axEditableAttribute)
        let metadata = metadataString(for: element)
        let actions = actionNames(element)

        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            kAXSearchFieldSubrole as String,
        ]

        if editable == true || textRoles.contains(role ?? "") || textRoles.contains(subrole ?? "") {
            return true
        }

        if metadata.contains("text field") || metadata.contains("search field") || metadata.contains("editor") || metadata.contains("insertion point") || metadata.contains("caret") || metadata.contains("source editor") {
            return true
        }

        return hasAttribute(element, kAXSelectedTextRangeAttribute as String) || hasAttribute(element, kAXNumberOfCharactersAttribute as String) || (actions.contains(kAXPressAction as String) && metadata.contains("text"))
    }

    private func accessibilityCursorMatch() -> String? {
        let hoveredChain = ancestorChain(startingAt: currentElement())
        let focusedChain = ancestorChain(startingAt: focusedElement())

        for element in hoveredChain + focusedChain {
            if elementLooksTextual(element) {
                return "text"
            }
        }

        guard let element = hoveredChain.first else { return nil }

        let role = attributeString(element, kAXRoleAttribute)
        let enabled = attributeBool(element, kAXEnabledAttribute)
        let actions = actionNames(element)
        let metadata = hoveredChain.map { metadataString(for: $0) }.filter { !$0.isEmpty }.joined(separator: " ")
        
        if metadata.contains("crosshair") || metadata.contains("cross hair") || metadata.contains("precision") || metadata.contains("crop") {
            return "crosshair"
        }

        if role == kAXSplitterRole as String {
            return "resize-ew"
        }

        let pressableRoles: Set<String> = [
            kAXButtonRole as String, axLinkRole, kAXMenuItemRole as String,
            kAXPopUpButtonRole as String, kAXRadioButtonRole as String,
            kAXCheckBoxRole as String, kAXTabGroupRole as String,
        ]
        let hasPressAction = actions.contains(kAXPressAction as String)
        if enabled == false && (hasPressAction || pressableRoles.contains(role ?? "")) {
            return "not-allowed"
        }
        if hasPressAction || pressableRoles.contains(role ?? "") {
            return "pointer"
        }

        return nil
    }

    func currentCursorType() -> CursorType {
        let resolvedCursor: NSCursor?
        if #available(macOS 14.0, *) {
            resolvedCursor = NSCursor.currentSystem ?? NSCursor.current
        } else {
            resolvedCursor = NSCursor.current
        }

        guard let resolvedCursor else {
            return CursorType(rawValue: accessibilityCursorMatch() ?? "arrow") ?? .arrow
        }

        guard let currentSignature = signature(for: resolvedCursor) else {
            return CursorType(rawValue: accessibilityCursorMatch() ?? "arrow") ?? .arrow
        }

        guard let bestMatch = knownCursorSignatures.min(by: { lhs, rhs in
            signatureScore(currentSignature, lhs.1) < signatureScore(currentSignature, rhs.1)
        }) else {
            return CursorType(rawValue: accessibilityCursorMatch() ?? "arrow") ?? .arrow
        }

        let bestScore = signatureScore(currentSignature, bestMatch.1)
        let primaryThreshold = strictSignatureAcceptanceThresholds[bestMatch.0] ?? signatureAcceptanceThreshold
        let matchedCursorType: String
        if bestScore > primaryThreshold {
            if let relaxedThreshold = relaxedSignatureAcceptanceThresholds[bestMatch.0], bestScore <= relaxedThreshold {
                matchedCursorType = bestMatch.0
            } else {
                matchedCursorType = "arrow"
            }
        } else {
            matchedCursorType = bestMatch.0
        }

        return CursorType(rawValue: matchedCursorType) ?? .arrow
    }
}
