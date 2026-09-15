import AppKit
import Foundation

/// A version as it appears in a bundle or on a git tag: `1.2.3`, `v1.2`,
/// `0.3.0-rc.1`.
///
/// Compared component by component with the shorter number padded with zeros,
/// so `1.2` and `1.2.0` are the same version. A pre-release suffix sorts below
/// the release it leads to — that is what stops a `v0.3.0-rc.1` build from
/// reading as `0.3.0` and declaring itself up to date once `0.3.0` ships.
struct AppVersion: Comparable, CustomStringConvertible {
    let numbers: [Int]
    let prerelease: String?

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = halves.first, !head.isEmpty else { return nil }
        // Empty components are kept so `1..0` and `1.2.` fail to parse rather
        // than quietly reading as `1.0` and `1.2`.
        let parsed = head.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parsed.isEmpty, !parsed.contains(nil) else { return nil }
        numbers = parsed.compactMap { $0 }
        prerelease = halves.count == 2 && !halves[1].isEmpty ? String(halves[1]) : nil
    }

    var description: String {
        let base = numbers.map(String.init).joined(separator: ".")
        return prerelease.map { "\(base)-\($0)" } ?? base
    }

    private static func aligned(_ lhs: AppVersion, _ rhs: AppVersion) -> ([Int], [Int]) {
        let width = max(lhs.numbers.count, rhs.numbers.count)
        let pad = { (n: [Int]) in n + Array(repeating: 0, count: width - n.count) }
        return (pad(lhs.numbers), pad(rhs.numbers))
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let (l, r) = aligned(lhs, rhs)
        return l == r && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let (l, r) = aligned(lhs, rhs)
        guard l == r else { return l.lexicographicallyPrecedes(r) }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):          return false
        case (.some, nil):        return true
        case (nil, .some):        return false
        case let (l?, r?):        return l < r
        }
    }
}

/// The one release the updater cares about. `releases/latest` already skips
/// drafts and pre-releases, so anything this parses is meant to be installed.
struct GitHubRelease: Equatable {
    let version: AppVersion
    let asset: URL
    let page: URL

    static func == (lhs: GitHubRelease, rhs: GitHubRelease) -> Bool {
        lhs.version == rhs.version && lhs.asset == rhs.asset && lhs.page == rhs.page
    }

    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let downloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }
    }

    /// GitHub answers 404 when a repository has no published releases at all,
    /// which is an ordinary state for a fresh repo and not something to paint
    /// an error over. `nil` means exactly that: nothing to install yet.
    static func parse(status: Int, body: Data) throws -> GitHubRelease? {
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateError.server(status: status) }
        return try parse(body)
    }

    static func parse(_ data: Data) throws -> GitHubRelease {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UpdateError.unreadableRelease
        }
        guard let version = AppVersion(payload.tagName) else {
            throw UpdateError.unreadableRelease
        }
        guard
            let asset = payload.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }),
            let assetURL = URL(string: asset.downloadURL),
            let page = URL(string: payload.htmlURL)
        else {
            throw UpdateError.noArchive(tag: payload.tagName)
        }
        return GitHubRelease(version: version, asset: assetURL, page: page)
    }
}

enum UpdateError: LocalizedError, Equatable {
    case server(status: Int)
    case unreadableRelease
    case noArchive(tag: String)
    case badArchive
    case versionMismatch(promised: String, found: String)
    case notWritable(path: String)
    case commandFailed(tool: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .server(let status):
            return "GitHub replied \(status)"
        case .unreadableRelease:
            return "Couldn't read the latest release"
        case .noArchive(let tag):
            return "Release \(tag) has no .zip to install"
        case .badArchive:
            return "The download wasn't a usable ClaudeBar"
        case .versionMismatch(let promised, let found):
            return "Release says \(promised) but the app inside is \(found)"
        case .notWritable(let path):
            return "Can't write to \(path)"
        case .commandFailed(let tool, let status):
            return "\(tool) failed (\(status))"
        }
    }
}

