import AppKit
import SwiftUI
import UserNotifications

struct DaemonSnapshot: Decodable {
    struct Quota: Decodable {
        let source: String
        let email: String
        let plan: String
        let primary_used: String
        let primary_remaining: String
        let primary_reset: String
        let primary_window: String
        let secondary_used: String
        let secondary_remaining: String
        let secondary_reset: String
        let secondary_window: String
    }

    struct Counts: Decodable {
        let accounts: Int
        let logged_in: Int
        let ready: Int
        let disabled: Int
        let cooldowns: Int
    }

    struct HotSession: Decodable {
        let running: Bool
        let account: String?
        let last_action: String?
    }

    struct AutoSwitchEvent: Decodable {
        let id: String
        let from_account: String
        let to_account: String
        let reason: String
    }

    struct AutoSwitch: Decodable {
        let enabled: Bool
        let interval_seconds: Int
        let event: AutoSwitchEvent?
    }

    struct Account: Decodable, Identifiable {
        let id: String
        let alias: String?
        let display_name: String
        let logged_in: Bool
        let disabled: Bool
        let disabled_reason: String?
        let cooldown_until: Int?
        let status: String
        let quota: Quota?
        let auth_storage: String
        let hot_active: Bool
    }

    let generated_at_epoch: Int
    let routing_strategy: String
    let last_account: String?
    let counts: Counts
    let accounts: [Account]
    let hot: HotSession?
    let auto_switch: AutoSwitch
}

@MainActor
final class StatusStore: ObservableObject {
    @Published var snapshot: DaemonSnapshot?
    @Published var lastError: String?
    @Published var switchingAccountID: String?
    @Published var autoSwitchUpdating = false
    @Published var daemonLaunching = false

    private let daemonURL: URL
    private var timer: Timer?
    private var lastAutoSwitchEventID: String?
    private let notificationsEnabled: Bool
    private var daemonProcess: Process?
    private var lastDaemonLaunchAttemptAt: Date?

    init() {
        let rawURL = ProcessInfo.processInfo.environment["CODEX_MENUBAR_DAEMON_URL"]
            ?? ProcessInfo.processInfo.environment["CODEX_ORBIT_DAEMON_URL"]
            ?? "http://127.0.0.1:8787"
        self.daemonURL = URL(string: rawURL) ?? URL(string: "http://127.0.0.1:8787")!
        self.notificationsEnabled = Bundle.main.bundleURL.pathExtension == "app"
        if notificationsEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        }

        Task { await refresh() }
        self.timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    var badgeText: String {
        guard let snapshot else { return "?" }
        if let activeAccount = snapshot.hot?.account,
           let account = snapshot.accounts.first(where: { $0.id == activeAccount }),
           let remaining = Self.percentValue(account.quota?.primary_remaining) {
            return "\(Int(remaining))"
        }
        return "\(snapshot.counts.ready)"
    }

    var canStartDaemon: Bool {
        daemonURL.host.map(Self.isLoopbackHost) == true && daemonScriptURL() != nil
    }

    func refresh() async {
        _ = await loadSnapshot()
    }

    func startDaemon() async {
        guard canStartDaemon else { return }
        _ = await ensureDaemonRunning(force: true)
        _ = await loadSnapshot(allowDaemonLaunch: false)
    }

    func switchAccount(_ accountID: String) async {
        switchingAccountID = accountID
        defer { switchingAccountID = nil }
        await postSnapshot(path: "/v1/switch", body: ["account": accountID])
    }

    func setAutoSwitch(enabled: Bool) async {
        autoSwitchUpdating = true
        defer { autoSwitchUpdating = false }
        await post(path: "/v1/auto-switch", body: ["enabled": enabled])
        _ = await loadSnapshot()
    }

    @discardableResult
    private func loadSnapshot(allowDaemonLaunch: Bool = true) async -> Bool {
        do {
            let statusURL = daemonURL.appending(path: "/v1/status")
            let (data, response) = try await URLSession.shared.data(from: statusURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                lastError = "Daemon unavailable"
                return false
            }
            let decoded = try JSONDecoder().decode(DaemonSnapshot.self, from: data)
            snapshot = decoded
            handleNotifications(snapshot: decoded)
            lastError = nil
            daemonLaunching = false
            return true
        } catch {
            if allowDaemonLaunch, await ensureDaemonRunning() {
                return await loadSnapshot(allowDaemonLaunch: false)
            }
            lastError = daemonLaunching ? "Starting local daemon…" : error.localizedDescription
            return false
        }
    }

