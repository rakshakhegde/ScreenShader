import AppKit
import CoreGraphics
import Metal
import MetalKit
import ApplicationServices

struct ShaderCompilationError: LocalizedError {
  let effectID: UUID
  let underlyingError: Error

  var errorDescription: String? {
    return self.underlyingError.localizedDescription
  }
}

class MetalView: MTKView {
  var metalLayer: CAMetalLayer {
    return self.layer as! CAMetalLayer
  }
  override func makeBackingLayer() -> CALayer {
    return CAMetalLayer()
  }
}

class MetalRenderer {
  let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private var textureCache: CVMetalTextureCache!
  
  private var activeSources: [(id: UUID, source: String)] = []
  private var renderPipelines: [MTLRenderPipelineState] = []
  
  private var passthroughPipeline: MTLRenderPipelineState? = nil
  private var cursorPipeline: MTLRenderPipelineState? = nil
  var cursorTracker: CursorTracker? = nil
  var customCursorScale: Float = 1.0
  
  private var intermediateTextureA: MTLTexture? = nil
  private var intermediateTextureB: MTLTexture? = nil
  private var previousFrameTexture: MTLTexture? = nil
  private var hasPreviousFrame: Bool = false

  private let renderTargetPixelFormat: MTLPixelFormat
  private let captureTexturePixelFormat: MTLPixelFormat
  private let metalLayer: CAMetalLayer
  private var screenFrame: CGRect

  init(
    metalLayer: CAMetalLayer,
    drawablePixelFormat: MTLPixelFormat,
    colorspace: CGColorSpace,
    wantsEDR: Bool,
    captureTexturePixelFormat: MTLPixelFormat,
    backingScaleFactor: CGFloat,
    screenFrame: CGRect
  ) {
    guard let device = MTLCreateSystemDefaultDevice() else {
      fatalError("Unable to access a Metal device on this system.")
    }
    self.device = device
    self.metalLayer = metalLayer
    self.screenFrame = screenFrame

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
    metalLayer.framebufferOnly = false
    metalLayer.contentsScale = backingScaleFactor
    metalLayer.isOpaque = true
    metalLayer.backgroundColor = NSColor.black.cgColor
    // Disable displaySyncEnabled: CVDisplayLink already paces our frame timing.
    // Keeping displaySyncEnabled=true causes WindowServer to freeze drawable presentation
    // for 1000ms during Mission Control transitions on external displays.
    metalLayer.displaySyncEnabled = false

    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, self.device, nil, &cache)
    if let createdCache = cache {
      self.textureCache = createdCache
    } else {
      fatalError("Could not create CVMetalTextureCache.")
    }
    
