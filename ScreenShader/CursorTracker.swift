import AppKit
import CoreGraphics
import Metal
import ApplicationServices

class CursorTracker {
    private let device: MTLDevice
    private let timer: DispatchSourceTimer
    private var lastHash: Int = 0
    
    // Thread-safe state
    private let lock = NSLock()
    private var _activeTexture: MTLTexture?
    private var _activeHotSpot: CGPoint = .zero
    private var _activeSize: CGSize = .zero
    
    var currentData: (texture: MTLTexture?, hotSpot: CGPoint, size: CGSize) {
        lock.lock()
        defer { lock.unlock() }
        return (_activeTexture, _activeHotSpot, _activeSize)
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
        
        // Hide cursor if idle for 3 seconds
        let idleTime = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        if idleTime > 5 {
            lock.lock()
            self._activeTexture = nil
            lock.unlock()
            lastHash = 0 // reset hash so it re-renders when it wakes up
            return
        }
        
        let newHash = cursor.image.tiffRepresentation?.hashValue ?? 0
        if newHash == lastHash {
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
