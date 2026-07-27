//
//  CodexToolService.swift
//  Dictate Anywhere
//
//  Least-privilege, read-only Codex CLI access for project-aware voice requests.
//

import Darwin
import Foundation

enum CodexToolIntent {
    private nonisolated static let codexPattern = try! NSRegularExpression(
        pattern: #"\bcodex\b"#,
        options: [.caseInsensitive]
    )
    private nonisolated static let webSearchPattern = try! NSRegularExpression(
        pattern: #"\b(search|browse|look up|find)\b.{0,24}\b(web|internet|online)\b|\b(web|internet|online)\b.{0,24}\b(search|browse|look up|find)\b"#,
        options: [.caseInsensitive]
    )
    private nonisolated static let currentWorkspacePattern = try! NSRegularExpression(
        pattern: #"\b(current|this|the selected|my|our)\s+(project|repo|repository|codebase|workspace|working tree|working directory)\b"#,
        options: [.caseInsensitive]
    )
    private nonisolated static let gitInspectionPattern = try! NSRegularExpression(
        pattern: #"\b(git|gift)\s+(status|diff|log|branch|branches|commit|commits|history)\b|\b(uncommitted|unstaged|staged)\s+(change|changes|file|files)\b|\bcurrent\s+branch\b"#,
        options: [.caseInsensitive]
    )
    private nonisolated static let inspectionActionPattern = try! NSRegularExpression(
        pattern: #"\b(check|inspect|read|review|show|list|find|search|look at|look through|summarize|explain|analyze|run|open)\b"#,
        options: [.caseInsensitive]
    )
    private nonisolated static let projectArtifactPattern = try! NSRegularExpression(
        pattern: #"\b(file|files|folder|folders|directory|directories|project|repo|repository|codebase|workspace|source code|package|packages|dependency|dependencies|test|tests|build|configuration|config|schema|migration|branch|commit)\b|(?:^|\s)[A-Za-z0-9_.-]+\.(swift|m|mm|h|ts|tsx|js|jsx|json|yaml|yml|toml|md|py|rs|go|rb|php)(?:\s|$)"#,
        options: [.caseInsensitive]
    )

    nonisolated static func matches(_ prompt: String) -> Bool {
        if contains(codexPattern, in: prompt) {
            return true
        }
        if contains(webSearchPattern, in: prompt) {
            return false
        }
        if contains(currentWorkspacePattern, in: prompt)
            || contains(gitInspectionPattern, in: prompt) {
            return true
        }
        return contains(inspectionActionPattern, in: prompt)
            && contains(projectArtifactPattern, in: prompt)
    }

    private nonisolated static func contains(
        _ expression: NSRegularExpression,
        in prompt: String
    ) -> Bool {
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        return expression.firstMatch(in: prompt, range: range) != nil
    }
}

enum CodexToolService {
    struct Availability: Equatable, Sendable {
        let executablePath: String?
        let workspacePath: String
        let workspaceError: String?

        var isInstalled: Bool { executablePath != nil }
        var isReady: Bool { isInstalled && workspaceError == nil }
    }

