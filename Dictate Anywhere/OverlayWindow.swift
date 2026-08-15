//
//  OverlayWindow.swift
//  Dictate Anywhere
//
//  Floating NSWindow controller for dictation overlay.
//

import AppKit
import SwiftUI

@Observable
final class OverlayWindow {
    // MARK: - Properties

    private var window: NSWindow?
    private var hostingView: NSHostingView<OverlayContent>?
    private var hideTask: Task<Void, Never>?
    private let model = OverlayModel()
    private let bottomMargin: CGFloat = OverlayMetrics.size(24)
    private let canvasWidth: CGFloat = OverlayMetrics.size(320)
    private let canvasHeight: CGFloat = OverlayMetrics.size(200)

    // MARK: - Public

    func show(state: OverlayState) {
        hideTask?.cancel()
        hideTask = nil

        if Thread.isMainThread {
            showImpl(state: state)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showImpl(state: state)
            }
        }
    }

    func hide(afterDelay delay: TimeInterval = 0.5) {
        hideTask?.cancel()

        if delay > 0 {
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.hideImpl()
            }
        } else {
            if Thread.isMainThread {
                hideImpl()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.hideImpl()
                }
            }
        }
    }

    // MARK: - Private

    private func showImpl(state: OverlayState) {
        if window == nil {
            window = createWindow()
            let content = OverlayContent(model: model)
            hostingView = NSHostingView(rootView: content)
            hostingView?.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
            window?.contentView = hostingView
        }

        model.overlayState = state
        model.isVisible = true

        positionWindow()
        window?.orderFrontRegardless()
    }

    private func hideImpl() {
        model.isVisible = false

        // Allow fade-out animation to complete before removing window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            // Guard against show-during-fade race condition
            if !self.model.isVisible {
                self.window?.orderOut(nil)
            }
        }
    }

    private func createWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true
        win.isExcludedFromWindowsMenu = true
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        return win
    }

    private func positionWindow() {
        guard let win = window else { return }

        let screens = NSScreen.screens
        guard let index = OverlayScreenPicker.pickScreenIndex(
            screenFrames: screens.map(\.frame),
            focusPoint: focusedElementLocation(),
            mouseLocation: NSEvent.mouseLocation
        ) else { return }

        let size = NSSize(width: canvasWidth, height: canvasHeight)
        let origin = OverlayScreenPicker.overlayOrigin(
            inVisibleFrame: screens[index].visibleFrame,
            size: size,
            bottomMargin: bottomMargin
        )

        win.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    // MARK: - Focused element lookup

    /// Global location of the control currently receiving keystrokes, so the
    /// overlay lands on the display being dictated into. Nil when accessibility
    /// is unavailable or the focused app reports no usable geometry.
    private func focusedElementLocation() -> CGPoint? {
        guard let primaryFrame = NSScreen.screens.first?.frame else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        // The overlay has to appear the instant the hotkey fires, so never let
        // an unresponsive app block the main thread here.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)

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

        let element = focusedElement as! AXUIElement
        guard let axPoint = position(of: element) ?? containingWindowPosition(of: element) else {
            return nil
        }

        return OverlayScreenPicker.appKitPoint(fromAccessibilityPoint: axPoint, primaryFrame: primaryFrame)
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
