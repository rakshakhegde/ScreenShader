import AppKit
import CoreGraphics

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ targetCID: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

@_silgen_name("CGSSetDebugOptions")
func CGSSetDebugOptions(_ options: Int32) -> CGError

class CursorHider {
    static let shared = CursorHider()
    
    private lazy var transparentCursor: NSCursor = {
        let transparentImage = NSImage(size: NSSize(width: 1, height: 1))
        transparentImage.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        transparentImage.unlockFocus()
        return NSCursor(image: transparentImage, hotSpot: .zero)
    }()
    private var enforceTimer: Timer?
    private let kCGSDisableCursor: Int32 = 0x08000000
    private var hideCount = 0
    private var isHiding = false
    
    private init() {}
    
    func startHiding() {
        guard !isHiding else { return }
        isHiding = true
        
        let cid = CGSMainConnectionID()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        transparentCursor.push()
        
        enforceTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(aggressivelyHide), userInfo: nil, repeats: true)
        if let timer = enforceTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    @objc private func aggressivelyHide() {
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
        if hideCount > 1000 {
            for _ in 0..<hideCount - 10 {
                CGDisplayShowCursor(CGMainDisplayID())
                hideCount -= 1
            }
        }
    }
    
    func stopHiding() {
        guard isHiding else { return }
        isHiding = false
        
        enforceTimer?.invalidate()
        enforceTimer = nil
        
        // Pop the transparent cursor
        NSCursor.pop()
        
        // Push the arrow cursor so WindowServer applies it globally before we lose background privilege
        NSCursor.arrow.push()
        
        let cid = CGSMainConnectionID()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanFalse)
        
        // Now pop the arrow cursor so our stack is clean
        NSCursor.pop()
        
        _ = CGSSetDebugOptions(0)
        
        for _ in 0..<hideCount {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        hideCount = 0
        
        // Hard-reset the cursor connection
        CGAssociateMouseAndMouseCursorPosition(0)
        CGAssociateMouseAndMouseCursorPosition(1)
        
        // Force WindowServer to update the cursor visibility immediately
        if let loc = CGEvent(source: nil)?.location {
            CGWarpMouseCursorPosition(loc)
        }
    }
}