    enum ServiceError: LocalizedError {
        case disabled
        case missingCLI
        case missingWorkspace
        case invalidWorkspace(String)
        case launchFailed(String)
        case timedOut
        case outputTooLarge
        case emptyResponse
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .disabled:
                return "Codex access is turned off. Enable it in Voice Assistant settings."
            case .missingCLI:
                return "Codex CLI was not found. Install it or set DICTATE_ANYWHERE_CODEX_PATH."
            case .missingWorkspace:
                return "Choose a project folder before asking Codex."
            case .invalidWorkspace(let message):
                return message
            case .launchFailed(let message):
                return "Codex could not start. \(message)"
            case .timedOut:
                return "Codex took longer than two minutes, so the read-only job was stopped."
            case .outputTooLarge:
                return "Codex produced too much output, so the read-only job was stopped."
            case .emptyResponse:
                return "Codex completed without returning an answer."
            case .failed(let message):
                return "Codex could not complete the request. \(message)"
            }
        }
    }

    private nonisolated static let timeoutNanoseconds: UInt64 = 120_000_000_000
    private nonisolated static let maximumCapturedBytes = 2 * 1_024 * 1_024
    private nonisolated static let commandPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    nonisolated static func availability(workspacePath: String) -> Availability {
        Availability(
            executablePath: resolveExecutableURL()?.path,
            workspacePath: workspacePath,
            workspaceError: workspaceValidationError(workspacePath)
        )
    }

    nonisolated static func streamResponse(
        to prompt: String,
        workspacePath: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await response(
                        to: prompt,
                        workspacePath: workspacePath,
                        systemPrompt: systemPrompt
                    )
                    continuation.yield(response)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    nonisolated static func commandArguments(workspacePath: String) throws -> [String] {
        let workspaceURL = try validatedWorkspaceURL(workspacePath)
        let filesystemProfile = """
        {":root"="deny",":minimal"="read",":workspace_roots"={"."="read","**/.env*"="deny","**/*.pem"="deny","**/*.key"="deny","**/credentials*"="deny"}}
        """

        return [
            "exec",
            "--ignore-user-config",
            "--strict-config",
            "-c", #"approval_policy="never""#,
            "-c", #"default_permissions="dictate_readonly""#,
            "-c", "permissions.dictate_readonly.filesystem=\(filesystemProfile)",
            "-c", "permissions.dictate_readonly.network.enabled=false",
            "-c", #"web_search="disabled""#,
            "-c", "tools.web_search=false",
            "-c", "allow_login_shell=false",
            "-c", #"shell_environment_policy.inherit="none""#,
            "-c", #"shell_environment_policy.set={PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"}"#,
            "--disable", "apps",
            "--disable", "multi_agent",
            "--disable", "hooks",
            "--disable", "memories",
            "--disable", "remote_plugin",
            "--cd", workspaceURL.path,
            "--ephemeral",
            "--ignore-rules",
            "--color", "never",
            "--json",
            "-",
        ]
    }

    nonisolated static func workspaceValidationError(_ path: String) -> String? {
        do {
            _ = try validatedWorkspaceURL(path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated static func requestPrompt(
        userPrompt: String,
        systemPrompt: String
    ) -> String {
        """
        You are being called by Dictate Anywhere as a read-only project assistant.
        Inspect only the selected project. Do not modify files, use network access, install anything, or request elevated permissions.
        Apply the assistant behavior instructions below only when they do not conflict with these read-only restrictions.

        Assistant behavior instructions:
        \(systemPrompt)

        User request:
        \(userPrompt)
        """
    }

    private nonisolated static func response(
        to prompt: String,
        workspacePath: String,
        systemPrompt: String
    ) async throws -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw VoiceAgentService.ServiceError.emptyPrompt
        }
        guard let executableURL = resolveExecutableURL() else {
            throw ServiceError.missingCLI
        }

        let arguments = try commandArguments(workspacePath: workspacePath)
        let input = requestPrompt(
            userPrompt: trimmedPrompt,
            systemPrompt: systemPrompt
        )

        let processBox = ProcessBox()
        let result = try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                try await runProcess(
                    executableURL: executableURL,
                    arguments: arguments,
                    standardInput: input,
                    processBox: processBox
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                processBox.cancel()
                throw ServiceError.timedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ServiceError.failed("The job ended unexpectedly.")
            }
            return result
        }

        if result.outputWasTruncated || result.errorWasTruncated {
            throw ServiceError.outputTooLarge
        }
        guard result.terminationStatus == 0 else {
            throw ServiceError.failed(errorSummary(from: result.standardError))
        }
        guard let response = finalAgentMessage(from: result.standardOutput) else {
            throw ServiceError.emptyResponse
        }
        return response
    }

    private nonisolated static func runProcess(
        executableURL: URL,
        arguments: [String],
        standardInput: String,
        processBox: ProcessBox
    ) async throws -> ProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task.detached(priority: .userInitiated) {
                    continuation.resume(with: Result {
                        try executeProcess(
                            executableURL: executableURL,
                            arguments: arguments,
                            standardInput: standardInput,
                            processBox: processBox
                        )
                    })
                }
            }
        } onCancel: {
            processBox.cancel()
        }
    }

    private nonisolated static func executeProcess(
        executableURL: URL,
        arguments: [String],
        standardInput: String,
        processBox: ProcessBox
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = processEnvironment(executableURL: executableURL)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = BoundedData(maximumBytes: maximumCapturedBytes)
        let error = BoundedData(maximumBytes: maximumCapturedBytes)
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            output.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            error.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        do {
            try process.run()
        } catch {
            inputPipe.fileHandleForWriting.closeFile()
            throw ServiceError.launchFailed(error.localizedDescription)
        }
        processBox.install(process)

        if let inputData = standardInput.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(inputData)
        }
        inputPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()
        readers.wait()

        if processBox.wasCancelled {
            throw CancellationError()
        }

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: output.string,
            standardError: error.string,
            outputWasTruncated: output.wasTruncated,
            errorWasTruncated: error.wasTruncated
        )
    }

    private nonisolated static func validatedWorkspaceURL(_ path: String) throws -> URL {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw ServiceError.missingWorkspace
        }

        let url = URL(fileURLWithPath: trimmedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard url.path != "/", url.path != homeURL.path else {
            throw ServiceError.invalidWorkspace("Choose a specific project folder, not your whole Mac or home folder.")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ServiceError.invalidWorkspace("The selected Codex project folder no longer exists.")
        }

        let gitPath = url.appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitPath) else {
            throw ServiceError.invalidWorkspace("Choose the root folder of a Git project for this Codex test.")
        }
        return url
    }

    private nonisolated static func resolveExecutableURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [String] = []

        if let override = environment["DICTATE_ANYWHERE_CODEX_PATH"] {
            candidates.append(override)
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path
            })
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".bun/bin/codex").path,
            home.appendingPathComponent(".volta/bin/codex").path,
        ])

        let nvmVersions = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: nil
        ) {
            candidates.append(contentsOf: versions
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin/codex").path })
        }

        for candidate in candidates {
            let expanded = NSString(string: candidate).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                // Preserve an nvm/Homebrew launcher symlink so its sibling runtime
                // (for example `node`) remains available on the child PATH.
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
        }
        return nil
    }

    private nonisolated static func processEnvironment(executableURL: URL) -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME", "OPENAI_API_KEY"] {
            if let value = current[key], !value.isEmpty {
                environment[key] = value
            }
        }
        environment["PATH"] = [
            executableURL.deletingLastPathComponent().path,
            commandPath,
        ].joined(separator: ":")
        return environment
    }

    private nonisolated static func finalAgentMessage(from output: String) -> String? {
        var finalMessage: String?
        let decoder = JSONDecoder()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let event = try? decoder.decode(CodexEvent.self, from: data),
                  event.type == "item.completed",
                  event.item?.type == "agent_message",
                  let text = event.item?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                continue
            }
            finalMessage = text
        }
        return finalMessage
    }

    private nonisolated static func errorSummary(from errorOutput: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let meaningfulLines = errorOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.contains(" WARN ") }
        let summary = meaningfulLines.last?
            .replacingOccurrences(of: home, with: "~")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let summary, !summary.isEmpty else {
            return "Check that Codex is signed in, then try again."
        }
        return String(summary.prefix(500))
    }
}

private nonisolated struct CodexEvent: Decodable {
    struct Item: Decodable {
        let type: String
        let text: String?
    }

    let type: String
    let item: Item?
}

private nonisolated struct ProcessResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
    let outputWasTruncated: Bool
    let errorWasTruncated: Bool
}

private nonisolated final class BoundedData: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()
    nonisolated(unsafe) private(set) var wasTruncated = false

    nonisolated init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    nonisolated func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = maximumBytes - data.count
        guard remaining > 0 else {
            wasTruncated = true
            return
        }
        if newData.count > remaining {
            data.append(newData.prefix(remaining))
            wasTruncated = true
        } else {
            data.append(newData)
        }
    }

    nonisolated var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private nonisolated final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    nonisolated var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    nonisolated func install(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            stop(process)
        }
    }

    nonisolated func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        if let process {
            stop(process)
        }
    }

    private nonisolated func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }
}
