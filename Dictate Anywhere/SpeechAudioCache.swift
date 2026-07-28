//
//  SpeechAudioCache.swift
//  Dictate Anywhere
//
//  Content-addressed cache for synthesized speech audio.
//
//  Cloud speech is billed per character and limited per minute, so audio that
//  has already been bought is never bought twice: pausing, resuming, seeking
//  backwards and re-reading a document all replay from here instead of going
//  back to the provider.
//

import CryptoKit
import Foundation

/// Whether a piece of synthesized audio is worth keeping past this playback.
nonisolated enum SpeechAudioCacheScope: Sendable {
    /// Spoken once and never re-read — a voice assistant reply, a voice
    /// preview. Kept in memory only, so a conversation cannot silt up the disk
    /// with audio nothing will ever ask for again.
    case ephemeral
    /// Part of a document the reader can pause, resume, seek around and re-read.
    case persistent
}

nonisolated struct SpeechAudioCacheKey: Hashable, Sendable {
    let provider: String
    let model: String
    let voice: String
    let text: String

    /// Content address of the audio. The chunk text is the whole identity of
    /// what was spoken, so the same chunk hits the cache no matter where in a
    /// document it appears or how the reader arrived at it.
    var digest: String {
        var hasher = SHA256()
        for component in [provider, model, voice, text] {
            hasher.update(data: Data(component.utf8))
            // Separator so ("ab", "c") and ("a", "bc") cannot collide.
            hasher.update(data: Data([0]))
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

actor SpeechAudioCache {
    static let shared = SpeechAudioCache()

    private struct MemoryEntry {
        let data: Data
        var lastAccess: UInt64
    }

    private let directory: URL?
    private let memoryCapacityBytes: Int
    private let diskCapacityBytes: Int
    private let maximumAge: TimeInterval

    private var memoryEntries: [String: MemoryEntry] = [:]
    private var memoryBytes = 0
    private var accessCounter: UInt64 = 0
    private var hasPreparedDirectory = false

    init(
        directory: URL? = SpeechAudioCache.defaultDirectory(),
        memoryCapacityBytes: Int = 64 * 1_024 * 1_024,
        diskCapacityBytes: Int = 256 * 1_024 * 1_024,
        // The reader's text does not survive a relaunch, so most of a cached
        // chunk's value is spent within the session that paid for it. A week is
        // generous cover for coming back to the same document.
        maximumAge: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.directory = directory
        self.memoryCapacityBytes = max(memoryCapacityBytes, 0)
        self.diskCapacityBytes = max(diskCapacityBytes, 0)
        self.maximumAge = max(maximumAge, 0)
    }

    static func defaultDirectory() -> URL? {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? "com.pixelforty.dictate-anywhere"
        return caches
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("SpeechAudio", isDirectory: true)
    }

    func data(for key: SpeechAudioCacheKey) -> Data? {
        let digest = key.digest

        if var entry = memoryEntries[digest] {
            accessCounter += 1
            entry.lastAccess = accessCounter
            memoryEntries[digest] = entry
            return entry.data
        }

        guard let fileURL = fileURL(for: digest),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return nil
        }
        // Touch the file so disk eviction sees this as recently used.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
        insertIntoMemory(data, digest: digest)
        return data
    }

    func store(
        _ data: Data,
        for key: SpeechAudioCacheKey,
        scope: SpeechAudioCacheScope = .persistent
    ) {
        guard !data.isEmpty else { return }
        let digest = key.digest
        insertIntoMemory(data, digest: digest)

        guard scope == .persistent else { return }
        guard let fileURL = fileURL(for: digest) else { return }
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else {
            return
        }
        pruneDiskIfNeeded()
    }

    /// Drops specific entries — the audio for text the reader no longer
    /// contains. Content addressing means an edit only orphans the chunks that
    /// actually changed; the untouched ones keep their keys and stay valid.
    func remove(_ keys: [SpeechAudioCacheKey]) {
        for key in keys {
            let digest = key.digest
            if let removed = memoryEntries.removeValue(forKey: digest) {
                memoryBytes -= removed.data.count
            }
            guard let directory else { continue }
            let fileURL = directory
                .appendingPathComponent(digest)
                .appendingPathExtension("audio")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Deletes anything past its age limit. Run at launch so an idle cache
    /// actually shrinks instead of sitting at its high-water mark until the next
    /// write happens to trip the size cap.
    @discardableResult
    func sweepExpired(now: Date = Date()) -> Int {
        guard let directory, maximumAge > 0 else { return 0 }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return 0
        }

        var removed = 0
        for url in entries {
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate
            guard let modified,
                  now.timeIntervalSince(modified) > maximumAge else {
                continue
            }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    func diskUsageBytes() -> Int {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.fileSizeKey]
              ) else {
            return 0
        }
        return entries.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return total + (size ?? 0)
        }
    }

    func removeAll() {
        memoryEntries.removeAll()
        memoryBytes = 0
        if let directory {
            try? FileManager.default.removeItem(at: directory)
            hasPreparedDirectory = false
        }
    }

    // MARK: - Memory

    private func insertIntoMemory(_ data: Data, digest: String) {
        guard memoryCapacityBytes > 0, data.count <= memoryCapacityBytes else {
            return
        }

        if let existing = memoryEntries[digest] {
            memoryBytes -= existing.data.count
        }
        accessCounter += 1
        memoryEntries[digest] = MemoryEntry(data: data, lastAccess: accessCounter)
        memoryBytes += data.count

        guard memoryBytes > memoryCapacityBytes else { return }
        for (evictedDigest, _) in memoryEntries.sorted(by: {
            $0.value.lastAccess < $1.value.lastAccess
        }) {
            guard memoryBytes > memoryCapacityBytes else { break }
            if let removed = memoryEntries.removeValue(forKey: evictedDigest) {
                memoryBytes -= removed.data.count
            }
        }
    }

    // MARK: - Disk

    private func fileURL(for digest: String) -> URL? {
        guard let directory, diskCapacityBytes > 0 else { return nil }
        if !hasPreparedDirectory {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            hasPreparedDirectory = true
        }
        return directory.appendingPathComponent(digest).appendingPathExtension("audio")
    }

    private func pruneDiskIfNeeded() {
        guard let directory else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else {
            return
        }

        var sized: [(url: URL, size: Int, modified: Date)] = []
        var total = 0
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize else {
                continue
            }
            total += size
            sized.append((url, size, values.contentModificationDate ?? .distantPast))
        }

        guard total > diskCapacityBytes else { return }
        // Evict oldest first, down to 80% so pruning is not run on every store.
        let target = diskCapacityBytes * 4 / 5
        for entry in sized.sorted(by: { $0.modified < $1.modified }) {
            guard total > target else { break }
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else {
                continue
            }
            total -= entry.size
        }
    }
}