    do {
      self.passthroughPipeline = try Self.buildPassthroughPipeline(device: self.device, pixelFormat: drawablePixelFormat)
      self.cursorPipeline = try Self.buildCursorRenderPipeline(device: self.device, pixelFormat: drawablePixelFormat)
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
        TextureWrapper previousTexture;
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

      struct Uniforms {
        float2 screenSize;
        float2 mousePosition;
        float time;
        float padding;
      };

      fragment float4 fragment_main(
        VertexOut in [[stage_in]],
        texture2d<float> inTexture [[texture(0)]],
        texture2d<float> prevTexture [[texture(1)]],
        constant Uniforms &uniforms [[buffer(0)]]
      ) {
        ShaderInput shaderInput;
        shaderInput.inputTexture = TextureWrapper{inTexture, uniforms.screenSize};
        shaderInput.previousTexture = TextureWrapper{prevTexture, uniforms.screenSize};
        shaderInput.texCoord = in.texCoord;
        shaderInput.screenPosition = texToScreen(in.texCoord, uniforms.screenSize);
        shaderInput.screenSize = uniforms.screenSize;
        shaderInput.mousePosition = uniforms.mousePosition;
        shaderInput.time = uniforms.time;

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
      
      fragment float4 cursor_fragment_main(CursorVertexOut in [[stage_in]], texture2d<float> cursorTexture [[texture(0)]], constant float &opacity [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 color = cursorTexture.sample(s, in.texCoord);
        return float4(color.rgb, color.a * opacity);
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



  func setEffectSources(_ sources: [(id: UUID, source: String)]) throws {
    guard !sources.isEmpty else {
      self.activeSources = []
      self.renderPipelines = []
      return
    }

    if sources.count == self.activeSources.count &&
       zip(sources, self.activeSources).allSatisfy({ $0.0.id == $0.1.id && $0.0.source == $0.1.source }) &&
       !self.renderPipelines.isEmpty {
      return
    }

    var newPipelines: [MTLRenderPipelineState] = []
    for item in sources {
      do {
        let pipeline = try Self.buildRenderPipeline(
          device: self.device,
          effectSource: item.source,
          pixelFormat: self.renderTargetPixelFormat
        )
        newPipelines.append(pipeline)
      } catch {
        self.renderPipelines = []
        self.activeSources = []
        throw ShaderCompilationError(effectID: item.id, underlyingError: error)
      }
    }
    self.renderPipelines = newPipelines
    self.activeSources = sources
  }

  private func ensureIntermediateTextures(width: Int, height: Int) {
    if self.intermediateTextureA?.width != width || self.intermediateTextureA?.height != height {
      let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: self.renderTargetPixelFormat, width: width, height: height, mipmapped: false)
      desc.usage = [.renderTarget, .shaderRead]
      desc.storageMode = .private
      self.intermediateTextureA = self.device.makeTexture(descriptor: desc)
      self.intermediateTextureB = self.device.makeTexture(descriptor: desc)
    }
  }

  private func ensurePreviousFrameTexture(width: Int, height: Int) {
    if self.previousFrameTexture?.width != width || self.previousFrameTexture?.height != height {
      let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: self.renderTargetPixelFormat, width: width, height: height, mipmapped: false)
      desc.usage = [.shaderRead]
      desc.storageMode = .private
      self.previousFrameTexture = self.device.makeTexture(descriptor: desc)
      self.hasPreviousFrame = false
    }
  }

  private func encodeCursorPass(
    commandBuffer: MTLCommandBuffer,
    baseTexture: MTLTexture,
    width: Int,
    height: Int
  ) -> MTLTexture? {
    guard let cursorPipeline = self.cursorPipeline,
          let tracker = self.cursorTracker else {
      return nil
    }

    let cgLoc = CGEvent(source: CGEventSource(stateID: .hidSystemState))?.location ?? .zero
    let mainScreenHeight = CGDisplayBounds(CGMainDisplayID()).height
    let globalMouse = NSPoint(x: cgLoc.x, y: CGFloat(mainScreenHeight) - cgLoc.y)

    // Only render cursor if the mouse is physically within this screen (with tolerance for edge pixels)
    let screenBounds = self.screenFrame.insetBy(dx: -2.0, dy: -2.0)
    guard screenBounds.contains(globalMouse) else {
      return nil
    }

    let cursorData = tracker.currentData
    guard let cursorTex = cursorData.texture else {
      return nil
    }

    self.ensureIntermediateTextures(width: width, height: height)
    guard let intermediateTexture = self.intermediateTextureA else {
      return nil
    }

    let pass1Descriptor = MTLRenderPassDescriptor()
    pass1Descriptor.colorAttachments[0].texture = intermediateTexture
    pass1Descriptor.colorAttachments[0].loadAction = .dontCare
    pass1Descriptor.colorAttachments[0].storeAction = .store

    guard let encoder1 = commandBuffer.makeRenderCommandEncoder(descriptor: pass1Descriptor) else {
      return nil
    }

    if let ptPipeline = self.passthroughPipeline {
      encoder1.setRenderPipelineState(ptPipeline)
      encoder1.setFragmentTexture(baseTexture, index: 0)
      encoder1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    let mx = Float(globalMouse.x - self.screenFrame.origin.x)
    let my = Float(globalMouse.y - self.screenFrame.origin.y)
    let sw = Float(self.screenFrame.width)
    let sh = Float(self.screenFrame.height)

    let cw_points = Float(cursorData.size.width) * self.customCursorScale
    let ch_points = Float(cursorData.size.height) * self.customCursorScale
    let hsX = Float(cursorData.hotSpot.x) * self.customCursorScale
    let hsY = Float(cursorData.hotSpot.y) * self.customCursorScale

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
    var cursorOpacity = Float(cursorData.opacity)
    encoder1.setFragmentBytes(&cursorOpacity, length: MemoryLayout<Float>.stride, index: 0)
    encoder1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    encoder1.endEncoding()

    return intermediateTexture
  }

  private struct RenderUniforms {
    var screenSize: vector_float2
    var mousePosition: vector_float2
    var time: Float
    var padding: Float = 0
  }

  private func encodeEffectPass(
    commandBuffer: MTLCommandBuffer,
    pipeline: MTLRenderPipelineState,
    sourceTexture: MTLTexture,
    previousTexture: MTLTexture,
    destinationTexture: MTLTexture,
    uniforms: inout RenderUniforms
  ) {
    let passDescriptor = MTLRenderPassDescriptor()
    passDescriptor.colorAttachments[0].texture = destinationTexture
    passDescriptor.colorAttachments[0].loadAction = .dontCare
    passDescriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(sourceTexture, index: 0)
    encoder.setFragmentTexture(previousTexture, index: 1)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    encoder.endEncoding()
  }

  func renderContentBuffer(contentBuffer: CVPixelBuffer) {
    guard !self.renderPipelines.isEmpty else {
      return
    }

    guard let drawable = self.metalLayer.nextDrawable() else {
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

    guard let commandBuffer = self.commandQueue.makeCommandBuffer() else {
      return
    }

    self.ensurePreviousFrameTexture(width: width, height: height)
    let prevTextureToUse = (self.hasPreviousFrame && self.previousFrameTexture != nil)
      ? self.previousFrameTexture!
      : texture

    // Pass 1: Render cursor into intermediateTextureA only if cursor is active and on this screen
    var currentSource = self.encodeCursorPass(
      commandBuffer: commandBuffer,
      baseTexture: texture,
      width: width,
      height: height
    ) ?? texture

    let screenSize = vector_float2(Float(self.screenFrame.width), Float(self.screenFrame.height))
    let cgLoc = CGEvent(source: CGEventSource(stateID: .hidSystemState))?.location ?? .zero
    let mainScreenHeight = CGDisplayBounds(CGMainDisplayID()).height
    let globalMouse = NSPoint(x: cgLoc.x, y: CGFloat(mainScreenHeight) - cgLoc.y)
    let mousePosition = vector_float2(
      Float(globalMouse.x - self.screenFrame.origin.x),
      Float(globalMouse.y - self.screenFrame.origin.y)
    )
    let time = Float(ProcessInfo.processInfo.systemUptime)
    var uniforms = RenderUniforms(screenSize: screenSize, mousePosition: mousePosition, time: time)

    let totalPasses = self.renderPipelines.count
    if totalPasses > 1 {
      self.ensureIntermediateTextures(width: width, height: height)
      guard self.intermediateTextureA != nil && self.intermediateTextureB != nil else {
        return
      }
    }

    for (index, pipeline) in self.renderPipelines.enumerated() {
      let isLast = (index == totalPasses - 1)
      let destinationTexture: MTLTexture
      if isLast {
        destinationTexture = drawable.texture
      } else {
        if currentSource === self.intermediateTextureA {
          destinationTexture = self.intermediateTextureB!
        } else {
          destinationTexture = self.intermediateTextureA!
        }
      }

      self.encodeEffectPass(
        commandBuffer: commandBuffer,
        pipeline: pipeline,
        sourceTexture: currentSource,
        previousTexture: prevTextureToUse,
        destinationTexture: destinationTexture,
        uniforms: &uniforms
      )
      currentSource = destinationTexture
    }

    if let blitEncoder = commandBuffer.makeBlitCommandEncoder(),
       let prevTex = self.previousFrameTexture,
       drawable.texture.width == prevTex.width,
       drawable.texture.height == prevTex.height {
      blitEncoder.copy(from: drawable.texture, to: prevTex)
      blitEncoder.endEncoding()
      self.hasPreviousFrame = true
    }

    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  func updateScreenFrame(_ frame: CGRect) {
    self.screenFrame = frame
  }

  func updateScaleFactor(metalLayer: CAMetalLayer, backingScaleFactor: CGFloat) {
    metalLayer.contentsScale = backingScaleFactor
  }

  func flushTextureCache() {
    CVMetalTextureCacheFlush(self.textureCache, 0)
  }
}

