import SwiftUI

/// The Composio app catalog: browse, search, add apps, and authorize them. Search and category come from Connect Apps.
struct MacComposioSetupView: View {
    @ObservedObject var service: ComposioModel
    var query = ""
    var category: String?
    /// Called when "View all" is pressed on a category section.
    var viewAll: ((String) -> Void)?
    @State private var projectKey = ""
    @AppStorage("claudeAllowConnectedApps") private var claudeAllowConnectedApps = true

    private var filtering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || category != nil }

    /// Counts only apps added to this project, and says so, so an un-added app showing "Add" doesn't look like a miscount.
    private var connectionSummary: String {
        let waiting = max(0, service.applied.count - service.connectedCount)
        let connected = service.connectedCount == 1 ? "1 app connected" : "\(service.connectedCount) apps connected"
        return waiting == 0 ? connected : connected + " · \(waiting) waiting for you to connect"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if service.configured { configuredBar } else { setupCard }
            if filtering {
                let results = ComposioCatalog.filter(query: query, category: category)
                if results.isEmpty { Text("No apps match your search.").font(.system(size: 14)).foregroundStyle(MacTheme.secondary) }
                else { section("Results", results) }
            } else {
                section("Recommended for you", ComposioCatalog.recommended.compactMap(ComposioCatalog.app))
                // 10.0: an app already under "Recommended for you" isn't repeated in its category.
                let recommended = Set(ComposioCatalog.recommended)
                ForEach(ComposioCatalog.categories.filter { name in ComposioCatalog.filter(query: "", category: name).contains { !recommended.contains($0.slug) } }, id: \.self) { name in
                    section(name, ComposioCatalog.filter(query: "", category: name).filter { !recommended.contains($0.slug) }, limit: 4, viewAllCategory: name)
                }
            }
            if let feedback = service.feedback { Text(feedback).font(.system(size: 14)).lineSpacing(4).foregroundStyle(MacTheme.secondary) }
            if service.configured { footer }
        }
        .onAppear { if service.configured { service.refresh() } }
        .onDisappear { projectKey = "" }
    }

    // MARK: Setup and status
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your Composio project").font(.system(size: 18, weight: .medium))
            Text("Use your own Composio project to connect apps to your Bots. This step is optional; you can chat without connectors. Add the apps you want below, then connect.")
                .font(.system(size: 14)).lineSpacing(4).foregroundStyle(MacTheme.secondary)
            SecureField("Composio project API key", text: $projectKey).textFieldStyle(.roundedBorder).accessibilityIdentifier("composio-project-key")
            HStack(spacing: 14) {
                MacPillButton(title: service.busy ? "Connecting…" : "Connect project", prominent: true) { service.connect(projectKey: projectKey); projectKey = "" }
                    .disabled(service.busy || projectKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.selected.isEmpty)
                Text(service.selected.isEmpty ? "Add at least one app" : "\(service.selected.count) app\(service.selected.count == 1 ? "" : "s") chosen").font(.system(size: 13)).foregroundStyle(MacTheme.secondary)
                Link("Get a key ↗", destination: URL(string: "https://platform.composio.dev")!).font(.system(size: 13))
            }
            Text("The key and tool session stay in this Mac’s Keychain. Composio and AI providers apply their own plans and usage limits.")
                .font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(MacTheme.raised, in: RoundedRectangle(cornerRadius: 16))
    }

    private var configuredBar: some View {
        HStack(spacing: 10) {
            Text(service.toolkits.isEmpty && !service.busy ? "Refresh to load your apps" : connectionSummary).font(.system(size: 14)).foregroundStyle(MacTheme.secondary)
            Spacer()
            if service.hasPendingChanges {
                let changes = service.selected.symmetricDifference(service.applied).count
                MacPillButton(title: "Apply \(changes) change\(changes == 1 ? "" : "s")", prominent: true) { service.applySelection() }.disabled(service.busy)
            }
            MacPillButton(title: service.busy ? "Working…" : "Refresh connections") { service.refresh() }.disabled(service.busy)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Let Claude Code use connected apps without asking", isOn: $claudeAllowConnectedApps).toggleStyle(.switch)
            Text("Claude Code works in the background and cannot ask you before using an app, so it refuses unless this is on. It lets only your connected apps (Composio) run without a question, for example reading Google Drive or sending an email from Gmail. Leave it off if you read pages or files you do not trust. Other AI CLIs follow their own settings.")
                .font(.system(size: 12)).lineSpacing(3).foregroundStyle(MacTheme.secondary)
            Text("Connected apps are available to your selected CLI through MCP, and actions follow that CLI’s permission settings. Add more apps above and choose Apply; accounts you already authorized stay connected.")
                .font(.system(size: 12)).lineSpacing(4).foregroundStyle(MacTheme.secondary)
            Button("Remove project from this Mac") { service.disconnect() }.disabled(service.busy)
            Link("Manage or revoke accounts in Composio ↗", destination: URL(string: "https://platform.composio.dev")!)
        }
    }

    // MARK: Catalog
    @ViewBuilder private func section(_ title: String, _ apps: [CatalogApp], limit: Int? = nil, viewAllCategory: String? = nil) -> some View {
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.system(size: 14)).foregroundStyle(MacTheme.secondary)
                    Spacer()
                    if let limit, let viewAllCategory, apps.count > limit, let viewAll {
                        Button("View all") { viewAll(viewAllCategory) }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(MacTheme.secondary)
                            .accessibilityLabel("View all \(title) apps")
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(limit.map { Array(apps.prefix($0)) } ?? apps) { app in card(app) }
                }
            }
        }
    }

    private func card(_ app: CatalogApp) -> some View {
        HStack(spacing: 12) {
            ConnectorIcon(slug: app.slug, symbol: app.symbol, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(app.category).font(.system(size: 11)).foregroundStyle(MacTheme.secondary)
            }
            Spacer(minLength: 6)
            trailing(app)
        }.padding(12).background(MacTheme.raised, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func trailing(_ app: CatalogApp) -> some View {
        if service.configured && service.applied.contains(app.slug) {
            if let toolkit = service.toolkits.first(where: { $0.slug == app.slug && $0.enabled }) {
                if toolkit.connected || toolkit.is_no_auth { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("\(app.name) connected") }
                else { MacPillButton(title: "Connect") { service.authorize(toolkit) }.disabled(service.busy) }
            } else { Text(service.busy ? "Loading…" : "—").font(.system(size: 12)).foregroundStyle(MacTheme.secondary) }
        } else {
            let chosen = service.selected.contains(app.slug)
            MacPillButton(title: chosen ? "Added ✓" : "Add") {
                if chosen { service.selected.remove(app.slug) } else { service.selected.insert(app.slug) }
            }.disabled(service.busy).accessibilityLabel(chosen ? "Remove \(app.name)" : "Add \(app.name)")
        }
    }
}
