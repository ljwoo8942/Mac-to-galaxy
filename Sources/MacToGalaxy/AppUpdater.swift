import Darwin
import Foundation

struct AppUpdateError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

struct PreparedAppUpdate: Sendable {
    let app: URL
    let replacement: URL
    fileprivate let lock: FileHandle

    func exchangeBundles() throws {
        // Both bundles are on the same volume. A failed swap leaves the current app in place.
        guard renamex_np(app.path, replacement.path, UInt32(RENAME_SWAP)) == 0 else {
            let reason = String(cString: strerror(errno))
            throw AppUpdateError("앱을 교체할 수 없습니다. \(reason)")
        }
    }

    func discardReplacement() {
        try? FileManager.default.removeItem(at: replacement.deletingLastPathComponent())
    }
}

enum AppUpdater {
    static let revisionKey = "MacToGalaxyRevision"
    private static let repository = "repos/ljwoo8942/Mac-to-galaxy"
    private static let bundleID = "io.github.ljwoo8942.MacToGalaxy"

    private struct BundleInfo: Decodable {
        let identifier: String
        let revision: String?

        enum CodingKeys: String, CodingKey {
            case identifier = "CFBundleIdentifier"
            case revision = "MacToGalaxyRevision"
        }
    }

    static func prepare(appAt bundleURL: URL, runningRevision: String?,
                        githubCLI: URL? = nil) throws -> PreparedAppUpdate? {
        let manager = FileManager.default
        let app = bundleURL.resolvingSymlinksInPath()
        let parent = app.deletingLastPathComponent()
        guard app.pathExtension == "app", try info(in: app).identifier == bundleID else {
            throw AppUpdateError("빌드한 Mac-to-galaxy.app을 열어 업데이트하세요.")
        }

        var environment = ProcessInfo.processInfo.environment
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let searchPath = directories + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = searchPath.joined(separator: ":")
        guard let gh = githubCLI ?? searchPath.map({ URL(fileURLWithPath: $0).appendingPathComponent("gh") })
            .first(where: { manager.isExecutableFile(atPath: $0.path) }) else {
            throw AppUpdateError("터미널에서 brew install gh를 실행한 뒤 gh auth login --hostname github.com --web으로 로그인하세요.")
        }
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment.removeValue(forKey: "GH_DEBUG")

        let workspace = try makeDirectory(in: manager.temporaryDirectory)
        defer { try? manager.removeItem(at: workspace) }
        let response = workspace.appendingPathComponent("revision")
        let api = ["api", "--hostname", "github.com"]
        try run(gh, api + ["\(repository)/git/ref/heads/main", "--jq", ".object.sha"], in: workspace,
                environment: environment, output: response,
                failure: "GitHub의 최신 버전을 확인할 수 없습니다. 인터넷과 저장소 접근 권한을 확인하고, 필요하면 gh auth login --hostname github.com --web을 실행하세요.")
        let revision = try String(contentsOf: response, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard revision.utf8.count == 40, revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AppUpdateError("GitHub에서 올바른 커밋 번호를 받지 못했습니다.")
        }
        guard revision != runningRevision else { return nil }

        let lock = try lockUpdate(for: app)
        guard try info(in: app).revision == runningRevision else {
            throw AppUpdateError("디스크에 있는 앱 버전이 바뀌었습니다. 앱을 다시 열어 업데이트를 확인하세요.")
        }
        let archive = workspace.appendingPathComponent("source.tar.gz")
        try run(gh, api + ["\(repository)/tarball/\(revision)"], in: workspace,
                environment: environment, output: archive, failure: "GitHub에서 업데이트 소스를 내려받지 못했습니다.")

        for name in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "BASH_ENV"] {
            environment.removeValue(forKey: name)
        }
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        try manager.createDirectory(at: source, withIntermediateDirectories: false)
        try run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", archive.path, "--strip-components=1", "-C", source.path],
                in: workspace, environment: environment, failure: "업데이트 소스의 압축을 풀지 못했습니다.")
        environment["MAC_TO_GALAXY_REVISION"] = revision
        let buildScript = source.appendingPathComponent("scripts/build-app.sh")
        try run(URL(fileURLWithPath: "/bin/bash"), [buildScript.path], in: workspace, environment: environment,
                timeout: 300, failure: "업데이트 빌드에 실패했습니다. Swift와 Homebrew의 libmtp, pkgconf를 확인하세요.", showBuildError: true)
        let built = source.appendingPathComponent("dist/Mac-to-galaxy.app", isDirectory: true)
        let builtInfo = try info(in: built)
        guard builtInfo.identifier == bundleID, builtInfo.revision == revision,
              manager.isExecutableFile(atPath: built.appendingPathComponent("Contents/MacOS/MacToGalaxy").path) else {
            throw AppUpdateError("새 앱의 실행 파일이나 커밋 번호를 확인할 수 없습니다.")
        }

        let staging = try makeDirectory(in: parent)
        let replacement = staging.appendingPathComponent("Mac-to-galaxy.app", isDirectory: true)
        do {
            try manager.copyItem(at: built, to: replacement)
            try run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", replacement.path],
                    in: workspace, environment: environment, failure: "새 앱의 코드 서명이 유효하지 않습니다.")
            return PreparedAppUpdate(app: app, replacement: replacement, lock: lock)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private static func info(in app: URL) throws -> BundleInfo {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        return try PropertyListDecoder().decode(BundleInfo.self, from: Data(contentsOf: plist))
    }

    private static func makeDirectory(in parent: URL) throws -> URL {
        let directory = parent.appendingPathComponent(".MacToGalaxy-Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private static func lockUpdate(for app: URL) throws -> FileHandle {
        let path = app.deletingLastPathComponent().appendingPathComponent(".\(app.lastPathComponent).update.lock").path
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw AppUpdateError("앱이 있는 폴더에 쓸 수 없습니다. 쓰기 가능한 폴더에 앱을 옮겨 다시 시도하세요.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw AppUpdateError("다른 창에서 이 앱을 업데이트 중입니다.")
        }
        return handle
    }

    private static func run(_ executable: URL, _ arguments: [String], in workspace: URL,
                            environment: [String: String], output: URL? = nil, timeout: Double = 90,
                            failure: String, showBuildError: Bool = false) throws {
        let stdout = output ?? workspace.appendingPathComponent("stdout")
        let stderr = workspace.appendingPathComponent("stderr")
        try Data().write(to: stdout)
        try Data().write(to: stderr)
        let outputFile = try FileHandle(forWritingTo: stdout)
        let errorFile = try FileHandle(forWritingTo: stderr)
        defer {
            try? outputFile.close()
            try? errorFile.close()
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputFile
        process.standardError = errorFile
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning { process.terminate() }
            throw AppUpdateError("\(failure) 응답 시간이 초과되었습니다.")
        }
        guard process.terminationStatus == 0 else {
            let details = showBuildError ? [stdout, stderr].compactMap(lastMessage).first : nil
            throw AppUpdateError([failure, details].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    private static func lastMessage(from url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd(), end > 0 else { return nil }
        try? file.seek(toOffset: end > 8192 ? end - 8192 : 0)
        guard let tail = try? file.read(upToCount: 8192) else { return nil }
        let lines = String(decoding: tail, as: UTF8.self).split(whereSeparator: \.isNewline)
        return lines.reversed().first(where: { $0.contains("error:") }).map { String($0.prefix(500)) }
    }
}
