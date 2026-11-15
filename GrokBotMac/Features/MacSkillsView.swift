import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The skills saved on this Mac (10.1). A skill is text a Bot follows; nothing here runs code.
@MainActor
final class MacSkillLibrary: ObservableObject {
    @Published private(set) var skills: [BotSkill] = []
    @Published private(set) var loadError: String?
    private let url: URL

    nonisolated static var defaultURL: URL {
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["OPENGROKBOT_TEST_WORKSPACE_DIR"] { return URL(fileURLWithPath: directory).appendingPathComponent("skills.json") }
        #endif
        return URL.applicationSupportDirectory.appending(path: "OpenGrokBot", directoryHint: .isDirectory).appending(path: "skills.json")
    }

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let library = try? JSONDecoder().decode(SkillLibrary.self, from: data) else {
            loadError = "The skills file could not be read, so it was left alone. Move or fix it, then restart Bothive."
            return
        }
        skills = Array(library.skills.filter(BotSkills.isValid).prefix(BotSkills.maxSkills))
    }

    private func persist(_ next: [BotSkill]) throws {
        if let loadError { throw SkillError(loadError) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(SkillLibrary(skills: next)).write(to: url, options: .atomic)
        skills = next
    }

    /// Adds a skill, or changes the one with `id`.
    @discardableResult
    func save(id: UUID?, name: String, description: String, text: String, source: String? = nil) throws -> BotSkill {
        var next = skills
        if let id, let index = next.firstIndex(where: { $0.id == id }) {
            var made = try BotSkills.make(name: name, description: description, text: text, source: source ?? next[index].source, id: id)
            made.addedAt = next[index].addedAt
            next[index] = made
            try persist(next)
            return made
        }
        guard next.count < BotSkills.maxSkills else { throw SkillError("You have the most skills this app keeps (200). Delete one first.") }
        let made = try BotSkills.make(name: name, description: description, text: text, source: source ?? "written here")
        next.append(made)
        try persist(next)
        return made
    }

    /// The saved skill with the same name and text, if there is one (so a shared Bot does not add a second copy).
    func existing(_ draft: SkillDraft) -> BotSkill? {
        skills.first { $0.name == draft.name && $0.text == draft.text }
    }

    func delete(_ id: UUID) throws {
        try persist(skills.filter { $0.id != id })
    }

    func note(for bot: Bot) -> String {
        BotSkills.promptNote(enabled: bot.skills, skills: skills)
    }
}

// MARK: - Settings → Skills

struct MacSkillsSettings: View {
    @EnvironmentObject private var desktop: MacAppModel
    var body: some View { MacSkillsPage(library: desktop.skills) }
}

private struct MacSkillsPage: View {
    @ObservedObject var library: MacSkillLibrary
    @EnvironmentObject private var app: AppModel

