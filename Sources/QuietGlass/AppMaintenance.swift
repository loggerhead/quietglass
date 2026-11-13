import AppKit
import ServiceManagement
import ShieldCore

@MainActor
final class LoginPreference: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var message: String?
    init() { refresh() }
    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
        needsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func setEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch { message = "Could not change launch at login. Check Login Items in System Settings." }
        refresh()
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

struct ReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        let numbers = pieces.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        parts = numbers
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

@MainActor
final class AppUpdates: ObservableObject {
    private struct Release: Decodable { let tag_name: String; let html_url: String; let draft: Bool; let prerelease: Bool }
    @Published private(set) var checking = false
    @Published private(set) var message = "Check for a newer public release."
    @Published private(set) var downloadPage: URL?
    @Published var automatic: Bool {
        didSet { if !loadingPreferences { writePreference("automaticUpdateChecks", automatic) }; configureTimer(); if !loadingPreferences { checkIfDue() } }
    }
    private var timer: Timer?
    private var loadingPreferences = false
    private var readPreference: (String) -> Any?
    private var writePreference: (String, Any) -> Void
    private let currentVersion: String
    private let fetch: (URLRequest) async throws -> (Data, Int)
    init(preferences: UserDefaults = .standard,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
         fetch: @escaping (URLRequest) async throws -> (Data, Int) = { request in
             let configuration = URLSessionConfiguration.ephemeral
             configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
             configuration.httpShouldSetCookies = false
             let session = URLSession(configuration: configuration)
             defer { session.finishTasksAndInvalidate() }
             let (data, response) = try await session.data(for: request)
             return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
         }) {
        let store = ProtectionStore(storage: preferences)
        self.readPreference = { key in
            guard let document = try? store.loadOrMigrate(),
                  let values = try? PropertyListSerialization.propertyList(from: document.preferences.appearance, format: nil) as? [String: Any] else { return nil }
            return values[key]
        }
        self.writePreference = { key, value in
            guard var document = try? store.loadOrMigrate() else { return }
            var values = (try? PropertyListSerialization.propertyList(from: document.preferences.appearance, format: nil)) as? [String: Any] ?? [:]
            values[key] = value
            guard let appearance = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) else { return }
            document.preferences.appearance = appearance
            try? store.save(document)
        }
        self.currentVersion = currentVersion; self.fetch = fetch
        automatic = readPreference("automaticUpdateChecks") as? Bool ?? false
        configureTimer()
    }
    func useProtectionPreferences(read: @escaping (String) -> Any?, write: @escaping (String, Any) -> Void) {
        readPreference = read; writePreference = write
        refreshPreferences()
    }
    func refreshPreferences() {
        loadingPreferences = true
        automatic = readPreference("automaticUpdateChecks") as? Bool ?? false
        loadingPreferences = false
    }
    private func configureTimer() {
        timer?.invalidate(); timer = nil
        guard automatic else { return }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkIfDue() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func shutdown() { timer?.invalidate(); timer = nil }
    func checkIfDue() {
        guard automatic, Date().timeIntervalSince(readPreference("lastUpdateCheck") as? Date ?? .distantPast) >= 86_400 else { return }
        Task { await check() }
    }
    func check() async {
        guard !checking else { return }
        checking = true; downloadPage = nil; message = "Checking for updates…"
        writePreference("lastUpdateCheck", Date())
        defer { checking = false }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/clintonimaroo/quietglass/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("QuietGlass", forHTTPHeaderField: "User-Agent")
        do {
            let (data, status) = try await fetch(request)
            guard status != 404 else { message = "No public release is available to check yet."; return }
            guard status == 200, data.count <= 1_000_000 else { message = "Update checking is temporarily unavailable. Try again later."; return }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard !release.draft, !release.prerelease,
                  let latest = ReleaseVersion(release.tag_name), let current = ReleaseVersion(currentVersion),
                  let url = URL(string: release.html_url), url.scheme == "https", url.host == "github.com",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.path.hasPrefix("/clintonimaroo/quietglass/releases/tag/") else {
                message = "The release information could not be verified."; return
            }
            writePreference("lastUpdateCheck", Date())
            if latest > current { downloadPage = url; message = QG("QuietGlass %@ is available.", release.tag_name) }
            else { message = "You have the newest available version." }
        } catch { message = "Could not check for updates. Check your connection and try again." }
    }
}
