import AppKit
import SwiftUI

struct DaemonSnapshot: Decodable {
    struct Counts: Decodable {
        let accounts: Int
        let logged_in: Int
        let ready: Int
        let disabled: Int
        let cooldowns: Int
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
    }

    let generated_at_epoch: Int
    let routing_strategy: String
    let last_account: String?
    let counts: Counts
    let accounts: [Account]
}

@MainActor
final class StatusStore: ObservableObject {
    @Published var snapshot: DaemonSnapshot?
    @Published var lastError: String?

    private let daemonURL: URL
    private var timer: Timer?

    init() {
        let rawURL = ProcessInfo.processInfo.environment["CODEX_ORBIT_DAEMON_URL"]
            ?? "http://127.0.0.1:8787"
        self.daemonURL = URL(string: rawURL) ?? URL(string: "http://127.0.0.1:8787")!

        Task { await refresh() }
        self.timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    var badgeText: String {
        guard let snapshot else { return "?" }
        return "\(snapshot.counts.ready)"
    }

    func refresh() async {
        do {
            let statusURL = daemonURL.appending(path: "/v1/status")
            let (data, response) = try await URLSession.shared.data(from: statusURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                lastError = "Daemon unavailable"
                return
            }
            let decoded = try JSONDecoder().decode(DaemonSnapshot.self, from: data)
            snapshot = decoded
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuContentView: View {
    @ObservedObject var store: StatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = store.snapshot {
                Text("Codex Orbit")
                    .font(.headline)
                Text("Routing: \(snapshot.routing_strategy)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Accounts")
                        Text("\(snapshot.counts.accounts)")
                    }
                    GridRow {
                        Text("Logged In")
                        Text("\(snapshot.counts.logged_in)")
                    }
                    GridRow {
                        Text("Ready")
                        Text("\(snapshot.counts.ready)")
                    }
                    GridRow {
                        Text("Disabled")
                        Text("\(snapshot.counts.disabled)")
                    }
                    GridRow {
                        Text("Cooldowns")
                        Text("\(snapshot.counts.cooldowns)")
                    }
                }

                Divider()

                Text("Accounts")
                    .font(.subheadline.weight(.semibold))

                ForEach(snapshot.accounts.prefix(8)) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.display_name)
                            Text(account.status.replacingOccurrences(of: "_", with: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } else if let lastError = store.lastError {
                Text("Codex Orbit")
                    .font(.headline)
                Text("Daemon not reachable")
                    .font(.subheadline)
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Loading...")
            }
        }
        .frame(width: 280)
        .padding(14)
    }
}

@main
struct CodexOrbitMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = StatusStore()

    var body: some Scene {
        MenuBarExtra("CX \(store.badgeText)", systemImage: "arrow.triangle.2.circlepath") {
            MenuContentView(store: store)
            Divider()
            Button("Refresh") {
                Task { await store.refresh() }
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
