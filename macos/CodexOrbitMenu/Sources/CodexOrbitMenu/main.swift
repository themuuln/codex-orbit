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

    private let daemonURL: URL
    private var timer: Timer?
    private var lastAutoSwitchEventID: String?
    private let notificationsEnabled: Bool

    init() {
        let rawURL = ProcessInfo.processInfo.environment["CODEX_ORBIT_DAEMON_URL"]
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

    func refresh() async {
        await loadSnapshot()
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
        await loadSnapshot()
    }

    private func loadSnapshot() async {
        do {
            let statusURL = daemonURL.appending(path: "/v1/status")
            let (data, response) = try await URLSession.shared.data(from: statusURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                lastError = "Daemon unavailable"
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
        content.title = "Codex Orbit"
        content.body = "Auto-switched from \(event.from_account) to \(event.to_account)."
        let request = UNNotificationRequest(
            identifier: "codex-orbit.auto-switch.\(event.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated static func percentValue(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw) else { return nil }
        return min(max(value, 0), 100)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

extension DaemonSnapshot.Account {
    var primaryRemainingPercent: Double {
        StatusStore.percentValue(quota?.primary_remaining) ?? 0
    }

    var secondaryRemainingPercent: Double {
        StatusStore.percentValue(quota?.secondary_remaining) ?? 0
    }

    var primaryUsedPercent: Double {
        if let used = StatusStore.percentValue(quota?.primary_used) {
            return used
        }
        return max(0, 100 - primaryRemainingPercent)
    }

    var secondaryUsedPercent: Double {
        if let used = StatusStore.percentValue(quota?.secondary_used) {
            return used
        }
        return max(0, 100 - secondaryRemainingPercent)
    }

    var planLabel: String {
        let rawPlan = quota?.plan.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rawPlan.isEmpty ? "Orbit" : rawPlan
    }

    var sourceLabel: String {
        let rawSource = quota?.source.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rawSource.isEmpty ? "orbit" : rawSource
    }

    var shortLabel: String {
        let preferred = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (preferred?.isEmpty == false ? preferred! : display_name)
        let firstToken = base.split(separator: " ").first.map(String.init) ?? base
        return firstToken.count > 10 ? String(firstToken.prefix(10)) : firstToken
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

struct SoftDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.08))
            .frame(height: 1)
    }
}

struct ThinUsageBar: View {
    let value: Double
    let tint: Color
    let height: CGFloat

    init(value: Double, tint: Color, height: CGFloat = 6) {
        self.value = value
        self.tint = tint
        self.height = height
    }

    var body: some View {
        GeometryReader { geometry in
            let clampedValue = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.7), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(height, geometry.size.width * clampedValue))
            }
        }
        .frame(height: height)
    }
}

struct StatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(tint.opacity(0.14))
            )
            .foregroundStyle(tint)
    }
}

struct HeaderActionButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(tint.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
    }
}

struct AccountTabButton: View {
    let account: DaemonSnapshot.Account
    let selected: Bool
    let action: () -> Void

