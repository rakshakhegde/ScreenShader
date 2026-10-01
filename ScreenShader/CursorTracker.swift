import AppKit
import ApplicationServices

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