/// Keeps the installed copy current against this repo's GitHub releases.
///
/// Checks shortly after launch and hourly after that, and — because the whole
/// point is a menu bar app you never think about — downloads, swaps and
/// relaunches without asking. The swap itself can't be done from inside the
/// process being replaced, so it is handed to a short shell script that waits
/// for this app to exit first; see `swapScript`.
///
/// This is the app's only network access. Turning `automatic` off stops the
/// hourly check entirely, leaving the Status tab's button as the only way an
/// update ever happens.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        /// A newer release is waiting on the user, because automatic updates
        /// are off and they asked for a check by hand.
        case available(String)
        case downloading(String)
        case installing(String)
        case relaunching
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?
    /// Set when a newer release exists but this copy can't replace itself —
    /// a read-only `/Applications`, say. The UI offers the release page.
    private(set) var manualDownload: URL?

    var automatic: Bool {
        didSet {
            guard automatic != oldValue else { return }
            defaults.set(automatic, forKey: Self.automaticKey)
            if automatic { start() } else { stop() }
        }
    }

    let currentVersion: AppVersion

    private static let repository = "ThomasHaas15/ClaudeBar"
    private static let automaticKey = "ClaudeBar.autoUpdate.enabled"
    private static let checkInterval: TimeInterval = 60 * 60
    private static let settleDelay: TimeInterval = 30

    private let defaults: UserDefaults
    private var timer: Timer?
    private var busy = false

    /// Patient, for the hourly check: `waitsForConnectivity` parks the request
    /// until the Mac has a network again rather than failing on a closed lid,
    /// which is what makes a check survive a laptop that spent the hour asleep.
    private let background: URLSession
    /// Short-fused, for the button, so "Check now" reports back instead of
    /// hanging silently while offline.
    private let interactive: URLSession

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.automaticKey) == nil {
            defaults.set(true, forKey: Self.automaticKey)
        }
        automatic = defaults.bool(forKey: Self.automaticKey)

        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        currentVersion = AppVersion(raw) ?? AppVersion("0")!

        let patient = URLSessionConfiguration.ephemeral
        patient.waitsForConnectivity = true
        patient.timeoutIntervalForRequest = 60
        patient.timeoutIntervalForResource = 15 * 60
        background = URLSession(configuration: patient)

        let prompt = URLSessionConfiguration.ephemeral
        prompt.waitsForConnectivity = false
        prompt.timeoutIntervalForRequest = 20
        prompt.timeoutIntervalForResource = 5 * 60
        interactive = URLSession(configuration: prompt)
    }

    // MARK: - Schedule

    func start() {
        #if DEBUG
        // A debug build runs out of DerivedData. Replacing that bundle with a
        // release would be a strange thing to do to someone mid-edit.
        return
        #else
        guard automatic, timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.check() }
        }
        timer.tolerance = 5 * 60
        self.timer = timer

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleDelay))
            await self?.check()
        }
        #endif
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Check

    /// Looks for a newer release. Installs it straight away unless automatic
    /// updates are off, in which case the answer is handed to the UI.
    func check(userInitiated: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        state = .checking
        manualDownload = nil
        do {
            let release = try await latestRelease(userInitiated: userInitiated)
            lastChecked = Date()
            guard let release, release.version > currentVersion else {
                state = .idle
                return
            }
            guard automatic else {
                state = .available(release.version.description)
                manualDownload = release.page
                return
            }
            try await install(release)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Installs a release the user asked for from the Status tab.
    func installAvailable() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let release = try await latestRelease(userInitiated: true)
            guard let release, release.version > currentVersion else {
                state = .idle
                return
            }
            try await install(release)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func latestRelease(userInitiated: Bool) async throws -> GitHubRelease? {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let session = userInitiated ? interactive : background
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.unreadableRelease }
        return try GitHubRelease.parse(status: http.statusCode, body: data)
    }

    // MARK: - Install

    private func install(_ release: GitHubRelease) async throws {
        let installed = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path) else {
            manualDownload = release.page
            throw UpdateError.notWritable(path: installed.deletingLastPathComponent().path)
        }

        let stage = try stagingDirectory()
        do {
            state = .downloading(release.version.description)
            let archive = try await download(release.asset, into: stage)

            state = .installing(release.version.description)
            let app = try unpack(archive, in: stage)
            try validate(app, against: release.version)

            state = .relaunching
            try swapAndRelaunch(to: app, at: installed, stage: stage)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    private func stagingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudebar-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func download(_ asset: URL, into stage: URL) async throws -> URL {
        var request = URLRequest(url: asset)
        request.setValue("ClaudeBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await background.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.server(status: http.statusCode)
        }
        // The file URL `download(for:)` hands back is deleted the moment this
        // call returns, so it has to be moved before anything else happens.
        let archive = stage.appendingPathComponent("ClaudeBar.zip")
        try FileManager.default.moveItem(at: temporary, to: archive)
        return archive
    }

    private func unpack(_ archive: URL, in stage: URL) throws -> URL {
        let unpacked = stage.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])

        let contents = try FileManager.default.contentsOfDirectory(
            at: unpacked,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let apps = contents.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw UpdateError.badArchive }
        return app
    }

    /// The trust boundary, such as it is: the archive came over TLS from a
    /// fixed repository path, and what came out of it has to be this app, at
    /// the version the tag promised, with an intact signature. `codesign`
    /// catches a bundle that arrived incomplete — worth knowing *before* the
    /// installed copy is deleted, rather than after.
    private func validate(_ app: URL, against version: AppVersion) throws {
        guard
            let bundle = Bundle(url: app),
            bundle.bundleIdentifier == Bundle.main.bundleIdentifier
        else { throw UpdateError.badArchive }

        guard
            let raw = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            let found = AppVersion(raw)
        else { throw UpdateError.badArchive }

        guard found == version else {
            throw UpdateError.versionMismatch(promised: version.description, found: found.description)
        }

        try run("/usr/bin/codesign", ["--verify", "--strict", app.path])
    }

    private func swapAndRelaunch(to app: URL, at installed: URL, stage: URL) throws {
        let script = stage.appendingPathComponent("swap.sh")
        try Self.swapScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            app.path,
            installed.path,
            stage.path
        ]
        try process.run()

        // The script is waiting on this pid; once the app exits launchd adopts
        // it and it finishes the swap.
        NSApp.terminate(nil)
    }

    /// Runs after this app has quit, so it can replace the bundle the app was
    /// running from.
    ///
    /// Copies the new bundle onto the destination volume *before* disturbing
    /// the installed one, so the moment where `/Applications/ClaudeBar.app`
    /// doesn't exist is two renames long rather than the length of a copy. A
    /// script that dies at any point leaves either the old app or the new one
    /// installed; the outcome worth ruling out is a Mac with no ClaudeBar.
    nonisolated static let swapScript = #"""
    #!/bin/sh
    # ClaudeBar updater — written into a temp directory by the app and deleted
    # when it finishes. Arguments: <pid> <new .app> <installed .app> <staging dir>
    PID="$1"
    NEW="$2"
    DST="$3"
    STAGE="$4"

    DIR="$(dirname "$DST")"
    NAME="$(basename "$DST")"
    STAGED="$DIR/.$NAME.new-$$"
    BACKUP="$DIR/.$NAME.old-$$"

    # Injectable so the failure paths can be tested without launching anything;
    # unset everywhere else, which is the app's own case.
    OPEN="${CLAUDEBAR_OPEN:-/usr/bin/open}"

    # Anything left by a previous run that didn't reach its own cleanup.
    rm -rf "$DIR/.$NAME".new-* "$DIR/.$NAME".old-* 2>/dev/null

    give_up() {
      rm -rf "$STAGED"
      "$OPEN" "$DST"
      rm -rf "$STAGE"
      exit 1
    }

    # Wait for the old copy to go. It was told to quit, but a menu bar app can
    # take a beat to unwind.
    i=0
    while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 100 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    kill -9 "$PID" 2>/dev/null

    # Land the new bundle on the destination volume first. Nothing installed has
    # been touched yet, so a failure here costs only the copy.
    /usr/bin/ditto "$NEW" "$STAGED" || give_up

    # The app downloaded this itself, so it carries no quarantine flag — but an
    # archive that reached the staging directory another way would, and
    # Gatekeeper refuses an ad-hoc signed bundle that has one.
    #
    # macOS `xattr` has no recursive flag, whatever `xattr -dr` suggests: it
    # exits 64 and removes nothing. find feeds it one path at a time instead.
    /usr/bin/find "$STAGED" -print0 2>/dev/null \
      | /usr/bin/xargs -0 /usr/bin/xattr -d com.apple.quarantine 2>/dev/null \
      || true

    /bin/mv "$DST" "$BACKUP" || give_up
    if ! /bin/mv "$STAGED" "$DST"; then
      /bin/mv "$BACKUP" "$DST"
      give_up
    fi

    rm -rf "$BACKUP"
    "$OPEN" "$DST"
    rm -rf "$STAGE"
    """#

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drained before waiting, so a chatty tool can't fill the pipe and hang.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(
                tool: (tool as NSString).lastPathComponent,
                status: process.terminationStatus
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}