    private func postSnapshot(path: String, body: [String: Any]) async {
        do {
            var request = URLRequest(url: daemonURL.appending(path: path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = payload["error"] as? String {
                    lastError = error
                } else {
                    lastError = "Request failed"
                }
                return
            }
            let decoded = try JSONDecoder().decode(DaemonSnapshot.self, from: data)
            snapshot = decoded
            handleNotifications(snapshot: decoded)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func post(path: String, body: [String: Any]) async {
        do {
            var request = URLRequest(url: daemonURL.appending(path: path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = payload["error"] as? String {
                    lastError = error
                } else {
                    lastError = "Request failed"
                }
                return
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleNotifications(snapshot: DaemonSnapshot) {
        guard notificationsEnabled else { return }
        guard let event = snapshot.auto_switch.event else { return }
        guard event.id != lastAutoSwitchEventID else { return }
        lastAutoSwitchEventID = event.id
        let content = UNMutableNotificationContent()
        content.title = "Codex Menu Bar"
        content.body = "Auto-switched from \(event.from_account) to \(event.to_account)."
        let request = UNNotificationRequest(
            identifier: "codex-menubar.auto-switch.\(event.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated static func percentValue(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw) else { return nil }
        return min(max(value, 0), 100)
    }

    nonisolated static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1"
    }

    private func ensureDaemonRunning(force: Bool = false) async -> Bool {
        guard canStartDaemon else { return false }
        if daemonLaunching { return await waitForDaemonReady() }
        if !force,
           let lastAttempt = lastDaemonLaunchAttemptAt,
           Date().timeIntervalSince(lastAttempt) < 5 {
            return false
        }

        guard let scriptURL = daemonScriptURL() else { return false }

        daemonLaunching = true
        lastDaemonLaunchAttemptAt = Date()

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = daemonLaunchArguments(scriptURL: scriptURL)
            process.standardInput = nil
            process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            process.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try process.run()
            daemonProcess = process
        } catch {
            daemonLaunching = false
            lastError = error.localizedDescription
            return false
        }

        let ready = await waitForDaemonReady()
        daemonLaunching = false
        return ready
    }

    private func waitForDaemonReady() async -> Bool {
        for _ in 0..<20 {
            do {
                let (data, response) = try await URLSession.shared.data(from: daemonURL.appending(path: "/health"))
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200,
                   !data.isEmpty {
                    return true
                }
            } catch {
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func daemonLaunchArguments(scriptURL: URL) -> [String] {
        var args = [
            "python3",
            scriptURL.path,
            "serve",
            "--host",
            daemonURL.host ?? "127.0.0.1",
            "--port",
            String(daemonURL.port ?? 8787),
        ]

        if let cxBinary = cxBinaryPath() {
            args.append(contentsOf: ["--cx-path", cxBinary])
        }

        return args
    }

    private func daemonScriptURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default

        for key in ["CODEX_MENUBAR_DAEMON_SCRIPT", "CODEX_ORBIT_DAEMON_SCRIPT"] {
            if let value = env[key], fileManager.isReadableFile(atPath: value) {
                return URL(fileURLWithPath: value)
            }
        }

        for root in searchRoots() {
            let candidate = root.appendingPathComponent("libexec/codex-orbit-daemon.py")
            if fileManager.isReadableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private func cxBinaryPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default

        for key in ["CODEX_MENUBAR_CX_BIN", "CODEX_ORBIT_DAEMON_CX", "CODEX_ORBIT_CX_BIN"] {
            if let value = env[key], fileManager.isExecutableFile(atPath: value) {
                return value
            }
        }

        for root in searchRoots() {
            let candidate = root.appendingPathComponent("bin/cx")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }

        if let pathValue = env["PATH"] {
            for entry in pathValue.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent("cx")
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate.path
                }
            }
        }

        return nil
    }

    private func searchRoots() -> [URL] {
        var roots: [URL] = []
        let fileManager = FileManager.default

        roots.append(contentsOf: ancestors(of: URL(fileURLWithPath: fileManager.currentDirectoryPath)))
        if let executable = Bundle.main.executableURL {
            roots.append(contentsOf: ancestors(of: executable.deletingLastPathComponent()))
        }
        roots.append(contentsOf: ancestors(of: Bundle.main.bundleURL))

        var deduped: [URL] = []
        var seen = Set<String>()
        for root in roots {
            let key = root.standardizedFileURL.path
            if seen.insert(key).inserted {
                deduped.append(root)
            }
        }
        return deduped
    }

    private func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        while current.path != "/" && !current.path.isEmpty {
            result.append(current)
            current.deleteLastPathComponent()
        }
        result.append(current)
        return result
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

extension DaemonSnapshot.Account {
    var primaryRemainingPercent: Double { StatusStore.percentValue(quota?.primary_remaining) ?? 0 }
    var secondaryRemainingPercent: Double { StatusStore.percentValue(quota?.secondary_remaining) ?? 0 }
    var primaryUsedPercent: Double { StatusStore.percentValue(quota?.primary_used) ?? max(0, 100 - primaryRemainingPercent) }
    var secondaryUsedPercent: Double { StatusStore.percentValue(quota?.secondary_used) ?? max(0, 100 - secondaryRemainingPercent) }

    var planLabel: String {
        let rawPlan = quota?.plan.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rawPlan.isEmpty ? "Codex" : rawPlan
    }

    var sourceLabel: String {
        let rawSource = quota?.source.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rawSource.isEmpty ? "orbit" : rawSource
    }

    var accountEmail: String? {
        let raw = quota?.email.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    var compactLabel: String {
        let preferred = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = preferred?.isEmpty == false ? preferred! : display_name
        return base.count > 12 ? String(base.prefix(12)) : base
    }

    var accentColor: Color {
        Palette.blue
    }

    var statusLabel: String {
        if hot_active { return "Live" }
        switch status {
        case "ready": return "Ready"
        case "cooldown": return "Cooldown"
        case "disabled": return "Disabled"
        default: return status.capitalized
        }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct ClearWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        DispatchQueue.main.async { configureWindow(for: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
        DispatchQueue.main.async { configureWindow(for: nsView) }
    }

    private func configureWindow(for view: NSView) {
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

struct PointerCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

struct HoverLiftModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0))
            )
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { inside in
                isHovering = inside
            }
    }
}

extension View {
    func orbitPointer() -> some View {
        modifier(PointerCursorModifier())
    }

    func orbitHoverLift() -> some View {
        modifier(HoverLiftModifier())
    }
}

enum Palette {
    static let text = Color.white.opacity(0.97)
    static let secondaryText = Color.white.opacity(0.74)
    static let subtleText = Color.white.opacity(0.52)
    static let divider = Color.white.opacity(0.13)
    static let border = Color.white.opacity(0.14)
    static let switcher = Color.white.opacity(0.07)
    static let row = Color.white.opacity(0.05)
    static let blue = Color(red: 0.34, green: 0.60, blue: 0.97)
    static let teal = blue
    static let orange = blue
    static let red = blue
    static let green = blue
}

struct SoftDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: 1)
    }
}

struct UsageMeterBar: View {
    let percentLeft: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let percent = min(max(percentLeft, 0), 100)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.11))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * percent / 100)
            }
        }
        .frame(height: 8)
    }
}

