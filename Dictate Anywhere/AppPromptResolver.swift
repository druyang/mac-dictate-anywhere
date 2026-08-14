//
//  AppPromptResolver.swift
//  Dictate Anywhere
//
//  Pure decision logic for per-app cleanup prompts: given the frontmost
//  app's bundle identifier, picks the matching rule's prompt or falls back
//  to the active provider's global prompt.
//

import Foundation

enum AppPromptResolver {
    static func resolve(
        bundleIdentifier: String?,
        mappings: [AppPromptMapping],
        enabled: Bool,
        fallback: String
    ) -> String {
        guard enabled, let bundleIdentifier,
              let match = mappings.first(where: { $0.bundleIdentifier == bundleIdentifier })
        else { return fallback }
        return match.prompt
    }
}