    private var tint: Color {
        if account.hot_active { return .blue }
        if account.status == "ready" { return .teal }
        if account.status == "cooldown" { return .orange }
        if account.status == "disabled" { return .red }
        return .gray
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Text(account.shortLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(selected ? .white : .primary)
                ThinUsageBar(
                    value: account.primaryUsedPercent / 100,
                    tint: selected ? .white.opacity(0.92) : tint,
                    height: 4
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minWidth: 72, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        selected
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor.opacity(0.95),
                                        Color.accentColor.opacity(0.8)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(Color.white.opacity(0.28))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(selected ? 0.18 : 0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct UsageSectionView: View {
    let title: String
    let value: Double
    let tint: Color
    let leftCaption: String
    let rightCaption: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            ThinUsageBar(value: value / 100, tint: tint)
            HStack(alignment: .firstTextBaseline) {
                Text(leftCaption)
                    .monospacedDigit()
                Spacer()
                Text(rightCaption)
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SnapshotMetricChip: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AccountListRow: View {
    let account: DaemonSnapshot.Account
    let snapshotEpoch: Int
    let isSwitching: Bool
    let onSwitch: () -> Void

    private var statusColor: Color {
        switch account.status {
        case "ready":
            return account.hot_active ? .blue : .teal
        case "cooldown":
            return .orange
        case "disabled":
            return .red
        default:
            return .gray
        }
    }

    private var detailText: String {
        if let reason = account.disabled_reason, !reason.isEmpty {
            return reason.replacingOccurrences(of: ":", with: " ")
        }
        if let cooldownUntil = account.cooldown_until {
            return "Cooldown until \(Self.timeString(epoch: cooldownUntil)) (\(Self.relativeString(from: snapshotEpoch, to: cooldownUntil)))"
        }
        if !account.logged_in {
            return "Login required"
        }
        return "\(Int(account.primaryUsedPercent))% session • \(Int(account.secondaryUsedPercent))% weekly"
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.display_name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if account.hot_active {
                        StatusBadge(text: "LIVE", tint: .blue)
                    }
                }
                Text(detailText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if account.status == "ready" && !account.hot_active {
                if isSwitching {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    HeaderActionButton(title: "Switch", tint: .accentColor, action: onSwitch)
                }
            }
        }
    }

    private static func timeString(epoch: Int) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    private static func relativeString(from startEpoch: Int, to endEpoch: Int) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(fromTimeInterval: TimeInterval(endEpoch - startEpoch))
    }
}

struct MenuCommandRow: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .popover, blendingMode: .withinWindow)
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.96, blue: 1.0).opacity(0.92),
                    Color(red: 0.95, green: 0.92, blue: 0.99).opacity(0.86),
                    Color(red: 0.93, green: 0.92, blue: 1.0).opacity(0.82)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.78, blue: 0.86).opacity(0.18),
                    .clear
                ],
                center: .center,
                startRadius: 10,
                endRadius: 280
            )
            content
                .padding(16)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.14), radius: 22, x: 0, y: 10)
    }
}

struct MenuContentView: View {
    @ObservedObject var store: StatusStore
    @State private var selectedAccountID: String?

    private var accountListHeight: CGFloat {
        guard let snapshot = store.snapshot else { return 0 }
        return min(CGFloat(max(snapshot.accounts.count, 1)) * 58, 230)
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
        return snapshot.accounts.first(where: { $0.status == "ready" && $0.quota != nil })
            ?? snapshot.accounts.first
    }

