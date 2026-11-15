import SwiftUI

/// Settings → Routines (10.1): every Bot's scheduled tasks in one place. See what runs and when, pause or resume, run one now,
/// add one, or delete it. To change what a routine says, use the Bot's own panel.
struct MacRoutinesSettings: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var desktop: MacAppModel

    @State private var botID: UUID?
    @State private var name = ""
    @State private var instruction = ""
    @State private var firstRun = Calendar.current.date(bySetting: .minute, value: 0, of: Date().addingTimeInterval(3600)) ?? Date().addingTimeInterval(3600)
    @State private var repeatRule = "daily"
    @State private var message: String?
    @State private var toDelete: (bot: Bot, task: BotSchedule)?

    private struct Row: Identifiable {
        var bot: Bot
        var task: BotSchedule
        var id: UUID { task.id }
    }

    private var bots: [Bot] { app.workspace.bots.filter { $0.memberIDs == nil } }
    private var rows: [Row] {
        bots.flatMap { bot in (bot.schedules ?? []).map { Row(bot: bot, task: $0) } }
            .sorted { a, b in
                if a.task.enabled != b.task.enabled { return a.task.enabled }
                return (a.task.nextRun ?? "9") < (b.task.nextRun ?? "9")
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            let all = rows
            Text(summary(all))
                .font(.system(size: 14)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true)
            InspectorCard(title: "All routines") {
                if all.isEmpty {
                    Text("Add one below, or ask a Bot in chat: \u{201C}every morning at 8, summarize my open tasks\u{201D}.").font(.system(size: 13)).foregroundStyle(MacTheme.secondary)
                }
                ForEach(all) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.task.name).font(.system(size: 14, weight: .semibold))
                        Text("\(row.bot.name) \u{00B7} \(when(row.task))").font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
                        if let last = row.task.lastRun {
                            Text("Last ran \(BotSchedule.date(last)?.formatted(date: .abbreviated, time: .shortened) ?? last)\(row.task.lastResult.map { " \u{00B7} " + $0 } ?? "")")
                                .font(.system(size: 11)).foregroundStyle(MacTheme.secondary)
                        }
                        HStack(spacing: 6) {
                            Button(row.task.enabled ? "Pause" : "Resume") {
                                var updated = row.task; updated.enabled.toggle(); _ = app.updateSchedule(updated, botID: row.bot.id)
                            }
                            Button("Run now") { desktop.runRoutineNow(row.task, for: row.bot, app: app) }
                                .disabled(desktop.runningBots.contains(row.bot.id))
                            Button("Open Bot") { desktop.selectedID = row.bot.id; desktop.panel = nil; desktop.showBotInspector = true }
                            Button("Delete", role: .destructive) { toDelete = (row.bot, row.task) }.buttonStyle(InspectorButtonStyle(destructive: true, compact: true))
                        }.buttonStyle(InspectorButtonStyle(compact: true))
                    }
                    Divider()
                }
            }
            creator
            if let message { Text(message).font(.system(size: 13)).foregroundStyle(MacTheme.secondary) }
        }
        .confirmationDialog("Delete this routine?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Delete \u{201C}\(toDelete?.task.name ?? "")\u{201D}", role: .destructive) {
                if let pending = toDelete { _ = app.removeSchedule(pending.task.id, botID: pending.bot.id) }
                toDelete = nil
            }
        }
    }

    private var creator: some View {
        InspectorCard(title: "Add a routine", footer: "Runs at the time you choose, in this Mac\u{2019}s time zone. To start one when another Bot messages, or when mail arrives, use the Bot\u{2019}s own panel.") {
            if bots.isEmpty {
                Text("Create a Bot first.").font(.system(size: 13)).foregroundStyle(MacTheme.secondary)
            } else {
                Picker("Bot", selection: Binding(get: { botID ?? bots[0].id }, set: { botID = $0 })) {
                    ForEach(bots) { Text($0.name).tag($0.id) }
                }
                TextField("Name, for example Morning summary", text: $name).textFieldStyle(.roundedBorder)
                TextField("What should this Bot do?", text: $instruction, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                DatePicker("First run", selection: $firstRun, in: Date()...)
                Picker("Repeat", selection: $repeatRule) {
                    Text("Once").tag("none"); Text("Hourly").tag("hourly"); Text("Daily").tag("daily"); Text("Weekly").tag("weekly")
                }
                Button("Add routine") { add() }.buttonStyle(InspectorButtonStyle(tint: .accentColor))
            }
        }
    }

    private func summary(_ all: [Row]) -> String {
        let count = all.count
        let on = all.filter { $0.task.enabled }.count
        let lead = count == 0 ? "No routines yet." : "\(count) routine" + (count == 1 ? "" : "s") + ", \(on) on."
        return lead + " A routine is a task a Bot does on its own, once, on a repeat, or when another Bot messages it. They run only while Bothive is open; a missed run happens once when you come back."
    }

    private func when(_ task: BotSchedule) -> String {
        if !task.enabled { return "Paused" }
        guard let next = task.nextRun else { return task.source == "mail" ? "When new mail arrives" : task.source == "calendar" ? "Before an event starts" : "When a Bot messages it" }
        let date = BotSchedule.date(next)?.formatted(date: .abbreviated, time: .shortened) ?? next
        let every = ["none": "Once", "hourly": "Every hour", "daily": "Every day", "weekly": "Every week"][task.recurrence] ?? task.recurrence
        return "\(date) \u{00B7} \(every)"
    }

    private func add() {
        guard let target = botID ?? bots.first?.id else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !text.isEmpty else { message = "Give the routine a name and instructions."; return }
        let task = BotSchedule(name: title, text: text, nextRun: ISO8601DateFormatter().string(from: firstRun), recurrence: repeatRule, timezone: TimeZone.current.identifier)
        if app.createSchedule(task, botID: target) { name = ""; instruction = ""; message = "Routine added." } else { message = app.errorMessage ?? "That routine could not be added." }
    }
}