struct BadgeView: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.18)))
            .overlay(Capsule().stroke(tint.opacity(0.30), lineWidth: 1))
    }
}

struct SwitcherChip: View {
    let account: DaemonSnapshot.Account
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(account.accentColor).frame(width: 7, height: 7)
                Text(account.compactLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if account.hot_active {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? account.accentColor.opacity(0.30) : Palette.switcher))
            .overlay(Capsule().stroke(selected ? account.accentColor.opacity(0.44) : Palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .orbitPointer()
        .orbitHoverLift()
    }
}

struct InlineActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.22)))
            .overlay(Capsule().stroke(tint.opacity(0.34), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .orbitPointer()
        .orbitHoverLift()
    }
}

struct MetricBlock: View {
    let title: String
    let percentLeft: Double
    let percentUsed: Double
    let tint: Color
    let topRight: String?
    let bottomLeft: String?
    let bottomRight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.text)
            UsageMeterBar(percentLeft: percentLeft, tint: tint)
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(percentUsed))% used")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text)
                Spacer()
                if let topRight, !topRight.isEmpty {
                    Text(topRight)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                if let bottomLeft, !bottomLeft.isEmpty {
                    Text(bottomLeft)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                if let bottomRight, !bottomRight.isEmpty {
                    Text(bottomRight)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct KeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.subtleText)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct AccountMenuRow: View {
    @State private var isHovered = false
    let account: DaemonSnapshot.Account
    let detail: String
    let isSelected: Bool
    let isSwitching: Bool
    let onSelect: () -> Void
    let onSwitch: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(account.accentColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.display_name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    if isSelected {
                        BadgeView(text: "Selected", tint: Palette.blue)
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let onSwitch {
                if isSwitching {
                    ProgressView().scaleEffect(0.7).tint(Palette.blue)
                } else {
                    InlineActionButton(title: "Activate", symbol: "arrow.left.arrow.right", tint: account.accentColor, action: onSwitch)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { inside in
            isHovered = inside
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected ? Color.white.opacity(isHovered ? 0.14 : 0.09) : (isHovered ? Color.white.opacity(0.09) : Palette.row))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isSelected || isHovered ? Palette.blue.opacity(0.34) : Palette.border, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.14), value: isHovered)
    }
}

struct MenuActionRow: View {
    let symbol: String
    let title: String
    let tint: Color
    let trailing: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text)
                Spacer()
                if let trailing, !trailing.isEmpty {
                    Text(trailing)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .orbitPointer()
        .orbitHoverLift()
    }
}

struct MenuPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            ClearWindowBackground()
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
        }
        .background(Color.clear)
    }
}

