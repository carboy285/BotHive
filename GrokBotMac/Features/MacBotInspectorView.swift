import AppKit
import SwiftUI

private enum BotInspectorTab: String, CaseIterable, Identifiable {
    case activity = "Activity", details = "Details", library = "Library"
    var id: String { rawValue }
}

/// A persistent companion to the conversation, rather than a modal over it.
struct MacBotInspectorView: View {
    let bot: Bot
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var desktop: MacAppModel
    @State private var tab = BotInspectorTab.activity
    @AppStorage("inspectorSuggestionsHidden") private var suggestionsHidden = false
    @State private var files: [URL] = []
    @State private var fileError: String?
    @State private var editingAvatar = false
    @AppStorage("providersOpen") private var showProviders = true
    @State private var folderDraft = ""
    @State private var editingDetails = false
    @State private var nameDraft = ""
    @State private var purposeDraft = ""
    @State private var memoryDraft = ""
    @State private var sharedDraft = ""
    @State private var creatingRoutine = false
    @State private var routineName = ""
    @State private var routineInstruction = ""
    @State private var routineDate = Date().addingTimeInterval(3600)
    @State private var routineRepeat = "none"
    @State private var routineTrigger = "time"
    @State private var routineContains = ""
    @State private var routineZone = TimeZone.current.identifier
    @State private var editingRoutine: BotSchedule?
    @State private var routineToDelete: BotSchedule?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                ShareLink(item: desktop.conversationText(for: bot, app: app)) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 19))
                        .frame(width: 42, height: 42).glassChrome(in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Share conversation").help("Share conversation")
                MacCircleButton(symbol: "xmark", label: "Close bot details") { desktop.showBotInspector = false }.keyboardShortcut(.cancelAction)
            }.padding(18)
            if editingAvatar {
                BotAvatarPicker(bot: bot, save: { appearance in app.setAppearance(appearance, for: bot) }, close: { editingAvatar = false })
                    .id(bot.id)
                Spacer(minLength: 0)
            } else { VStack(spacing: 0) {
                    Button { editingAvatar = true } label: {
                        MacBotAvatar(color: bot.color, size: 64, appearance: bot.appearance)
                    }.buttonStyle(.plain).help("Change Bot avatar").accessibilityLabel("Change Bot avatar")
                    Text(bot.name).font(.system(size: 17, weight: .semibold))
                        .multilineTextAlignment(.center).textSelection(.enabled)
                        .padding(.horizontal, 24).padding(.top, 12)
                    if bot.isMain != true, !bot.purpose.isEmpty {
                        Text(bot.purpose).font(.system(size: 13)).foregroundStyle(MacTheme.secondary)
                            .multilineTextAlignment(.center).lineLimit(3).textSelection(.enabled)
                            .padding(.horizontal, 28).padding(.top, 4)
                    }
                    HStack(spacing: 4) {
                        ForEach(BotInspectorTab.allCases) { item in
                            Button { tab = item; if item == .library { refreshFiles() } } label: {
                                Text(item.rawValue).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(tab == item ? Color.primary : MacTheme.secondary)
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .background(tab == item ? MacTheme.raised : .clear, in: Capsule())
                                    .contentShape(Capsule())
                            }.buttonStyle(.plain)
                                .accessibilityIdentifier("bot-inspector-tab-\(item.rawValue.lowercased())")
                                .accessibilityAddTraits(tab == item ? [.isSelected] : [])
                        }
                    }
                    .padding(.top, 16).padding(.bottom, 16)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            switch tab {
                            case .activity: activity
                            case .details: details
                            case .library: library
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 30)
                    }.scrollIndicators(.hidden)
            } }
        }
        .frame(maxHeight: .infinity).background(MacTheme.canvas)
        .confirmationDialog("Delete this routine?", isPresented: Binding(get: { routineToDelete != nil }, set: { if !$0 { routineToDelete = nil } }), presenting: routineToDelete) { task in
            Button("Delete \(task.name)", role: .destructive) { _ = app.removeSchedule(task.id, botID: bot.id); routineToDelete = nil }
        } message: { _ in Text("Future runs will be removed from this Bot.") }
        .onChange(of: desktop.runningBots) { _, running in if !running.contains(bot.id), tab == .library { refreshFiles() } }
        .onAppear { folderDraft = bot.folder ?? ""; if desktop.needsProvider(bot) { showProviders = true } }
        .onChange(of: bot.id) { _, _ in editingAvatar = false; editingDetails = false; creatingRoutine = false; editingRoutine = nil; folderDraft = bot.folder ?? "" }
    }

    private var tint: Color { bot.appearance == nil && bot.color == "white" ? .primary : AvatarArtwork.color(bot.appearance?.color ?? bot.color) }
    private var ink: Color {
        let name = bot.appearance?.color ?? bot.color
        if bot.appearance == nil && bot.color == "white" { return MacTheme.canvas }
        return ["white", "amber", "orange", "green", "teal", "gray"].contains(name) ? .black : .white
    }
    private var isPinned: Bool { bot.isPinned ?? (bot.isMain == true) }
    private var busy: Bool { desktop.runningBots.contains(bot.id) }

    private var details: some View {
        VStack(alignment: .leading, spacing: 22) {
            InspectorCard(title: "Organize", footer: "Drag Bots in the sidebar to change their order.") {
                Toggle("Pinned to top", isOn: Binding(get: { isPinned }, set: { desktop.remote.setPinned(bot, pinned: $0) }))
                HStack(spacing: 8) {
                    TextField("Folder, blank for Unfiled", text: $folderDraft).textFieldStyle(.roundedBorder)
                    Button("Save") { _ = app.organize(bot, folder: folderDraft) }
                        .buttonStyle(InspectorButtonStyle()).disabled(folderDraft.count > 80 || folderDraft == (bot.folder ?? ""))
                }
                if bot.memberIDs == nil {
                    Button("Share this Bot…", systemImage: "square.and.arrow.up") { if let note = BotSharing.export(bot) { desktop.sendFeedback[bot.id] = note } }
                        .buttonStyle(InspectorButtonStyle()).help("Saves the name and job only, never memory, chats, logins or files.")
                }
            }
            memoryCard
            InspectorCard(title: "Browser", footer: "Its own browser profile. When the Bot browses, nothing opens on your screen; use this button, or Show browser in the chat, to watch.") {
                Button("Open local browser", systemImage: "globe") {
                    do { _ = try LocalBotBrowsers.shared.open(bot, reveal: true) } catch { app.errorMessage = error.localizedDescription }
                }.buttonStyle(InspectorButtonStyle())
            }
            InspectorCard(title: "Linux VM", footer: "One VM is shared by all Bots. Set it up, or choose one on another computer, under Settings → Computer.") {
                Text("This Bot uses the shared VM when it needs Linux.").font(.system(size: 13)).foregroundStyle(MacTheme.secondary)
                Button("Shared VM settings…") { desktop.settingsTab = .computer; desktop.panel = .settings }.buttonStyle(InspectorButtonStyle())
            }
            InspectorCard(title: "Shared memory", footer: "Every Bot can see these. Remove anything that is out of date.") {
                ForEach(app.workspace.sharedMemory ?? [], id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(item).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button { app.updateSharedMemory((app.workspace.sharedMemory ?? []).filter { $0 != item }) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(MacTheme.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Remove shared memory item")
                    }
                }
                HStack {
                    TextField("Add something every Bot should know", text: $sharedDraft).textFieldStyle(.roundedBorder).font(.system(size: 12)).onSubmit(addShared)
                    Button("Add", action: addShared).buttonStyle(InspectorButtonStyle(compact: true)).disabled(sharedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if bot.memberIDs == nil {
                MacBotSkillsCard(bot: bot)
                MacShareBotCard(bot: bot)
            }
            if bot.memberIDs == nil {
                DisclosureGroup(isExpanded: $showProviders) {
                    MacBotProviderSettingsView(bot: bot).padding(.top, 10)
                } label: {
                    Text("Providers & models").font(.system(size: 13, weight: .semibold)).foregroundStyle(MacTheme.secondary)
                }.padding(.horizontal, 4)
            }
        }
    }

    private func addShared() {
        let item = sharedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.isEmpty else { return }
        if app.updateSharedMemory((app.workspace.sharedMemory ?? []) + [item]) { sharedDraft = "" }
    }

    private var memoryCard: some View {
        InspectorCard(title: "Memory", footer: editingDetails ? nil : "Memory is separate from chat history. Editing it does not erase messages.") {
            if editingDetails {
                TextField("Bot name", text: $nameDraft).textFieldStyle(.roundedBorder)
                TextField("Purpose", text: $purposeDraft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6)
                Text("Private memory, one item per line").font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
                TextEditor(text: $memoryDraft).font(.system(size: 13)).frame(minHeight: 110)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(MacTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 8) {
                    Button("Save") {
                        let items = memoryDraft.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        if app.updateDetails(bot, name: nameDraft, purpose: purposeDraft, memory: items) { editingDetails = false }
                    }.buttonStyle(InspectorButtonStyle(tint: tint, ink: ink))
                    Button("Cancel") { editingDetails = false }.buttonStyle(InspectorButtonStyle())
                }
            } else {
                if (bot.memory ?? []).isEmpty {
                    Text("Nothing saved yet.").font(.system(size: 13)).foregroundStyle(MacTheme.secondary)
                } else {
                    ForEach(bot.memory ?? [], id: \.self) { Text($0).font(.system(size: 13)).textSelection(.enabled) }
                }
                Button("Edit name, purpose and memory") { nameDraft = bot.name; purposeDraft = bot.purpose; memoryDraft = (bot.memory ?? []).joined(separator: "\n"); editingDetails = true }
                    .buttonStyle(InspectorButtonStyle())
            }
        }
    }

    private var routinesCard: some View {
        InspectorCard(title: "Routines", footer: "You can also ask in chat to add one. A routine runs at a set time, repeats hourly, daily or weekly, or runs when another Bot messages it. The app must be running; missed runs catch up once.") {
            Button("Create routine…") { editingRoutine = nil; routineName = ""; routineInstruction = ""; routineDate = Date().addingTimeInterval(3600); routineZone = TimeZone.current.identifier; routineRepeat = "none"; routineTrigger = "time"; routineContains = ""; creatingRoutine = true }
                .buttonStyle(InspectorButtonStyle())
            if creatingRoutine {
                Divider()
                TextField("Routine name", text: $routineName).textFieldStyle(.roundedBorder)
                TextField("What should this Bot do?", text: $routineInstruction, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                Picker("Trigger", selection: $routineTrigger) { Text("At a time").tag("time"); Text("Bot message received").tag("message") }
                if routineTrigger == "time" {
                    TextField("Time zone, for example America/Chicago", text: $routineZone).textFieldStyle(.roundedBorder)
                    DatePicker("First run", selection: $routineDate, in: Date()...).environment(\.timeZone, TimeZone(identifier: routineZone) ?? .current)
                    Picker("Repeat", selection: $routineRepeat) {
                        Text("Once").tag("none"); Text("Hourly").tag("hourly"); Text("Daily").tag("daily"); Text("Weekly").tag("weekly")
                    }
                } else {
                    TextField("Message text to match (optional)", text: $routineContains).textFieldStyle(.roundedBorder)
                    Text("Runs when another Bot sends a message. Messages sent before you save do not trigger it.").font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
                }
                HStack(spacing: 8) {
                    Button(editingRoutine == nil ? "Save routine" : "Save changes") { saveRoutine() }.buttonStyle(InspectorButtonStyle(tint: tint, ink: ink))
                    Button("Cancel") { creatingRoutine = false }.buttonStyle(InspectorButtonStyle())
                }
            }
            if (bot.schedules ?? []).isEmpty, !creatingRoutine {
                Text("No routines yet.").font(.system(size: 13)).foregroundStyle(MacTheme.secondary)
            }
            ForEach(bot.schedules ?? []) { task in
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.name).font(.system(size: 14, weight: .semibold))
                    Text("\(task.enabled ? (task.nextRun ?? "When another Bot messages") : "Paused") · \(task.recurrence) · \(task.timezone)").font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
                    if let last = task.lastRun { Text("Last run \(last) · \(task.lastResult ?? "no result")").font(.system(size: 12)).foregroundStyle(MacTheme.secondary) }
                    if !(task.history ?? []).isEmpty {
                        DisclosureGroup("Run history") {
                            ForEach((task.history ?? []).reversed()) { run in Text("\(run.date) · \(run.status)").font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        }.font(.system(size: 12))
                    }
                    HStack(spacing: 6) {
                        Button("Run now") { desktop.runRoutineNow(task, for: bot, app: app) }.disabled(busy || bot.memberIDs != nil)
                        Button("Edit") {
                            editingRoutine = task; routineName = task.name; routineInstruction = task.text; routineZone = task.timezone
                            routineDate = task.nextRun.flatMap(BotSchedule.date) ?? Date().addingTimeInterval(3600)
                            routineRepeat = task.recurrence; routineTrigger = task.eventBased ? "message" : "time"; routineContains = task.contains ?? ""; creatingRoutine = true
                        }.disabled(busy)
                        Button(task.enabled ? "Pause" : "Resume") {
                            var updated = task; updated.enabled.toggle(); _ = app.updateSchedule(updated, botID: bot.id)
                        }
                        Button("Delete", role: .destructive) { routineToDelete = task }.buttonStyle(InspectorButtonStyle(destructive: true, compact: true))
                    }.buttonStyle(InspectorButtonStyle(compact: true))
                }
            }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            if files.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text").font(.system(size: 28, weight: .light)).foregroundStyle(MacTheme.secondary)
                    Text("No files yet").font(.system(size: 17, weight: .semibold))
                    Text("Files this Bot creates in its working folder show up here.")
                        .font(.system(size: 13)).foregroundStyle(MacTheme.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 36)
            } else {
                ForEach(files, id: \.path) { file in
                    Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text").font(.system(size: 18)).foregroundStyle(MacTheme.secondary)
                            Text(displayName(file.lastPathComponent))
                                .font(.system(size: 14)).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(MacTheme.secondary)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(MacTheme.panel, in: RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).help("Show \(file.lastPathComponent) in Finder")
                }
            }
            if let fileError { Text(fileError).font(.system(size: 12)).foregroundStyle(MacTheme.secondary) }
            HStack(spacing: 8) {
                Button("Refresh") { refreshFiles() }
                Button("Open folder") { desktop.openWorkingDirectory(for: bot) }
            }.buttonStyle(InspectorButtonStyle()).padding(.top, 4)
        }
    }

    /// Attachments are stored as "<uuid>-<name>"; show just the name.
    private func displayName(_ stored: String) -> String {
        let pattern = #"^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}-"#
        return stored.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    // MARK: Activity (10.1.1): what the Bot is doing and the things you reach for most, in the same quiet layout as the Grok Bot panel.

    private var groupsWithThisBot: [Bot] { app.workspace.bots.filter { $0.memberIDs?.contains(bot.id) == true } }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !suggestionsHidden, bot.memberIDs == nil { suggested }
            if bot.memberIDs != nil { groupMembersCard } else { computerCard }
            if bot.memberIDs == nil { MacVoiceCard(bot: bot) }
            if bot.memberIDs == nil { routinesCard }
            if bot.memberIDs == nil { groupChatsCard }
            recentActivity
        }
    }

    private var suggested: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Suggested").font(.system(size: 12, weight: .medium)).foregroundStyle(MacTheme.secondary)
                Spacer()
                Button("Hide") { withAnimation(.snappy(duration: 0.2)) { suggestionsHidden = true } }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
            }.padding(.horizontal, 6)
            InspectorRows {
                InspectorRow(symbol: "clock", title: "Create a routine") {
                    editingRoutine = nil; routineName = ""; routineInstruction = ""; routineDate = Date().addingTimeInterval(3600)
                    routineZone = TimeZone.current.identifier; routineRepeat = "none"; routineTrigger = "time"; routineContains = ""; creatingRoutine = true
                }
                if desktop.gateway == nil {
                    InspectorRow(symbol: "person.3", title: "Start a group chat with \(bot.name)") { desktop.groupSeed = bot.id; desktop.panel = .newGroup }
                }
                InspectorRow(symbol: "sparkles", title: "Add a skill") { tab = .details }
            }
        }
    }

    /// The Bot's computer: a screen-like tile on the right, its state underneath its name, and the actions that used to live on their own tab.
    private var computerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Computer").font(.system(size: 12, weight: .medium)).foregroundStyle(MacTheme.secondary).padding(.horizontal, 6)
            InspectorRows {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Bot\u{2019}s computer").font(.system(size: 14))
                        Text(busy ? "Working\u{2026}" : (desktop.gateway == nil ? "Runs on this Mac" : "Runs on \(desktop.gateway?.hostName ?? "another computer")"))
                            .font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
                        if let provider = desktop.providersToRun(for: bot).first {
                            Text(provider.cli.provider.name + (provider.choice.model.isEmpty ? "" : " \u{00B7} " + provider.choice.model))
                                .font(.system(size: 12)).foregroundStyle(MacTheme.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55))
                        MacBotAvatar(color: bot.color, size: 20, appearance: bot.appearance).opacity(busy ? 1 : 0.55)
                    }.frame(width: 62, height: 42).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
                        .accessibilityHidden(true)
                }.padding(.vertical, 2)
                InspectorRow(symbol: "globe", title: "Open browser") { do { _ = try LocalBotBrowsers.shared.open(bot, reveal: true) } catch { app.errorMessage = error.localizedDescription } }
                InspectorRow(symbol: "folder", title: "Open working folder") { desktop.openWorkingDirectory(for: bot) }
                if MacBotVMs.shared.assigned(bot.id) != nil { InspectorRow(symbol: "display", title: "Open VM console") { Task { await MacBotVMs.shared.open(bot) } } }
                if busy { InspectorRow(symbol: "stop.fill", title: "Stop response") { desktop.stop(botID: bot.id) } }
                InspectorRow(symbol: "wrench.and.screwdriver", title: "AI CLI setup") { desktop.panel = .setup }
            }
        }
    }

    /// Group chats this Bot is part of, and a way to start another one with it.
    private var groupChatsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Group chats").font(.system(size: 12, weight: .medium)).foregroundStyle(MacTheme.secondary).padding(.horizontal, 6)
            InspectorRows {
                ForEach(groupsWithThisBot) { group in
                    InspectorRow(symbol: "person.3", title: group.name, detail: "\((group.memberIDs ?? []).count) Bots") { desktop.selectedID = group.id }
                }
                if desktop.gateway == nil {
                    InspectorRow(symbol: "plus", title: "New group chat with \(bot.name)") { desktop.groupSeed = bot.id; desktop.panel = .newGroup }
                } else if groupsWithThisBot.isEmpty {
                    Text("No group chats yet.").font(.system(size: 13)).foregroundStyle(MacTheme.secondary)
                }
            }
            if groupsWithThisBot.isEmpty, desktop.gateway == nil {
                Text("A group chat puts several Bots in one conversation. Each answers with its own provider and model.")
                    .font(.system(size: 12)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
            }
        }
    }

    /// A group chat's own members: open one, remove one, or add another Bot (2 to 8 in total).
    private var groupMembersCard: some View {
        let ids = bot.memberIDs ?? []
        let members = ids.compactMap { id in app.workspace.bots.first { $0.id == id } }
        let others = app.workspace.bots.filter { $0.memberIDs == nil && !ids.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Members").font(.system(size: 12, weight: .medium)).foregroundStyle(MacTheme.secondary).padding(.horizontal, 6)
            InspectorRows {
                ForEach(members) { member in
                    HStack(spacing: 10) {
                        Button { desktop.selectedID = member.id } label: {
                            HStack(spacing: 10) {
                                MacBotAvatar(color: member.color, size: 22, appearance: member.appearance)
                                Text(member.name).font(.system(size: 14))
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(MacTheme.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { _ = app.setGroupMembers(bot, members: ids.filter { $0 != member.id }) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(MacTheme.secondary)
                        }.buttonStyle(.plain).disabled(ids.count <= 2).accessibilityLabel("Remove \(member.name) from the group").help(ids.count <= 2 ? "A group needs at least 2 Bots" : "Remove from the group")
                    }
                }
                if ids.count < 8, !others.isEmpty {
                    Menu {
                        ForEach(others) { other in Button(other.name) { _ = app.setGroupMembers(bot, members: ids + [other.id]) } }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 13)).frame(width: 22).foregroundStyle(MacTheme.secondary)
                            Text("Add a Bot").font(.system(size: 14))
                            Spacer()
                        }.contentShape(Rectangle())
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                }
            }
            Text("Each member answers with its own provider and model. A group has 2 to 8 Bots.")
                .font(.system(size: 12)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent activity").font(.system(size: 12, weight: .medium)).foregroundStyle(MacTheme.secondary).padding(.horizontal, 6)
            InspectorRows {
                let events = app.entries(for: bot).filter { $0.kind == .activity }.suffix(5)
                if events.isEmpty { Text("Nothing recorded yet.").font(.system(size: 13)).foregroundStyle(MacTheme.secondary) }
                ForEach(Array(events)) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.date, format: .dateTime.hour().minute()).font(.system(size: 11)).foregroundStyle(MacTheme.secondary)
                        Text(event.text).font(.system(size: 13)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func saveRoutine() {
        let name = routineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = routineInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let zone = routineTrigger == "time" ? routineZone.trimmingCharacters(in: .whitespacesAndNewlines) : TimeZone.current.identifier
        guard !name.isEmpty, name.count <= 200, !instruction.isEmpty, instruction.count <= 8000,
              TimeZone(identifier: zone) != nil, routineContains.count <= 200,
              routineTrigger != "time" || routineDate > Date() else { app.errorMessage = "Enter a name, instruction, valid time zone and future run time."; return }
        let next = routineTrigger == "time" ? ISO8601DateFormatter().string(from: routineDate) : nil
        var task = editingRoutine ?? BotSchedule(name: name, text: instruction, recurrence: "none", timezone: zone)
        let triggerChanged = task.nextRun != next || task.contains != (routineTrigger == "message" ? routineContains : nil)
        task.name = name; task.text = instruction; task.nextRun = next; task.recurrence = routineTrigger == "time" ? routineRepeat : "none"; task.timezone = zone
        task.contains = routineTrigger == "message" ? routineContains : nil
        if triggerChanged {
            task.occurrence = UUID()
            if routineTrigger == "message" { task.lastEvent = app.entries(for: bot).last(where: { $0.kind == .activity && $0.senderBotID != nil })?.id }
        }
        let saved = editingRoutine == nil ? app.createSchedule(task, botID: bot.id) : app.updateSchedule(task, botID: bot.id)
        if saved { creatingRoutine = false; editingRoutine = nil; routineName = ""; routineInstruction = "" }
    }

    private func refreshFiles() {
        let directory = desktop.workingDirectory(for: bot)
        guard FileManager.default.fileExists(atPath: directory.path) else { files = []; fileError = nil; return }
        do {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
            let rootFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            let folder = directory.appendingPathComponent("Attachments", isDirectory: true)
            let attachmentFiles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
            files = (rootFiles + attachmentFiles).filter { url in
                guard let info = try? url.resourceValues(forKeys: keys) else { return false }
                return info.isRegularFile == true && info.isSymbolicLink != true
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            fileError = nil
        } catch { files = []; fileError = "The files could not be read. Try opening the folder in Finder." }
    }
}

/// A titled group of controls on a rounded card. Everything inside aligns to the leading edge.
struct InspectorCard<Content: View>: View {
    let title: String?
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(MacTheme.secondary)
                    .padding(.horizontal, 6).accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).background(MacTheme.panel, in: RoundedRectangle(cornerRadius: 14))
            if let footer {
                Text(footer).font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

/// One button look for the whole panel: a filled capsule, tinted when it is the main action.
struct InspectorButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var ink: Color = .white
    var destructive = false
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .medium))
            .foregroundStyle(destructive ? Color.red : (tint == nil ? Color.primary : ink))
            .padding(.horizontal, compact ? 10 : 14).frame(minHeight: compact ? 28 : 34)
            .background((tint ?? MacTheme.raised).opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}


/// A quiet rounded list: rows separated by hairlines, like the Grok Bot panel. Put `InspectorRow`s (or any views) inside.
struct InspectorRows<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        _VariadicView.Tree(InspectorRowsLayout()) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(MacTheme.panel, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct InspectorRowsLayout: _VariadicView_UnaryViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                child.padding(.vertical, 9)
                if index < children.count - 1 { Divider().opacity(0.6) }
            }
        }
    }
}

/// One row: a small symbol, a title, an optional detail, and a chevron.
struct InspectorRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(MacTheme.secondary).frame(width: 20)
                Text(title).font(.system(size: 14)).lineLimit(1)
                Spacer(minLength: 8)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(MacTheme.secondary) }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(MacTheme.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
