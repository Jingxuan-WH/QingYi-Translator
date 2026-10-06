import CryptoKit
import Foundation

/// A version published on GitHub Releases.
public struct ReleaseInfo: Equatable {
    public let version: SemanticVersion
    public let tag: String
    public let notes: String
    public let pageUrl: String
    public let downloadUrl: String
    public let size: Int64
    /// Hex digest GitHub reports for the asset; nil for assets uploaded before GitHub added digests.
    public let sha256: String?
    public let publishedAt: Date?

    public init(version: SemanticVersion, tag: String, notes: String, pageUrl: String, downloadUrl: String, size: Int64, sha256: String?, publishedAt: Date?) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.pageUrl = pageUrl
        self.downloadUrl = downloadUrl
        self.size = size
        self.sha256 = sha256
        self.publishedAt = publishedAt
    }

    public var versionText: String { version.description }
}

public struct UpdateError: Error, LocalizedError {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

/// Checks GitHub Releases for a newer version and downloads it.
public enum UpdateService {
    public static let repository = "Jingxuan-WH/QingYi-Translator"
    public static let assetName = "QingYiTranslator-mac.zip"
    public static let releasesPage = "https://github.com/\(repository)/releases/latest"

    // TRANSLATOR_UPDATE_URL points the check at a local test server; downloads are then allowed from that server only.
    private static let testApiUrl: String? = {
        guard let url = ProcessInfo.processInfo.environment["TRANSLATOR_UPDATE_URL"], !url.isEmpty else { return nil }
        return url
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "QingYiTranslator/\(AppInfo.versionText) (macOS)"]
        return URLSession(configuration: config)
    }()

    public static var currentVersion: SemanticVersion { AppInfo.version }

    private static var apiUrl: String { testApiUrl ?? "https://api.github.com/repos/\(repository)/releases/latest" }

    /// The latest release, or nil when none has a macOS build. Throws `UpdateError` on failure.
    public static func getLatest() async throws -> ReleaseInfo? {
        guard let url = URL(string: apiUrl) else { throw UpdateError(L("无法读取版本信息。", "Could not read the release information.")) }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UpdateError(L("无法连接到 GitHub，请检查网络后重试。", "Could not reach GitHub. Please check your network and try again."))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            return nil // nothing published yet
        }
        if status == 403 || status == 429 {
            throw UpdateError(L("GitHub 访问次数过多，请过一会儿再试。", "Too many requests to GitHub. Please try again later."))
        }
        guard (200...299).contains(status) else {
            throw UpdateError(L("GitHub 返回错误（HTTP \(status)）。", "GitHub returned an error (HTTP \(status))."))
        }
        do {
            return try parseRelease(data)
        } catch {
            throw UpdateError(L("无法读取版本信息。", "Could not read the release information."))
        }
    }

    /// Reads a GitHub "release" object. Drafts, pre-releases and releases without the macOS asset are ignored.
    public static func parseRelease(_ json: Data) throws -> ReleaseInfo? {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true {
            return nil
        }
        let tag = root["tag_name"] as? String ?? ""
        guard let version = tryParseVersion(tag) else { return nil }

        var downloadUrl: String?
        var sha256: String?
        var size: Int64 = 0
        for asset in root["assets"] as? [[String: Any]] ?? [] {
            guard (asset["name"] as? String)?.caseInsensitiveCompare(assetName) == .orderedSame else { continue }
            downloadUrl = asset["browser_download_url"] as? String
            if let s = asset["size"] as? NSNumber {
                size = s.int64Value
            }
            if let digest = asset["digest"] as? String, digest.lowercased().hasPrefix("sha256:") {
                sha256 = String(digest.dropFirst("sha256:".count))
            }
            break
        }
        guard let url = downloadUrl, isTrustedDownload(url) else { return nil }

        var published: Date?
        if let at = root["published_at"] as? String {
            published = JSONDates.parse(at)
        }
        return ReleaseInfo(version: version, tag: tag, notes: (root["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           pageUrl: root["html_url"] as? String ?? releasesPage, downloadUrl: url, size: size, sha256: sha256, publishedAt: published)
    }

    public static func tryParseVersion(_ tag: String?) -> SemanticVersion? { SemanticVersion.parse(tag) }

    public static func isNewer(_ release: ReleaseInfo) -> Bool { release.version > currentVersion }

    /// Downloads the release to `path`, checking its size, file type and SHA-256 digest.
    public static func download(_ release: ReleaseInfo, to path: URL, progress: ((Double) -> Void)?) async throws {
        guard let url = URL(string: release.downloadUrl) else { throw UpdateError(L("下载地址无效。", "The download URL is invalid.")) }
        do {
            try await Timeouts.run(seconds: 300) {
                let (bytes, response) = try await session.bytes(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(status) else {
                    throw UpdateError(L("下载失败（HTTP \(status)）。", "Download failed (HTTP \(status))."))
                }
                let total = response.expectedContentLength > 0 ? response.expectedContentLength : release.size
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path.path, contents: nil)
                let handle = try FileHandle(forWritingTo: path)
                defer { try? handle.close() }

                var hasher = SHA256()
                var received: Int64 = 0
                var head: [UInt8] = []
                var buffer = Data()
                buffer.reserveCapacity(65536)
                for try await byte in bytes {
                    if head.count < 2 {
                        head.append(byte)
                    }
                    buffer.append(byte)
                    if buffer.count >= 65536 {
                        try handle.write(contentsOf: buffer)
                        hasher.update(data: buffer)
                        received += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                        if total > 0 {
                            progress?(min(1, Double(received) / Double(total)))
                        }
                    }
                }
                if !buffer.isEmpty {
                    try handle.write(contentsOf: buffer)
                    hasher.update(data: buffer)
                    received += Int64(buffer.count)
                }
                progress?(1)

                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                let valid = received > 0 && head == [0x50, 0x4B] // "PK": a zip archive
                    && (release.size <= 0 || received == release.size)
                    && (release.sha256 == nil || digest.caseInsensitiveCompare(release.sha256!) == .orderedSame)
                if !valid {
                    throw UpdateError(L("下载的文件不完整或校验失败，请重试。", "The downloaded file is incomplete or failed verification. Please try again."))
                }
            }
        } catch let error as UpdateError {
            try? FileManager.default.removeItem(at: path)
            throw error
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: path)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: path)
            throw UpdateError(L("下载中断，请检查网络后重试。", "The download was interrupted. Please check your network and try again."))
        }
    }

    // Only files attached to this repository's releases are installed (or files from the test server, when one is set).
    static func isTrustedDownload(_ url: String) -> Bool {
        guard let uri = URL(string: url), let host = uri.host else { return false }
        if let test = testApiUrl, let testUri = URL(string: test) {
            return host == testUri.host && uri.port == testUri.port
        }
        return uri.scheme == "https" && host == "github.com"
            && uri.path.lowercased().hasPrefix("/\(repository.lowercased())/releases/download/")
    }
}

public struct TimeoutError: Error {}

public enum Timeouts {
    /// Runs `operation`, giving up with `TimeoutError` after `seconds`.
    public static func run<T>(seconds: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            guard let result = try await group.next() else { throw TimeoutError() }
            group.cancelAll()
            return result
        }
    }
}
