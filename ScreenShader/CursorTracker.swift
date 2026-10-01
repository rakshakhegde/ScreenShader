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
        if #available(macOS 14.0, *) {
            if let systemCursor = NSCursor.currentSystem {
                return systemCursor
            }
        }
        
        let fallbackStr = accessibilityCursorMatch() ?? "arrow"
        switch fallbackStr {
        case "text": return .iBeam
        case "pointer": return .pointingHand
        case "crosshair": return .crosshair
        case "open-hand": return .openHand
        case "closed-hand": return .closedHand
        case "resize-ew": return .resizeLeftRight
        case "resize-ns": return .resizeUpDown
        case "not-allowed": return .operationNotAllowed
        default: return .arrow
        }
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

    private let systemWideElement = AXUIElementCreateSystemWide()
    private let totalScreenHeight = NSScreen.screens.reduce(CGFloat(0)) { max($0, $1.frame.maxY) }
    
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
        let editable = attributeBool(element, "AXEditable")
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
            kAXButtonRole as String, "AXLink", kAXMenuItemRole as String,
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
}
