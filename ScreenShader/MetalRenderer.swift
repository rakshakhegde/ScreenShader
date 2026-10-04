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
  let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private var textureCache: CVMetalTextureCache!
  
  private var activeEffectSource: String? = nil
  private var renderPipeline: MTLRenderPipelineState? = nil
  
  private var passthroughPipeline: MTLRenderPipelineState? = nil
  private var cursorPipeline: MTLRenderPipelineState? = nil
  var cursorTracker: CursorTracker? = nil
  var customCursorScale: Float = 1.0
  
  
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
    metalLayer.isOpaque = true
    metalLayer.backgroundColor = NSColor.black.cgColor
    metalLayer.displaySyncEnabled = false

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

      struct Uniforms {
        float2 screenSize;
        float2 mousePosition;
        float time;
        float padding;
      };

      fragment float4 fragment_main(
        VertexOut in [[stage_in]],
        texture2d<float> inTexture [[texture(0)]],
        constant Uniforms &uniforms [[buffer(0)]]
      ) {
        ShaderInput shaderInput;
        shaderInput.inputTexture = TextureWrapper{inTexture, uniforms.screenSize};
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
        desc.storageMode = .private
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
                let cursorData = tracker.currentData
                if let cursorTex = cursorData.texture {
                    let globalMouse = NSEvent.mouseLocation
                    let mx = Float(globalMouse.x - screen.frame.origin.x)
                    let my = Float(globalMouse.y - screen.frame.origin.y)
                    let sw = Float(screen.frame.width)
                    let sh = Float(screen.frame.height)
                    
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
                }
            }
        }
        encoder1.endEncoding()
    }
    
    let pass2Descriptor = MTLRenderPassDescriptor()
    pass2Descriptor.colorAttachments[0].texture = drawable.texture
    pass2Descriptor.colorAttachments[0].loadAction = .dontCare
    pass2Descriptor.colorAttachments[0].storeAction = .store
    
    if let encoder2 = commandBuffer.makeRenderCommandEncoder(descriptor: pass2Descriptor) {
        if let screen = window.screen {
            if let renderPipeline = self.renderPipeline {
                struct RenderUniforms {
                    var screenSize: vector_float2
                    var mousePosition: vector_float2
                    var time: Float
                    var padding: Float = 0
                }
                
                let screenSize = vector_float2(Float(screen.frame.width), Float(screen.frame.height))
                let globalMouse = NSEvent.mouseLocation
                let mousePosition = vector_float2(
                  Float(globalMouse.x - screen.frame.origin.x), 
                  Float(globalMouse.y - screen.frame.origin.y))
                let time = Float(ProcessInfo.processInfo.systemUptime)

                var uniforms = RenderUniforms(screenSize: screenSize, mousePosition: mousePosition, time: time)

                encoder2.setRenderPipelineState(renderPipeline)
                encoder2.setFragmentTexture(intermediateTexture, index: 0)
                encoder2.setFragmentBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)

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