struct MenuContentView: View {
    @ObservedObject var store: StatusStore
    @State private var selectedAccountID: String?
    @State private var showAllAccounts = false

    private var accountListHeight: CGFloat {
        guard let snapshot = store.snapshot else { return 0 }
        return min(CGFloat(max(snapshot.accounts.count, 1)) * 40, 156)
    }

    private func featuredAccount(from snapshot: DaemonSnapshot) -> DaemonSnapshot.Account? {
        if let hotAccount = snapshot.hot?.account,
           let exactMatch = snapshot.accounts.first(where: { $0.id == hotAccount }) {
            return exactMatch
        }
        if let lastAccount = snapshot.last_account,
           let exactMatch = snapshot.accounts.first(where: { $0.id == lastAccount }) {
            return exactMatch
        }
        return snapshot.accounts.first(where: { $0.status == "ready" && $0.quota != nil }) ?? snapshot.accounts.first
    }

    private func selectedAccount(from snapshot: DaemonSnapshot) -> DaemonSnapshot.Account? {
        if let selectedAccountID,
           let selected = snapshot.accounts.first(where: { $0.id == selectedAccountID }) {
            return selected
        }
        return featuredAccount(from: snapshot)
    }

    private func updatedText(epoch: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        if abs(date.timeIntervalSinceNow) < 5 { return "Updated just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Updated " + formatter.localizedString(for: date, relativeTo: Date())
    }

    private func resetText(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("reset") || lower.contains("until") { return raw }
        if lower.hasPrefix("in ") { return "Resets \(raw)" }
        return "Resets in \(raw)"
    }

    private func windowText(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    private func humanized(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalized
    }

    private func cooldownText(snapshotEpoch: Int, cooldownUntil: Int) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(fromTimeInterval: TimeInterval(cooldownUntil - snapshotEpoch))
    }

    private func routingModeText(for snapshot: DaemonSnapshot) -> String {
        snapshot.auto_switch.enabled ? "Auto-switch every \(snapshot.auto_switch.interval_seconds)s" : "Manual routing"
    }

    private func routingDetail(for snapshot: DaemonSnapshot) -> String {
        if let event = snapshot.auto_switch.event {
            return "Last switch: \(event.from_account) → \(event.to_account)"
        }
        if let lastAction = snapshot.hot?.last_action, !lastAction.isEmpty {
            return humanized(lastAction)
        }
        return humanized(snapshot.routing_strategy)
    }

    private func heroMessage(for account: DaemonSnapshot.Account, snapshot: DaemonSnapshot) -> String {
        if account.hot_active { return "Live for the current hot session." }
        if let reason = account.disabled_reason, !reason.isEmpty { return humanized(reason) }
        if let cooldownUntil = account.cooldown_until {
            return "Available again \(cooldownText(snapshotEpoch: snapshot.generated_at_epoch, cooldownUntil: cooldownUntil))."
        }
        if !account.logged_in { return "Login required before routing can use this account." }
        if snapshot.auto_switch.enabled { return "Eligible for automatic promotion." }
        return "Ready to activate for the current session."
    }

    private func rowDetail(for account: DaemonSnapshot.Account, snapshot: DaemonSnapshot) -> String {
        if let reason = account.disabled_reason, !reason.isEmpty { return humanized(reason) }
        if let cooldownUntil = account.cooldown_until {
            return "Cooldown \(cooldownText(snapshotEpoch: snapshot.generated_at_epoch, cooldownUntil: cooldownUntil))"
        }
        if !account.logged_in { return "Login required" }
        return "\(Int(account.primaryRemainingPercent))% session left • \(Int(account.secondaryRemainingPercent))% weekly left"
    }

    private func headerRightText(for account: DaemonSnapshot.Account) -> String {
        account.accountEmail ?? account.planLabel
    }

    var body: some View {
        MenuPanel {
            VStack(alignment: .leading, spacing: 7) {
                if let snapshot = store.snapshot,
                   let selected = selectedAccount(from: snapshot) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Codex Menu Bar")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Palette.text)
                            Text(updatedText(epoch: snapshot.generated_at_epoch))
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondaryText)
                        }
                        Spacer(minLength: 10)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(headerRightText(for: selected))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Palette.text)
                                .lineLimit(1)
                            Text(selected.planLabel)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondaryText)
                                .lineLimit(1)
                        }
                    }

                    if snapshot.accounts.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(snapshot.accounts) { account in
                                    SwitcherChip(account: account, selected: account.id == selected.id) {
                                        selectedAccountID = account.id
                                    }
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }

                    SoftDivider()

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selected.display_name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Palette.text)
                                .lineLimit(1)
                            Text(heroMessage(for: selected, snapshot: snapshot))
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondaryText)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                BadgeView(text: selected.sourceLabel.uppercased(), tint: Palette.blue)
                                BadgeView(text: snapshot.auto_switch.enabled ? "Auto" : "Manual", tint: snapshot.auto_switch.enabled ? Palette.green : Palette.orange)
                                if snapshot.hot?.running == true {
                                    BadgeView(text: "Hot", tint: Palette.blue)
                                }
                            }
                        }
                        Spacer(minLength: 8)
                        if store.switchingAccountID == selected.id {
                            ProgressView().scaleEffect(0.72).tint(Palette.blue)
                        } else if selected.status == "ready" && !selected.hot_active {
                            InlineActionButton(title: "Make Active", symbol: "arrow.left.arrow.right.circle", tint: selected.accentColor) {
                                Task { await store.switchAccount(selected.id) }
                            }
                        } else {
                            BadgeView(text: selected.statusLabel, tint: selected.accentColor)
                        }
                    }

                    SoftDivider()

                    MetricBlock(
                        title: "Session",
                        percentLeft: selected.primaryRemainingPercent,
                        percentUsed: selected.primaryUsedPercent,
                        tint: Palette.blue,
                        topRight: resetText(selected.quota?.primary_reset),
                        bottomLeft: "\(Int(selected.primaryRemainingPercent))% left",
                        bottomRight: windowText(selected.quota?.primary_window)
                    )

                    MetricBlock(
                        title: "Weekly",
                        percentLeft: selected.secondaryRemainingPercent,
                        percentUsed: selected.secondaryUsedPercent,
                        tint: Palette.teal,
                        topRight: resetText(selected.quota?.secondary_reset),
                        bottomLeft: "\(Int(selected.secondaryRemainingPercent))% left",
                        bottomRight: windowText(selected.quota?.secondary_window)
                    )

                    SoftDivider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Routing")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.text)
                        KeyValueRow(label: routingModeText(for: snapshot), value: "\(snapshot.counts.ready)/\(snapshot.counts.accounts) ready")
                        KeyValueRow(label: "Cooldown", value: "\(snapshot.counts.cooldowns)")
                        KeyValueRow(label: "Disabled", value: "\(snapshot.counts.disabled)")
                        Text(routingDetail(for: snapshot))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(2)
                    }

                    if snapshot.accounts.count > 1 {
                        SoftDivider()

                        VStack(alignment: .leading, spacing: 6) {
                            Button(action: {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    showAllAccounts.toggle()
                                }
                            }) {
                                HStack {
                                    Text("All Accounts")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Palette.text)
                                    Spacer()
                                    Text("\(snapshot.counts.accounts)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Palette.secondaryText)
                                    Image(systemName: showAllAccounts ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Palette.secondaryText)
                                }
                                .padding(.vertical, 1)
                            }
                            .buttonStyle(.plain)
                            .orbitPointer()

                            if showAllAccounts {
                                ScrollView(.vertical, showsIndicators: false) {
                                    LazyVStack(spacing: 6) {
                                        ForEach(snapshot.accounts) { account in
                                            AccountMenuRow(
                                                account: account,
                                                detail: rowDetail(for: account, snapshot: snapshot),
                                                isSelected: account.id == selected.id,
                                                isSwitching: store.switchingAccountID == account.id,
                                                onSelect: { selectedAccountID = account.id },
                                                onSwitch: account.status == "ready" && !account.hot_active ? {
                                                    selectedAccountID = account.id
                                                    Task { await store.switchAccount(account.id) }
                                                } : nil
                                            )
                                        }
                                    }
                                }
                                .frame(height: accountListHeight)
                            }
                        }
                        .animation(.easeOut(duration: 0.16), value: showAllAccounts)
                    }

                    SoftDivider()

                    VStack(alignment: .leading, spacing: 2) {
                        MenuActionRow(symbol: "arrow.clockwise", title: "Refresh Now", tint: Palette.blue, trailing: nil) {
                            Task { await store.refresh() }
                        }
                        MenuActionRow(
                            symbol: snapshot.auto_switch.enabled ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath",
                            title: store.autoSwitchUpdating ? "Updating…" : (snapshot.auto_switch.enabled ? "Disable Auto-switch" : "Enable Auto-switch"),
                            tint: snapshot.auto_switch.enabled ? Palette.green : Palette.orange,
                            trailing: snapshot.auto_switch.enabled ? "\(snapshot.auto_switch.interval_seconds)s" : nil
                        ) {
                            Task { await store.setAutoSwitch(enabled: !snapshot.auto_switch.enabled) }
                        }
                        MenuActionRow(symbol: "power", title: "Quit", tint: Palette.red, trailing: nil) {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                } else if let lastError = store.lastError {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Codex Menu Bar")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Palette.text)
                        Text(store.daemonLaunching ? "Starting daemon…" : "Daemon not reachable")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.text)
                        Text("The local control plane is unavailable, so switching and quota state are paused.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(lastError)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.subtleText)
                            .fixedSize(horizontal: false, vertical: true)
                        if store.canStartDaemon {
                            InlineActionButton(title: store.daemonLaunching ? "Starting Daemon…" : "Start Daemon", symbol: store.daemonLaunching ? "bolt.circle" : "play.circle", tint: Palette.green) {
                                Task { await store.startDaemon() }
                            }
                        }
                        SoftDivider()
                        MenuActionRow(symbol: "arrow.clockwise", title: "Retry", tint: Palette.blue, trailing: nil) {
                            Task { await store.refresh() }
                        }
                        MenuActionRow(symbol: "power", title: "Quit", tint: Palette.red, trailing: nil) {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Codex Menu Bar")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Palette.text)
                        Text("Connecting to the daemon and loading account health…")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                        ProgressView().tint(Palette.blue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 348)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

@main
struct CodexMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = StatusStore()

    var body: some Scene {
        MenuBarExtra("CX \(store.badgeText)", systemImage: "bolt.horizontal.circle") {
            MenuContentView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