    @State private var editingID: UUID?
    @State private var editing = false
    @State private var nameDraft = ""
    @State private var descriptionDraft = ""
    @State private var textDraft = ""
    @State private var address = ""
    @State private var searching = false
    @State private var found: SkillSearch?
    @State private var chosen: Set<String> = []
    @State private var previews: [SkillDraft] = []
    @State private var message: String?
    @State private var toDelete: BotSkill?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("A skill is a set of instructions a Bot follows, like \u{201C}always list sources\u{201D} or \u{201C}write in my voice\u{201D}. Turn skills on for each Bot in its side panel. Skills are text only: they cannot run anything or approve anything.")
                .font(.system(size: 14)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = library.loadError { Text(error).font(.system(size: 13)).foregroundStyle(.red) }
            if editing { editor } else { yourSkills }
            if let message { Text(message).font(.system(size: 13)).foregroundStyle(MacTheme.secondary).textSelection(.enabled) }
            fromGitHub
        }
        .confirmationDialog("Delete this skill?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), presenting: toDelete) { skill in
            Button("Delete \u{201C}\(skill.name)\u{201D}", role: .destructive) {
                do { try library.delete(skill.id); app.forgetSkill(skill.id); message = "Skill deleted." } catch { message = error.localizedDescription }
            }
        } message: { _ in Text("Bots that use it stop following it.") }
    }

    private var yourSkills: some View {
        InspectorCard(title: "Your skills") {
            if library.skills.isEmpty {
                Text("No skills yet. Write one, load one from a file, or add one from GitHub below.").font(.system(size: 13)).foregroundStyle(MacTheme.secondary)
            }
            ForEach(library.skills) { skill in
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name).font(.system(size: 14, weight: .semibold))
                    Text(skill.description.isEmpty ? "No description" : skill.description).font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
                    Text("\(skill.source) \u{00B7} \(skill.text.count) characters").font(.system(size: 11)).foregroundStyle(MacTheme.secondary)
                    HStack(spacing: 6) {
                        Button("Edit") { beginEdit(skill) }
                        Button("Delete", role: .destructive) { toDelete = skill }.buttonStyle(InspectorButtonStyle(destructive: true, compact: true))
                    }.buttonStyle(InspectorButtonStyle(compact: true))
                }
                Divider()
            }
            HStack(spacing: 8) {
                Button("New skill") { beginEdit(nil) }.buttonStyle(InspectorButtonStyle(tint: .accentColor))
                Button("Add from a file\u{2026}") { addFromFile() }.buttonStyle(InspectorButtonStyle())
            }
        }
    }

    private var editor: some View {
        InspectorCard(title: editingID == nil ? "New skill" : "Edit skill") {
            TextField("Name, for example Cite sources", text: $nameDraft).textFieldStyle(.roundedBorder)
            TextField("What it is for (one line the Bot sees first)", text: $descriptionDraft).textFieldStyle(.roundedBorder)
            TextEditor(text: $textDraft).font(.system(size: 13)).frame(minHeight: 220)
                .scrollContentBackground(.hidden).padding(6).background(MacTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
            Text("Write what the Bot should do, in plain language. Markdown is fine. Up to 20,000 characters.").font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
            HStack(spacing: 8) {
                Button("Save skill") {
                    do { try library.save(id: editingID, name: nameDraft, description: descriptionDraft, text: textDraft); editing = false; message = "Skill saved." }
                    catch { message = error.localizedDescription }
                }.buttonStyle(InspectorButtonStyle(tint: .accentColor))
                Button("Cancel") { editing = false }.buttonStyle(InspectorButtonStyle())
            }
        }
    }

    private var fromGitHub: some View {
        InspectorCard(title: "Add from GitHub or skills.sh", footer: "Paste an address like github.com/owner/repo, a skills.sh page, or an \u{201C}npx skills add owner/repo\u{201D} command. Bothive looks for SKILL.md files in that public repository and shows you the text before anything is saved. Only the text is kept; scripts in the repository are ignored.") {
            HStack(spacing: 8) {
                TextField("github.com/owner/repo  \u{00B7}  skills.sh/owner/repo/skill  \u{00B7}  owner/repo", text: $address).textFieldStyle(.roundedBorder).onSubmit(search)
                Button(searching ? "Looking\u{2026}" : "Find skills", action: search).buttonStyle(InspectorButtonStyle(tint: .accentColor)).disabled(searching || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let found {
                Text("\(found.items.count) skill\(found.items.count == 1 ? "" : "s") in \(found.owner)/\(found.repo). Choose up to 5 to read.").font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
                ForEach(found.items, id: \.path) { item in
                    Toggle(isOn: Binding(get: { chosen.contains(item.path) }, set: { if $0 { chosen.insert(item.path) } else { chosen.remove(item.path) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.folder).font(.system(size: 13))
                            Text(item.path).font(.system(size: 11)).foregroundStyle(MacTheme.secondary)
                        }
                    }.toggleStyle(.checkbox)
                }
                Button("Read the selected skills") { readChosen(found) }.buttonStyle(InspectorButtonStyle()).disabled(chosen.isEmpty || searching)
            }
            if !previews.isEmpty {
                Text("Read this first. A skill is instructions written by someone else. Only add ones you trust: a Bot will follow it where it fits.").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                ForEach(previews, id: \.source) { draft in preview(draft) }
            }
        }
    }

    private func preview(_ draft: SkillDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.name).font(.system(size: 14, weight: .semibold))
            Text(draft.description.isEmpty ? "No description" : draft.description).font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
            Text("\(draft.source) \u{00B7} \(draft.text.count) characters").font(.system(size: 11)).foregroundStyle(MacTheme.secondary)
            ScrollView { Text(String(draft.text.prefix(1500)) + (draft.text.count > 1500 ? "\n\u{2026}" : "")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 160).padding(8).background(MacTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
            Button("Add this skill") { add(draft) }.buttonStyle(InspectorButtonStyle(tint: .accentColor))
        }
    }

    private func beginEdit(_ skill: BotSkill?) {
        editingID = skill?.id; nameDraft = skill?.name ?? ""; descriptionDraft = skill?.description ?? ""; textDraft = skill?.text ?? ""; editing = true
    }

    private func search() {
        guard !searching else { return }
        searching = true; message = nil; found = nil; chosen = []; previews = []
        let input = address
        Task {
            do {
                let result = try await BotSkills.find(input)
                found = result
                if result.items.count == 1 { chosen = [result.items[0].path] }
            } catch { message = error.localizedDescription }
            searching = false
        }
    }

    private func readChosen(_ search: SkillSearch) {
        let paths = search.items.map(\.path).filter { chosen.contains($0) }.prefix(5)
        searching = true; message = nil; previews = []
        Task {
            do {
                var drafts: [SkillDraft] = []
                for path in paths { drafts.append(try await BotSkills.fetchSkill(owner: search.owner, repo: search.repo, ref: search.ref, path: path)) }
                previews = drafts
            } catch { message = error.localizedDescription }
            searching = false
        }
    }

    private func add(_ draft: SkillDraft) {
        do {
            try library.save(id: nil, name: draft.name, description: draft.description, text: draft.text, source: draft.source)
            previews.removeAll { $0.source == draft.source }
            message = "Added \u{201C}\(draft.name)\u{201D}. Turn it on for a Bot in its side panel."
        } catch { message = error.localizedDescription }
    }

    private func addFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown"), UTType.plainText].compactMap { $0 }
        panel.message = "Choose a skill file (SKILL.md or any Markdown or text file under 100 KB)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= BotSkills.maxFetchBytes else { throw SkillError("Choose a skill file under 100 KB.") }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw SkillError("That file is not text.") }
            let base = url.lastPathComponent
            let fallback = base.lowercased() == "skill.md" ? url.deletingLastPathComponent().lastPathComponent : url.deletingPathExtension().lastPathComponent
            var draft = try BotSkills.parseMarkdown(text, fallbackName: fallback)
            draft.source = "file: " + String(base.prefix(80))
            previews = [draft]
            message = nil
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Bot panel: which skills this Bot follows, and sharing it

struct MacBotSkillsCard: View {
    let bot: Bot
    @EnvironmentObject private var desktop: MacAppModel
    var body: some View { MacBotSkillsList(bot: bot, library: desktop.skills) }
}

private struct MacBotSkillsList: View {
    let bot: Bot
    @ObservedObject var library: MacSkillLibrary
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var desktop: MacAppModel
    private var live: Bot { app.workspace.bots.first { $0.id == bot.id } ?? bot }

    var body: some View {
        InspectorCard(title: "Skills", footer: "Instructions this Bot follows, written by you or added from GitHub.") {
            if library.skills.isEmpty { Text("No skills yet.").font(.system(size: 13)).foregroundStyle(MacTheme.secondary) }
            ForEach(library.skills) { skill in
                Toggle(isOn: Binding(
                    get: { live.skills?.contains(skill.id) == true },
                    set: { on in
                        var ids = live.skills ?? []
                        if on { if !ids.contains(skill.id) { ids.append(skill.id) } } else { ids.removeAll { $0 == skill.id } }
                        _ = app.setSkills(ids, for: live)
                    })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(skill.name).font(.system(size: 13))
                        if !skill.description.isEmpty { Text(skill.description).font(.system(size: 11)).foregroundStyle(MacTheme.secondary).lineLimit(2) }
                    }
                }.toggleStyle(.checkbox)
            }
            Button("Manage skills\u{2026}") { desktop.openSettings(.skills) }.buttonStyle(InspectorButtonStyle(compact: true))
        }
    }
}

struct MacShareBotCard: View {
    let bot: Bot
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var desktop: MacAppModel
    @State private var includeSkills = true
    @State private var note: String?
    private var live: Bot { app.workspace.bots.first { $0.id == bot.id } ?? bot }
    private var hasSkills: Bool { !(live.skills ?? []).isEmpty }

    var body: some View {
        InspectorCard(title: "Share this Bot", footer: note ?? "Copy a code a friend can paste into Bothive to get their own copy. It holds the name, description and look only. Your chats, memory and files stay here.") {
            Toggle("Include its skills", isOn: $includeSkills).toggleStyle(.checkbox).disabled(!hasSkills).font(.system(size: 13))
            Button("Copy share code", systemImage: "link") {
                do {
                    let ids = Set(live.skills ?? [])
                    let code = try BotShare.make(bot: live, skills: includeSkills && hasSkills ? desktop.skills.skills.filter { ids.contains($0.id) } : [])
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    note = "Share code copied. Send it to a friend."
                } catch { note = error.localizedDescription }
            }.buttonStyle(InspectorButtonStyle())
        }
    }
}

/// In the new-Bot dialog: paste a code from a friend, look at what is in it, then add it.
struct MacAddFromCodeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var desktop: MacAppModel
    @State private var code = ""
    @State private var card: BotShare.Card?
    @State private var includeSkills = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $code).font(.system(size: 12, design: .monospaced)).frame(minHeight: 64, maxHeight: 90)
                .scrollContentBackground(.hidden).padding(8).background(MacTheme.raised, in: RoundedRectangle(cornerRadius: 10))
            Button("Look at it") { look() }.buttonStyle(InspectorButtonStyle(compact: true)).disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        CustomBotAvatar(appearance: BotAppearance(shape: card.shape, color: card.color), size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name).font(.system(size: 14, weight: .semibold))
                            Text(card.purpose.isEmpty ? "No description" : card.purpose).font(.system(size: 12)).foregroundStyle(MacTheme.secondary).lineLimit(4)
                        }
                    }
                    if !card.skills.isEmpty {
                        Text("It brings \(card.skills.count) skill\(card.skills.count == 1 ? "" : "s"): \(card.skills.map(\.name).joined(separator: ", ")). Skills are instructions the Bot will follow, so only include them from someone you trust.")
                            .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Toggle("Include the skills", isOn: $includeSkills).toggleStyle(.checkbox).font(.system(size: 13))
                    }
                    Button("Add this Bot") { add(card) }.buttonStyle(InspectorButtonStyle(tint: .accentColor))
                }.padding(12).background(MacTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(.top, 8)
    }

    private func look() {
        note = nil; card = nil; includeSkills = false
        do { card = try BotShare.read(code) } catch { note = error.localizedDescription }
    }

    private func add(_ card: BotShare.Card) {
        var ids: [UUID] = []
        if includeSkills {
            for draft in card.skills {
                if let existing = desktop.skills.existing(draft) { ids.append(existing.id); continue }
                if let saved = try? desktop.skills.save(id: nil, name: draft.name, description: draft.description, text: draft.text, source: draft.source) { ids.append(saved.id) }
            }
        }
        if let id = app.addSharedBot(card, skills: ids) {
            desktop.selectedID = id
            desktop.panel = nil
        } else { note = "That Bot could not be added here." }
    }
}
