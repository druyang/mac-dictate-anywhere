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

    @ObservationIgnored private let screenSession: OverlayScreenSession

    // MARK: - Init

    init(screenResolver: OverlayScreenResolving = SystemOverlayScreenResolver()) {
        screenSession = OverlayScreenSession(resolver: screenResolver)
    }

    // MARK: - Public

    /// Starts a dictation, so the overlay chooses its display afresh.
    ///
    /// - Parameter targetProcessIdentifier: the app the transcript will be
    ///   pasted into, captured before audio startup so the overlay follows it
    ///   rather than whichever app is frontmost once the microphone is live.
    func beginSession(targetProcessIdentifier: pid_t?) {
        hideTask?.cancel()
        hideTask = nil

        if Thread.isMainThread {
            screenSession.begin(targetProcessIdentifier: targetProcessIdentifier)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.screenSession.begin(targetProcessIdentifier: targetProcessIdentifier)
            }
        }
    }

    func show(state: OverlayState) {
        let supersedesFinishingSession = hideTask != nil
        hideTask?.cancel()
        hideTask = nil

        if Thread.isMainThread {
            showImpl(state: state, startsNewSession: supersedesFinishingSession)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showImpl(state: state, startsNewSession: supersedesFinishingSession)
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
            hideTask = nil
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

    private func showImpl(state: OverlayState, startsNewSession: Bool) {
        if startsNewSession {
            screenSession.end()
        }

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

        // The next appearance is a new session and picks its display afresh.
        screenSession.end()

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
        guard let win = window, let visibleFrame = screenSession.visibleFrame() else { return }

        let size = NSSize(width: canvasWidth, height: canvasHeight)
        let origin = OverlayScreenPicker.overlayOrigin(
            inVisibleFrame: visibleFrame,
            size: size,
            bottomMargin: bottomMargin
        )

        let frame = NSRect(origin: origin, size: size)
        guard win.frame != frame else { return }

        win.setFrame(frame, display: true, animate: false)
    }
}