    private func updatedText(epoch: Int) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(epoch)),
            relativeTo: Date()
        )
    }

    private func selectedAccount(from snapshot: DaemonSnapshot) -> DaemonSnapshot.Account? {
        if let selectedAccountID,
           let selected = snapshot.accounts.first(where: { $0.id == selectedAccountID }) {
            return selected
        }
        return featuredAccount(from: snapshot)
    }

    private func resetText(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "No reset"
        }
        let lower = raw.lowercased()
        if lower.contains("reset") || lower.contains("until") {
            return raw
        }
        if lower.hasPrefix("in ") {
            return "Resets \(raw)"
        }
        return "Resets in \(raw)"
    }

    private func windowText(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return "\(raw) window"
    }

    private func availabilityDetail(for snapshot: DaemonSnapshot) -> String {
        if let lastAction = snapshot.hot?.last_action, !lastAction.isEmpty {
            return lastAction.replacingOccurrences(of: "_", with: " ")
        }
        if let event = snapshot.auto_switch.event {
            return "Last switch: \(event.from_account) → \(event.to_account)"
        }
        return "Routing: \(snapshot.routing_strategy.replacingOccurrences(of: "_", with: " "))"
    }

    private func actionTitle(for snapshot: DaemonSnapshot) -> String {
        snapshot.auto_switch.enabled ? "Disable Auto-switch" : "Enable Auto-switch"
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 16) {
                if let snapshot = store.snapshot,
                   let selected = selectedAccount(from: snapshot) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(snapshot.accounts) { account in
                                AccountTabButton(
                                    account: account,
                                    selected: account.id == selected.id,
                                    action: { selectedAccountID = account.id }
                                )
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selected.display_name)
                                    .font(.system(size: 17, weight: .semibold))
                                    .lineLimit(1)
                                Text("Updated \(updatedText(epoch: snapshot.generated_at_epoch))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 10)
                            Text(selected.planLabel)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            StatusBadge(
                                text: selected.hot_active ? "Live" : selected.status.capitalized,
                                tint: selected.hot_active ? .blue : (selected.status == "ready" ? .teal : .orange)
                            )
                            StatusBadge(
                                text: selected.sourceLabel.uppercased(),
                                tint: .purple
                            )
                            if store.autoSwitchUpdating {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else if selected.status == "ready" && !selected.hot_active {
                                HeaderActionButton(title: "Make Active", tint: .accentColor) {
                                    Task { await store.switchAccount(selected.id) }
                                }
                            }
                        }
                    }

                    SoftDivider()

                    UsageSectionView(
                        title: "Session",
                        value: selected.primaryUsedPercent,
                        tint: .orange,
                        leftCaption: "\(Int(selected.primaryUsedPercent))% used",
                        rightCaption: resetText(selected.quota?.primary_reset),
                        detail: windowText(selected.quota?.primary_window)
                    )

                    SoftDivider()

                    UsageSectionView(
                        title: "Weekly",
                        value: selected.secondaryUsedPercent,
                        tint: .teal,
                        leftCaption: "\(Int(selected.secondaryUsedPercent))% used",
                        rightCaption: resetText(selected.quota?.secondary_reset),
                        detail: windowText(selected.quota?.secondary_window)
                    )

                    SoftDivider()

                    UsageSectionView(
                        title: "Availability",
                        value: (Double(snapshot.counts.ready) / Double(max(snapshot.counts.accounts, 1))) * 100,
                        tint: .blue,
                        leftCaption: "\(snapshot.counts.ready) ready of \(snapshot.counts.accounts)",
                        rightCaption: snapshot.auto_switch.enabled ? "Auto-switch on" : "Manual routing",
                        detail: availabilityDetail(for: snapshot)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            SnapshotMetricChip(label: "Live", value: snapshot.hot?.running == true ? "1" : "0")
                            SnapshotMetricChip(label: "Cooldown", value: "\(snapshot.counts.cooldowns)")
                            SnapshotMetricChip(label: "Disabled", value: "\(snapshot.counts.disabled)")
                        }
                    }

                    if !snapshot.accounts.isEmpty {
                        SoftDivider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Accounts")
                                .font(.system(size: 16, weight: .semibold))
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(snapshot.accounts) { account in
                                        AccountListRow(
                                            account: account,
                                            snapshotEpoch: snapshot.generated_at_epoch,
                                            isSwitching: store.switchingAccountID == account.id,
                                            onSwitch: {
                                                selectedAccountID = account.id
                                                Task { await store.switchAccount(account.id) }
                                            }
                                        )
                                        if account.id != snapshot.accounts.last?.id {
                                            SoftDivider()
                                        }
                                    }
                                }
                            }
                            .frame(height: accountListHeight)
                        }
                    }

                    SoftDivider()

                    VStack(alignment: .leading, spacing: 8) {
                        MenuCommandRow(symbol: "arrow.clockwise", title: "Refresh") {
                            Task { await store.refresh() }
                        }
                        MenuCommandRow(
                            symbol: "arrow.triangle.2.circlepath",
                            title: actionTitle(for: snapshot)
                        ) {
                            Task { await store.setAutoSwitch(enabled: !snapshot.auto_switch.enabled) }
                        }
                        MenuCommandRow(symbol: "power", title: "Quit") {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                } else if let lastError = store.lastError {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Codex Orbit")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Daemon not reachable")
                            .font(.system(size: 15, weight: .medium))
                        Text(lastError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        SoftDivider()
                        MenuCommandRow(symbol: "arrow.clockwise", title: "Retry") {
                            Task { await store.refresh() }
                        }
                        MenuCommandRow(symbol: "power", title: "Quit") {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Codex Orbit")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Loading…")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
        }
        .frame(width: 420)
        .padding(10)
    }
}

@main
struct CodexOrbitMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = StatusStore()

    var body: some Scene {
        MenuBarExtra("CX \(store.badgeText)", systemImage: "bolt.horizontal.circle") {
            MenuContentView(store: store)
        }
    }
}
