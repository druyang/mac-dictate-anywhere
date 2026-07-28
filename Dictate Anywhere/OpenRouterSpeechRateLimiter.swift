//
//  OpenRouterSpeechRateLimiter.swift
//  Dictate Anywhere
//
//  Session-wide throttle for OpenRouter speech synthesis.
//
//  Buffer-depth limits inside a single playback run are not enough: every seek
//  starts a fresh run, so a reader hunting for a spot renews its own allowance
//  and walks straight into a 429. This limiter outlives individual runs, so
//  bursts are smoothed instead of multiplied — and a request waits its turn
//  rather than failing.
//

import Foundation

actor OpenRouterSpeechRateLimiter {
    static let shared = OpenRouterSpeechRateLimiter()

    typealias Clock = @Sendable () -> Date
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let maximumRequestsPerMinute: Int
    private let maximumConcurrentRequests: Int
    private let now: Clock
    private let sleep: Sleeper

    private var recentRequestTimes: [Date] = []
    private var activeRequests = 0
    private var blockedUntil: Date?

    init(
        maximumRequestsPerMinute: Int = 20,
        maximumConcurrentRequests: Int = 2,
        now: @escaping Clock = { Date() },
        sleep: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.maximumRequestsPerMinute = max(maximumRequestsPerMinute, 1)
        self.maximumConcurrentRequests = max(maximumConcurrentRequests, 1)
        self.now = now
        self.sleep = sleep
    }

    /// Waits until a request may be sent, then counts it. Every `acquire` must
    /// be paired with a `release`.
    func acquire() async throws {
        while true {
            try Task.checkCancellation()
            let currentTime = now()

            if let blockedUntil, blockedUntil > currentTime {
                try await sleep(
                    max(blockedUntil.timeIntervalSince(currentTime), 0.05)
                )
                continue
            }

            recentRequestTimes.removeAll {
                currentTime.timeIntervalSince($0) >= 60
            }

            if activeRequests >= maximumConcurrentRequests {
                try await sleep(0.05)
                continue
            }

            if recentRequestTimes.count >= maximumRequestsPerMinute,
               let oldest = recentRequestTimes.first {
                let wait = 60 - currentTime.timeIntervalSince(oldest)
                try await sleep(max(wait, 0.05))
                continue
            }

            recentRequestTimes.append(currentTime)
            activeRequests += 1
            return
        }
    }

    func release() {
        activeRequests = max(activeRequests - 1, 0)
    }

    /// A 429 means the whole app is over the provider's limit, not just the one
    /// request that saw it. Hold every other synthesis back for the same window
    /// so a retry storm cannot form behind it.
    func backOff(seconds: TimeInterval) {
        let until = now().addingTimeInterval(max(seconds, 0))
        if let blockedUntil, blockedUntil >= until { return }
        blockedUntil = until
    }

    var isBackingOff: Bool {
        guard let blockedUntil else { return false }
        return blockedUntil > now()
    }
}
