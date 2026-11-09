import Foundation
import AppKit
import CryptoKit
import Security
import os

/// Checks GitHub Releases for a newer version and installs it in place ("Update" in the panel).
///
/// Installing: download the release's zip of the app (`FreeAudio-x.y.zip`; the DMG is for
/// manual installs: a mounted image is a removable volume, which FreeAudio may not read), check
/// its SHA-256 against the release's `.zip.sha256` file, check that the app inside is the same
/// app (bundle ID, version) signed with FreeAudio's certificate (pinned in the binary), swap the
/// app bundle, and relaunch. A file FreeAudio downloads itself isn't
/// quarantined, so the new version opens without the Gatekeeper prompt, and the stable
/// certificate keeps the System Audio Recording and Accessibility permissions. When the app
/// can't replace itself (read-only location, missing release files), the banner only links to
/// the release page.
@MainActor
final class UpdateService: ObservableObject, @unchecked Sendable {
    static let shared = UpdateService()

    enum InstallState: Equatable {
        case idle
        case downloading
        case installing
        case failed(String)
    }

    // GitHub repository whose latest release is compared with the running version.
    private let repoOwner = "hakanotal"
    private let repoName  = "FreeAudio"

    // Current app bundle version (CFBundleShortVersionString)
    let currentVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }()

    /// Passed to the copy started after an update, so it replaces the running one (AppDelegate).
    nonisolated static let relaunchArgument = "--after-update"
    nonisolated static var isRelaunchAfterUpdate: Bool {
        CommandLine.arguments.contains(relaunchArgument)
    }

    @Published var latestVersion: String? = nil
    @Published var releaseURL: URL? = nil
    @Published var hasUpdate: Bool = false
    @Published var lastCheckDate: Date? = nil
    /// Whether "Update" can install the latest release here (release files found, app folder
    /// writable). Otherwise the banner only links to the release page.
    @Published private(set) var canInstall = false
    @Published private(set) var installState: InstallState = .idle

    private var archiveURL: URL?
    private var checksumURL: URL?
    private var isChecking = false
    private var periodicTimer: Timer?
    /// The app can run for weeks: check again this often while it does.
    private static let periodicInterval: TimeInterval = 6 * 3600

    private init() {}

    /// Update checks and downloads bypass the URL cache: a cached reply (or a 304 for a
    /// revalidated one) must never stand in for the current release or its files.
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Each update step and failure, for bug reports: `log show --predicate 'subsystem == "com.freeaudio.app"'`.
    private nonisolated static let log = Logger(subsystem: "com.freeaudio.app", category: "update")

    // MARK: - Check for Updates

    func checkForUpdates() async {
        if let last = lastCheckDate, Date().timeIntervalSince(last) < 3600 { return }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10
            let (data, response) = try await Self.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                // Repo may not exist yet; silently ignore
                lastCheckDate = Date()
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                lastCheckDate = Date()
                return
            }
            if let tag = json["tag_name"] as? String {
                let clean = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                latestVersion = clean
                releaseURL = (json["html_url"] as? String).flatMap { URL(string: $0) }
                hasUpdate = isNewerVersion(clean, than: currentVersion)
                let assets = json["assets"] as? [[String: Any]] ?? []
                archiveURL = Self.assetURL(in: assets, suffix: ".zip")
                checksumURL = Self.assetURL(in: assets, suffix: ".zip.sha256")
                canInstall = hasUpdate && archiveURL != nil && checksumURL != nil && Self.canReplaceRunningApp()
                Self.log.info("Latest release \(clean, privacy: .public): update=\(self.hasUpdate) canInstall=\(self.canInstall)")
            }
            lastCheckDate = Date()
        } catch is CancellationError {
            // Cancelled (e.g. the panel closed): try again next time, not in an hour.
        } catch let error as URLError where error.code == .cancelled {
            // Same as above.
        } catch {
            // Network unavailable or repo doesn't exist: silently ignore
            lastCheckDate = Date()
        }
    }

    /// Checks again every few hours while the app runs (when update checks are on).
    func startPeriodicChecks() {
        guard periodicTimer == nil else { return }
        let timer = Timer(timeInterval: Self.periodicInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard SettingsService.shared.checkUpdatesOnLaunch else { return }
                Task { await UpdateService.shared.checkForUpdates() }
            }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer
    }

    private static func assetURL(in assets: [[String: Any]], suffix: String) -> URL? {
        assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap { URL(string: $0) }
    }

    /// The running app can swap itself only when it can rename its bundle (not in a
    /// read-only or translocated location, user has write access to the folder).
    private static func canReplaceRunningApp() -> Bool {
        let app = Bundle.main.bundleURL
        let fileManager = FileManager.default
        return app.pathExtension == "app"
            && !app.path.contains("/AppTranslocation/")
            && fileManager.isWritableFile(atPath: app.path)
            && fileManager.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    // MARK: - Version Comparison

    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let remoteComponents = remote.split(separator: ".").compactMap { Int($0) }
        let localComponents  = local.split(separator: ".").compactMap { Int($0) }
        let length = max(remoteComponents.count, localComponents.count)
        for i in 0..<length {
            let r = i < remoteComponents.count ? remoteComponents[i] : 0
            let l = i < localComponents.count  ? localComponents[i]  : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    // MARK: - Open Release Page

    func openReleasePage() {
        guard let url = releaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Install

    /// Downloads, verifies and installs the latest release, then relaunches into it.
    func installUpdate() async {
        guard canInstall, let archiveURL, let checksumURL, let version = latestVersion else { return }
        switch installState {
        case .downloading, .installing: return
        case .idle, .failed: break
        }
        installState = .downloading
        let appURL = Bundle.main.bundleURL
        do {
            let staged = try await Self.downloadAndVerify(archive: archiveURL, checksum: checksumURL,
                                                          version: version, nextTo: appURL)
            installState = .installing
            Self.log.info("Update \(version, privacy: .public) verified; installing")
            // The relaunch may end this process without applicationWillTerminate.
            SettingsService.shared.flushPendingSaves()
            try await Task.detached(priority: .userInitiated) {
                try Self.replace(appURL, with: staged)
            }.value
            relaunch(appURL)
        } catch {
            Self.log.error("Update to \(version, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            installState = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    /// Opens the installed (new) app through LaunchServices; it replaces this copy (AppDelegate).
    /// Not through the launch agent: launchd's first start of a newly written app is refused by
    /// macOS (Launch Constraint Violation) and only its retry 10 s later succeeds. The agent
    /// starts the new version at the next login.
    private func relaunch(_ appURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [Self.relaunchArgument]
        // @Sendable: NSWorkspace calls this off the main thread.
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { @Sendable _, error in
            guard let error else { return }
            Task { @MainActor in
                Self.log.error("Opening the new version failed: \(String(describing: error), privacy: .public)")
                // launchd can still start it (after its retry), else the user reopens it.
                if LaunchService.isManagedLaunch, LaunchService.shared.restartAgent() { return }
                UpdateService.shared.installState = .failed(
                    L("Güncelleme kuruldu; FreeAudio'yu yeniden açın", "Update installed; reopen FreeAudio"))
            }
        }
    }

    enum UpdateError: Error {
        case download, checksum, unpack, notTheApp, signature, copy

        var message: String {
            switch self {
            case .download: return L("İndirilemedi, tekrar deneyin", "Download failed, please try again")
            case .checksum: return L("İndirilen dosya bozuk, tekrar deneyin", "The download is damaged, please try again")
            case .unpack: return L("Güncelleme dosyası açılamadı", "Couldn't open the update")
            case .notTheApp: return L("Güncelleme beklenen sürümü içermiyor", "The update doesn't contain the expected version")
            case .signature: return L("Güncellemenin imzası doğrulanamadı; sürüm sayfasından indirin",
                                      "The update's signature couldn't be verified; download it from the release page")
            case .copy: return L("Güncelleme kurulamadı", "Couldn't install the update")
            }
        }
    }

    /// An update unpacked next to the app, ready to swap in.
    struct StagedUpdate: Sendable {
        let app: URL
        /// Scratch folder holding `app`; removed after the swap.
        let folder: URL
    }

    /// Downloads the zip into a scratch folder on the app's volume (so the final swap is a
    /// rename), checks it and unpacks the app.
    private nonisolated static func downloadAndVerify(archive: URL, checksum: URL, version: String,
                                                      nextTo appURL: URL) async throws -> StagedUpdate {
        let fileManager = FileManager.default
        let work = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                       appropriateFor: appURL, create: true)
        do {
            // The release's "<sha256>  FreeAudio-x.y.zip" line.
            let (sumData, sumResponse) = try await session.data(from: checksum)
            guard (sumResponse as? HTTPURLResponse)?.statusCode == 200,
                  let expected = String(decoding: sumData, as: UTF8.self)
                    .split(whereSeparator: \.isWhitespace).first?.lowercased(),
                  expected.count == 64 else { throw UpdateError.download }

            let (downloaded, response) = try await session.download(from: archive)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
            let zip = work.appendingPathComponent("update.zip")
            try fileManager.moveItem(at: downloaded, to: zip)
            let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
            guard digest.map({ String(format: "%02x", $0) }).joined() == expected else { throw UpdateError.checksum }

            // ditto keeps the bundle's symlinks, permissions and signature intact.
            let unpacked = work.appendingPathComponent("unpacked")
            guard await run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) else { throw UpdateError.unpack }
            try? fileManager.removeItem(at: zip)

            guard let newApp = try fileManager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }),
                  let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  info["CFBundleShortVersionString"] as? String == version else { throw UpdateError.notTheApp }
            try verifySignature(of: newApp)
            return StagedUpdate(app: newApp, folder: work)
        } catch {
            try? fileManager.removeItem(at: work)
            throw error
        }
    }

    /// SHA-1 of FreeAudio's code-signing certificate ("FreeAudio Code Signing",
    /// docs/SIGNING-AND-UPDATES.md). Pinned in the binary, so every copy, including one a
    /// contributor signed ad hoc, only installs updates signed with it. A new certificate needs a
    /// new value here, and users of older versions then update by hand once.
    private nonisolated static let releaseCertificateSHA1 = "8f91f55ba1b09414250a4eba77c5370be81ae910"

    /// The app must be validly signed (strict, nested code) by FreeAudio's certificate, with
    /// the running app's bundle identifier.
    private nonisolated static func verifySignature(of app: URL) throws {
        guard let identifier = Bundle.main.bundleIdentifier else { throw UpdateError.signature }
        let requirementText = "identifier \"\(identifier)\" and certificate leaf = H\"\(releaseCertificateSHA1)\""
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.signature
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures)
                               | UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckNestedCode))
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError.signature
        }
    }

    /// Swaps the app bundle for the staged one (same volume: an atomic rename). The running
    /// process keeps using the old files until it exits.
    private nonisolated static func replace(_ appURL: URL, with staged: StagedUpdate) throws {
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: staged.folder) }
        do {
            _ = try fileManager.replaceItemAt(appURL, withItemAt: staged.app, backupItemName: nil,
                                              options: .usingNewMetadataOnly)
        } catch {
            log.error("Replacing the app failed: \(String(describing: error), privacy: .public)")
            throw UpdateError.copy
        }
    }

    /// Runs a command-line tool and reports whether it exited with status 0.
    private nonisolated static func run(_ tool: String, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // @Sendable: Process calls this on a background thread.
            process.terminationHandler = { @Sendable in continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
