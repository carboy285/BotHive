import SwiftUI

struct MacConnectAppsView: View {
    @EnvironmentObject private var desktop: MacAppModel
    @State private var query = ""
    @State private var category: String?
    private static let onThisMac = "This Mac"

    private struct MacEntry: Identifiable {
        let id: String, title: String, subtitle: String, symbol: String, keywords: String, tint: Color
    }
    private static let macEntries: [MacEntry] = [
        MacEntry(id: "messages", title: "Messages", subtitle: "Read and reply to texts", symbol: "message.fill", keywords: "apple mac messages imessage texts sms", tint: .green),
        MacEntry(id: "notes", title: "Notes", subtitle: "Find and save notes", symbol: "note.text", keywords: "apple mac notes", tint: .yellow),
        MacEntry(id: "reminders", title: "Reminders", subtitle: "Set and check reminders", symbol: "checklist", keywords: "apple mac reminders todo tasks", tint: .orange),
        MacEntry(id: "calendar", title: "Calendar", subtitle: "See your day and add events", symbol: "calendar", keywords: "apple mac calendar events schedule", tint: .red),
        MacEntry(id: "contacts", title: "Contacts", subtitle: "Look up the people you ask about", symbol: "person.crop.circle.fill", keywords: "apple mac contacts people address book", tint: .gray),
        MacEntry(id: "mail", title: "Mail", subtitle: "Read and draft email", symbol: "envelope.fill", keywords: "apple mac mail email", tint: .blue),
        MacEntry(id: "logins", title: "Secure Logins", subtitle: "Sign in to a site without a Bot ever seeing your password", symbol: "key.fill", keywords: "secure logins password manager sign in credentials", tint: .indigo)
    ]

    private func open(_ entry: MacEntry) {
        switch entry.id {
        case "logins": desktop.settingsTab = .secureLogins; desktop.panel = .settings
        default: desktop.panel = .apple
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Connect Apps").font(.system(size: 25, weight: .medium))
                Spacer()
                ConnectedBadge(service: desktop.composio)
                Button { desktop.panel = nil } label: { Image(systemName: "xmark").frame(width: 38, height: 38) }.buttonStyle(.plain).accessibilityLabel("Close Connect Apps")
            }
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(MacTheme.secondary)
                    TextField("Search across apps and skills", text: $query).textFieldStyle(.plain).font(.system(size: 15)).accessibilityLabel("Search apps and skills")
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(MacTheme.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
                }.padding(.horizontal, 14).padding(.vertical, 11).background(MacTheme.raised, in: Capsule())
                Button { desktop.panel = .newBot } label: {
                    HStack(spacing: 8) {
                        MacBotAvatar(size: 20)
                        Text("Bot templates").font(.system(size: 14, weight: .medium))
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(MacTheme.secondary)
                    }.padding(.horizontal, 14).padding(.vertical, 10).background(MacTheme.raised, in: Capsule())
                }.buttonStyle(.plain).help("Start a Bot from a ready-made character, or paste a Bot code from a friend").accessibilityLabel("Bot templates")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All", selected: category == nil) { category = nil }
                    chip(Self.onThisMac, selected: category == Self.onThisMac) { category = Self.onThisMac }
                    ForEach(ComposioCatalog.categories, id: \.self) { name in chip(name, selected: category == name) { category = name } }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if showsMacSection { macSection }
                    if category == nil, !matchingSkills.isEmpty { skillsSection }
                    if category != Self.onThisMac { MacComposioSetupView(service: desktop.composio, query: query, category: category, viewAll: { category = $0 }) }
                }.frame(maxWidth: 780, alignment: .leading).padding(.vertical, 8).frame(maxWidth: .infinity)
            }
        }.padding(36)
    }

    private var visibleMacEntries: [MacEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return Self.macEntries.filter { entry in words.allSatisfy { (entry.title + " " + entry.keywords).lowercased().contains($0) } }
    }
    private var showsMacSection: Bool { (category == nil || category == Self.onThisMac) && !visibleMacEntries.isEmpty }

    private var macSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Self.onThisMac).font(.system(size: 16, weight: .medium))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                ForEach(visibleMacEntries) { entry in
                    HStack(spacing: 14) {
                        Image(systemName: entry.symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 46, height: 46).background(entry.tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                            Text(entry.subtitle).font(.system(size: 12)).foregroundStyle(MacTheme.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        MacPillButton(title: "Open") { open(entry) }
                    }
                }
            }
        }
    }

    private var matchingSkills: [BotSkill] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return desktop.skills.skills.filter { skill in words.allSatisfy { (skill.name + " " + skill.description).lowercased().contains($0) } }
    }

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Skills").font(.system(size: 16, weight: .medium))
            ForEach(matchingSkills) { skill in
                HStack(spacing: 14) {
                    Image(systemName: "text.book.closed.fill").font(.system(size: 18)).foregroundStyle(.white)
                        .frame(width: 46, height: 46).background(Color.indigo, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                        Text(skill.description.isEmpty ? skill.source : skill.description).font(.system(size: 12)).foregroundStyle(MacTheme.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    MacPillButton(title: "Manage") { desktop.openSettings(.skills) }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? MacTheme.onProminent : Color.primary.opacity(0.88))
                .background(selected ? MacTheme.prominent : MacTheme.raised, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct ConnectedBadge: View {
    @ObservedObject var service: ComposioModel
    var body: some View {
        if service.connectedCount > 0 {
            HStack(spacing: 8) {
                HStack(spacing: -8) {
                    ForEach(Array(service.toolkits.filter { $0.connected || $0.is_no_auth }.prefix(4)), id: \.slug) { toolkit in
                        ConnectorIcon(slug: toolkit.slug, symbol: ComposioCatalog.app(toolkit.slug)?.symbol ?? "app", size: 26)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(MacTheme.canvas, lineWidth: 2))
                    }
                }.accessibilityHidden(true)
                Text("\(service.connectedCount) connected").font(.system(size: 13)).foregroundStyle(MacTheme.secondary)
            }
        }
    }
}
