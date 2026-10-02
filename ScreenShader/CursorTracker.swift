import AppKit
import CoreGraphics
import Metal
import ApplicationServices

class CursorTracker {
    private let device: MTLDevice
    private let timer: DispatchSourceTimer
    private var lastHash: Int = 0
    private var lastUpdateTime: CFTimeInterval = CACurrentMediaTime()
    private let fadeDuration: CFTimeInterval = 0.1
    
    // Thread-safe state
    private let lock = NSLock()
    private var _activeTexture: MTLTexture?
    private var _activeHotSpot: CGPoint = .zero
    private var _activeSize: CGSize = .zero
    private var _opacity: Float = 1.0
    
    var currentData: (texture: MTLTexture?, hotSpot: CGPoint, size: CGSize, opacity: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (_activeTexture, _activeHotSpot, _activeSize, _opacity)
    }
    
    init(device: MTLDevice) {
        self.device = device
        self.timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        self.timer.schedule(deadline: .now(), repeating: .milliseconds(33)) // ~30Hz
        self.timer.setEventHandler { [weak self] in
            self?.updateCursor()
        }
        self.timer.resume()
    }
    
    deinit {
        timer.cancel()
    }
    
    private func updateCursor() {
        let cursor = fetchCurrentCursor()
        
        let currentTime = CACurrentMediaTime()
        let dt = currentTime - lastUpdateTime
        lastUpdateTime = currentTime
        
        let idleTime = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        let isIdle = idleTime > 5
        
        let opacityChange = Float(dt / fadeDuration)
        
        lock.lock()
        if isIdle {
            _opacity = max(0.0, _opacity - opacityChange)
        } else {
            _opacity = min(1.0, _opacity + opacityChange)
        }
        let currentOpacity = _opacity
        let hasTexture = _activeTexture != nil
        lock.unlock()
        
        if currentOpacity == 0.0 {
            if hasTexture {
                lock.lock()
                self._activeTexture = nil
                lock.unlock()
                lastHash = 0
            }
            return
        }
        
        let newHash = cursor.image.tiffRepresentation?.hashValue ?? 0
        if newHash == lastHash && hasTexture {
            return
        }
        
        lastHash = newHash
        let texture = createTexture(from: cursor)
        
        lock.lock()
        self._activeTexture = texture
        self._activeHotSpot = cursor.hotSpot
        self._activeSize = cursor.image.size
        lock.unlock()
    }
    
    private func fetchCurrentCursor() -> NSCursor {
        return NSCursor.currentSystem ?? .arrow
    }
    
    private func createTexture(from cursor: NSCursor) -> MTLTexture? {
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
            return texture
        }
        return nil
    }
}
