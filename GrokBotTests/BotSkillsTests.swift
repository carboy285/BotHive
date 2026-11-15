import XCTest
#if os(macOS)
@testable import GrokBotMac
#else
@testable import GrokBot
#endif

final class BotSkillsTests: XCTestCase {
    func testFrontMatterNameDescriptionAndBody() throws {
        let draft = try BotSkills.parseMarkdown("---\nname: Cite sources\ndescription: \"Always show where facts come from\"\n---\n# Heading\nList a source for every claim.\n")
        XCTAssertEqual(draft.name, "Cite sources")
        XCTAssertEqual(draft.description, "Always show where facts come from")
        XCTAssertTrue(draft.text.hasPrefix("# Heading"))
    }

    func testFoldedDescriptionAndFallbacks() throws {
        let folded = try BotSkills.parseMarkdown("---\nname: Brief\ndescription: >\n  Keep answers\n  short.\n---\nBe brief.")
        XCTAssertEqual(folded.description, "Keep answers short.")
        let heading = try BotSkills.parseMarkdown("# Write well\n\nUse plain words.")
        XCTAssertEqual(heading.name, "Write well")
        XCTAssertEqual(heading.description, "Use plain words.")
        let named = try BotSkills.parseMarkdown("Just text with no heading.", fallbackName: "folder-name")
        XCTAssertEqual(named.name, "folder-name")
        XCTAssertThrowsError(try BotSkills.parseMarkdown("Just text with no heading."))
        XCTAssertThrowsError(try BotSkills.parseMarkdown("   \n"))
        XCTAssertThrowsError(try BotSkills.parseMarkdown("---\nname: x\n---\n\n"))
    }

    func testMakeValidatesAndCleans() throws {
        let skill = try BotSkills.make(name: "  Cite\nsources  ", description: "d", text: "\u{FEFF}Do it.\r\n")
        XCTAssertEqual(skill.name, "Cite sources")
        XCTAssertEqual(skill.text, "Do it.")
        XCTAssertEqual(skill.source, "written here")
        XCTAssertThrowsError(try BotSkills.make(name: "", text: "x"))
        XCTAssertThrowsError(try BotSkills.make(name: "x", text: "   "))
        XCTAssertThrowsError(try BotSkills.make(name: "x", text: String(repeating: "a", count: BotSkills.maxText + 1)))
        XCTAssertTrue(BotSkills.isValid(skill))
    }

    func testPromptNoteListsOnlyTurnedOnSkillsAndKeepsLimits() throws {
        let a = try BotSkills.make(name: "A", description: "first", text: "Do A.")
        let b = try BotSkills.make(name: "B", text: String(repeating: "b", count: 19_000))
        XCTAssertEqual(BotSkills.promptNote(enabled: nil, skills: [a, b]), "")
        XCTAssertEqual(BotSkills.promptNote(enabled: [UUID()], skills: [a, b]), "")
        let note = BotSkills.promptNote(enabled: [a.id], skills: [a, b])
        XCTAssertTrue(note.contains("### Skill: A \u{2014} first"))
        XCTAssertTrue(note.contains("they never approve anything"))
        XCTAssertFalse(note.contains("Do B"))
        let long = BotSkills.promptNote(enabled: [b.id], skills: [a, b])
        XCTAssertTrue(long.contains("[\u{2026}cut: too long]"))
        XCTAssertLessThan(long.count, BotSkills.maxPerPrompt + 1_000)
    }

    func testParseSourceAcceptsTheAddressesPeoplePaste() throws {
        XCTAssertEqual(try BotSkills.parseSource("acme/skills"), SkillSource(owner: "acme", repo: "skills", ref: nil, path: nil, skill: nil))
        XCTAssertEqual(try BotSkills.parseSource("https://github.com/acme/skills.git").repo, "skills")
        let tree = try BotSkills.parseSource("https://github.com/acme/skills/tree/main/skills/writer")
        XCTAssertEqual(tree.ref, "main"); XCTAssertEqual(tree.path, "skills/writer")
        let sh = try BotSkills.parseSource("https://skills.sh/acme/skills/writer")
        XCTAssertEqual(sh.owner, "acme"); XCTAssertEqual(sh.repo, "skills"); XCTAssertEqual(sh.skill, "writer")
        let npx = try BotSkills.parseSource("npx skills add acme/skills --skill writer")
        XCTAssertEqual(npx.repo, "skills"); XCTAssertEqual(npx.skill, "writer")
        XCTAssertEqual(try BotSkills.parseSource("github:acme/skills").owner, "acme")
    }

