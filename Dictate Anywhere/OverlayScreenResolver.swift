//
//  OverlayScreenResolver.swift
//  Dictate Anywhere
//
//  Supplies the display geometry the dictation overlay places itself against.
//

import AppKit

/// Source of the display information the overlay needs.
///
/// Split out of `OverlayWindow` so the once-per-session lookup can be tested
/// without attaching monitors or granting accessibility permission.
protocol OverlayScreenResolving {
    /// Visible frames of the attached displays, primary first, in AppKit global
    /// coordinates. Cheap enough to read on every overlay update.
    func visibleFrames() -> [CGRect]

    /// Index of the display the overlay belongs on, or nil when none matches.
    ///
    /// Expensive: this is the call that crosses a process boundary to ask the
    /// focused application where it is, so callers resolve once per session.
    func resolveScreenIndex() -> Int?
}

/// Resolves the overlay's display from the real window server.
struct SystemOverlayScreenResolver: OverlayScreenResolving {
    /// The overlay has to appear the instant the hotkey fires, so an
    /// unresponsive app must never block the main thread for long.
    private static let messagingTimeout: Float = 0.25

    func visibleFrames() -> [CGRect] {
        NSScreen.screens.map(\.visibleFrame)
    }

    func resolveScreenIndex() -> Int? {
        OverlayScreenPicker.pickScreenIndex(
            screenFrames: NSScreen.screens.map(\.frame),
            focusPoint: focusedElementLocation(),
            mouseLocation: NSEvent.mouseLocation
        )
    }

    // MARK: - Focused element lookup

    /// Global location of the control currently receiving keystrokes, so the
    /// overlay lands on the display being dictated into. Nil when accessibility
    /// is unavailable or the focused app reports no usable geometry.
    private func focusedElementLocation() -> CGPoint? {
        guard let primaryFrame = NSScreen.screens.first?.frame else { return nil }

        let systemWide = AXUIElementCreateSystemWide()

        let axPoint = AccessibilityMessagingTimeout.withTimeout(
            Self.messagingTimeout,
            apply: { _ = AXUIElementSetMessagingTimeout(systemWide, $0) }
        ) { () -> CGPoint? in
            guard let element = focusedElement(of: systemWide) else { return nil }
            return position(of: element) ?? containingWindowPosition(of: element)
        }

        guard let axPoint else { return nil }

        return OverlayScreenPicker.appKitPoint(fromAccessibilityPoint: axPoint, primaryFrame: primaryFrame)
    }

    private func focusedElement(of systemWide: AXUIElement) -> AXUIElement? {
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success,
            let focusedElement,
            CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    private func position(of element: AXUIElement) -> CGPoint? {
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
            let positionValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = positionValue as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// Some apps expose no position on the focused element itself; its window
    /// is a good enough stand-in for picking a display.
    private func containingWindowPosition(of element: AXUIElement) -> CGPoint? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowValue
        ) == .success,
            let windowValue,
            CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return position(of: windowValue as! AXUIElement)
    }
}