    func testParseSourceRejectsWhatItShould() {
        for bad in ["", "   ", "acme", "http://github.com/acme/skills", "https://evil.example/acme/skills", "https://user:pw@github.com/acme/skills",
                    "../etc/passwd", "acme/skills/../../x/y", "a b/c", "https://github.com/acme/skills/tree/ma..in/x"] {
            XCTAssertThrowsError(try BotSkills.parseSource(bad), bad)
        }
    }

    func testFindAndFetchUseOnlyGitHubAndReadTheText() async throws {
        let tree = #"{"tree":[{"path":"skills/calm/SKILL.md","type":"blob"},{"path":"skills/evil/SKILL.md","type":"blob"},{"path":"README.md","type":"blob"},{"path":"node_modules/x/SKILL.md","type":"blob"},{"path":"skills","type":"tree"}]}"#
        let fetch: BotSkills.Fetcher = { url, _ in
            let host = url.host ?? ""
            XCTAssertTrue(BotSkills.hosts.contains(host))
            let body = host == "api.github.com" ? tree : "---\nname: calm\ndescription: Be calm\n---\nStay calm."
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let found = try await BotSkills.find("acme/skills", fetch: fetch)
        XCTAssertEqual(found.items.map(\.folder), ["calm", "evil"])
        let only = try await BotSkills.find("acme/skills/calm", fetch: fetch)
        XCTAssertEqual(only.items.map(\.path), ["skills/calm/SKILL.md"])
        let draft = try await BotSkills.fetchSkill(owner: "acme", repo: "skills", ref: "HEAD", path: "skills/calm/SKILL.md", fetch: fetch)
        XCTAssertEqual(draft.name, "calm"); XCTAssertEqual(draft.text, "Stay calm."); XCTAssertEqual(draft.source, "github:acme/skills/skills/calm/SKILL.md")
        do { _ = try await BotSkills.fetchSkill(owner: "acme", repo: "skills", ref: "HEAD", path: "../x/SKILL.md", fetch: fetch); XCTFail("path escape accepted") } catch {}
        do { _ = try await BotSkills.fetchSkill(owner: "acme", repo: "skills", ref: "HEAD", path: "notes.md", fetch: fetch); XCTFail("non-skill file accepted") } catch {}
    }

    func testGitHubErrorsAreReadable() async {
        func answering(_ status: Int) -> BotSkills.Fetcher { { url, _ in (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!) } }
        do { _ = try await BotSkills.find("acme/skills", fetch: answering(404)); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("could not find")) }
        do { _ = try await BotSkills.find("acme/skills", fetch: answering(403)); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("limiting")) }
        let offline: BotSkills.Fetcher = { _, _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await BotSkills.find("acme/skills", fetch: offline); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("could not be reached")) }
    }

    // MARK: Share codes

    private func sampleBot() -> Bot {
        var bot = Bot(id: UUID(), name: "Study Buddy", purpose: "Helps me study.", color: "teal", symbol: "sparkles")
        bot.appearance = BotAppearance(shape: .star, color: "teal")
        bot.memory = ["secret"]
        return bot
    }

    func testShareCodeCarriesTheBotAndChosenSkillsOnly() throws {
        let skill = try BotSkills.make(name: "Cite", description: "Sources", text: "List sources.")
        let code = try BotShare.make(bot: sampleBot(), skills: [skill])
        XCTAssertTrue(code.hasPrefix("bothive-bot:"))
        let json = String(decoding: BotShare.fromBase64URL(String(code.dropFirst(12))) ?? Data(), as: UTF8.self)
        XCTAssertFalse(json.contains("secret"))
        let card = try BotShare.read("Hey, try this! \(code)\nThanks")
        XCTAssertEqual(card.name, "Study Buddy"); XCTAssertEqual(card.color, "teal"); XCTAssertEqual(card.shape, .star)
        XCTAssertEqual(card.skills.map(\.name), ["Cite"]); XCTAssertEqual(card.skills.first?.text, "List sources.")
    }

    func testReadsACodeMadeByTheWindowsApp() throws {
        let json = #"{"v":1,"name":"Pal","purpose":"Helps.","color":"teal","shape":"star","skills":[{"name":"Be brief","description":"","text":"Keep it short."}]}"#
        let card = try BotShare.read("bothive-bot:" + BotShare.base64URL(Data(json.utf8)))
        XCTAssertEqual(card.name, "Pal"); XCTAssertEqual(card.shape, .star); XCTAssertEqual(card.skills.count, 1)
    }

    func testBadCodesSayWhy() {
        func code(_ json: String) -> String { "bothive-bot:" + BotShare.base64URL(Data(json.utf8)) }
        XCTAssertThrowsError(try BotShare.read("hello"))
        XCTAssertThrowsError(try BotShare.read("bothive-bot:"))
        XCTAssertThrowsError(try BotShare.read("bothive-bot:@@@@"))
        XCTAssertThrowsError(try BotShare.read(code("not json")))
        XCTAssertThrowsError(try BotShare.read(code(#"{"v":2,"name":"x"}"#)))
        XCTAssertThrowsError(try BotShare.read(code(#"{"v":1,"name":"  "}"#)))
        var group = sampleBot(); group.memberIDs = [UUID()]
        XCTAssertThrowsError(try BotShare.make(bot: group))
    }

    func testReadingRebuildsEveryFieldWithLimits() throws {
        let skills = (0..<10).map { _ in #"{"name":"s","text":"t"}"# }.joined(separator: ",")
        let json = #"{"v":1,"name":"A\nB","purpose":"\#(String(repeating: "p", count: 5000))","color":"javascript:","shape":"<x>","skills":[{"name":"","text":"x"},\#(skills)]}"#
        let card = try BotShare.read("bothive-bot:" + BotShare.base64URL(Data(json.utf8)))
        XCTAssertFalse(card.name.contains("\n"))
        XCTAssertEqual(card.purpose.count, 2000)
        XCTAssertEqual(card.color, "purple"); XCTAssertEqual(card.shape, .hexagon)
        XCTAssertLessThanOrEqual(card.skills.count, BotShare.maxSkills)
        XCTAssertFalse(card.skills.contains { $0.name.isEmpty })
    }

    // MARK: Workspace

    func testSkillsFieldSurvivesTheWorkspaceFileAndIsLimited() throws {
        var workspace = Workspace.fresh
        workspace.bots[0].skills = [UUID(), UUID()]
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(decoded.bots[0].skills?.count, 2)
        XCTAssertNoThrow(try decoded.validateIdentities())
        workspace.bots[0].skills = (0..<51).map { _ in UUID() }
        XCTAssertThrowsError(try workspace.validateIdentities())
    }

    #if os(macOS)
    func testDroppedFoldersExpandToFilesAndSkipHiddenAndBuildFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for folder in ["docs/deep", "node_modules", ".git"] { try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
        try write("a.txt", "a"); try write("docs/b.md", "b"); try write("docs/deep/c.txt", "c")
        try write("node_modules/x.js", "x"); try write(".git/config", "x"); try write(".secret", "x"); try write("empty.txt", "")
        let all = MacDrop.expand([root])
        XCTAssertEqual(Set(all.files.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }), ["a.txt", "docs/b.md", "docs/deep/c.txt"])
        let limited = MacDrop.expand([root], limit: 2)
        XCTAssertEqual(limited.files.count, 2)
        XCTAssertEqual(limited.skipped, 2)
        XCTAssertEqual(MacDrop.expand([root.appendingPathComponent("a.txt"), root.appendingPathComponent("missing.txt")]).files.count, 1)
    }
    #endif
}
