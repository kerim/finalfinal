//
//  WriteQueuePhase4bTraceE2ETests.swift
//  final finalUITests
//
//  A SMALL PERMANENT REGRESSION SET for the Phase 4b Cmd-Z fix, all on one long article. After a sidebar section operation the
//  automatic rewrites (footnote renumber, Notes list, bibliography) change the document, so it no longer equals the copy saved when the
//  operation finished; Cmd-Z must still undo the SECTION operation instead of being refused. Each test records what it saw (result lines carry
//  the fixture counts) and asserts the outcome a user would see, read from the project database and from the app's own log
//  (`diagnostic.log`, `[STRUCT-TRACE]` and `[FN-DIAG]` lines).
//
//  FIXTURE (invented text, the fixed recipe of POCComplexGenerator in docs/architecture/write-queue-plan/phase3/e2e-scratch/
//  WriteQueuePhase3bReplayPOC.swift.txt): ARTICLE, 7 to 8 thousand words, 68 citation groups that resolve through the Zotero mock library
//  file, 9 footnotes, 30 comment/task/reference marks, Chinese text.
//
//  THE TESTS
//  testDeleteUndoAtOnce_article: delete the same section and press Cmd-Z with NO click in the text, as soon as the test tool can deliver the
//    key, while the automatic rewrites are still landing (the user's rule: nobody should have to wait before Cmd-Z). "At once" therefore means
//    "as early as the tool allows": the tool waits until the app is responsive before it sends a key, which in the VM took between 0.5 s and
//    2.8 s after the delete finished, depending on how busy the VM was (measured 2026-10-12: 2.84 s twice, 0.52 s once). The window before about
//    0.5 s is not reachable with this tool and rests only on the unit tests of the per-chain advance; the old build refused from about 0.4 s
//    after the delete, so a press at 0.5 s is already inside the window that used to fail. The section must come back exactly as in the 15 s
//    test below. See the section "Cmd-Z pressed while the automatic rewrites are still landing".
//  testDeleteWaitUndoRedo_article: delete the section "1.3 Prices at the Market" from the sidebar, leave the document alone for 15 s while the
//    rewrites land, then Cmd-Z must bring the section back (heading rows in the database, card in the sidebar, no `routing-refused` line);
//    after another 15 s, Cmd-Shift-Z must delete it again.
//  testTypeEarlyThenUndo_article: delete, then type a word BEFORE the rewrites land (the seam below holds them back), so they land AFTER the
//    typing. Cmd-Z presses must then undo the footnote renumber, remove the typed word, and only then restore the section; that last press
//    can only be routed through the editor's fallback comparison (web/*/src/derived-equivalence.ts). The Notes list must be the seeded one
//    again at the end. The test FAILS (never silently skips a step) when no renumber was posted after the typing, and it asserts that no new
//    renumber follows the first Cmd-Z.
//  testDuplicateWaitUndo_article: duplicate a section that holds a footnote and citations, leave the document alone for 15 s, then Cmd-Z must
//    remove the copy.
//
//  THE SEAM: `FF_UI_TESTING_REWRITE_DELAY_SECONDS` (TestMode.uiTestingRewriteDelaySeconds, inert without FF_UI_TESTING=1) stretches the two
//  waits that hold the rewrites back (the footnote wait, 3 s, and the bibliography wait, 1 s). Only testTypeEarlyThenUndo_article sets it.
//
//  VM ONLY: this class runs in the disposable VM through scripts/vmtest/vmtest, never on the host screen. One method:
//  scripts/vmtest/vmtest run --scope "final finalUITests/WriteQueuePhase4bTraceE2ETests/testDeleteWaitUndoRedo_article" --timeout 1500
//
//  HOW MANY PRESSES REMOVE A TYPED WORD is not fixed (see `undoUntilTypedTextIsGone`), so every method that removes typed text presses Cmd-Z
//  until no typed character is left and asserts that the section never returns while any typed character remains and returns on the first
//  press after the last one is gone.
//
//  Version restore is not driven here: the only restore driver in the suite (`restoreFullProject(snapshotNamed:)` plus `saveVersion(named:)`
//  in UnifiedUndoE2ETests+Helpers.swift) is an instance method of another test class.
//

// The synthetic-document generator is deliberately embedded so the whole class runs from this one file in the VM.
// swiftlint:disable file_length
import XCTest

// MARK: - Synthetic documents (ported from POCComplexGenerator; the article only, identical random sequence for it)

struct Phase4bCounts {
    var characters = 0, words = 0, cjkCharacters = 0, paragraphBlocks = 0, headings = 0, blockQuotes = 0
    var headingsByLevel: [Int: Int] = [:]
    var citationGroups = 0, distinctCitationGroups = 0, footnoteMarks = 0, footnoteDefinitions = 0
    var comments = 0, tasks = 0, references = 0

    var reportLine: String {
        let levels = headingsByLevel.keys.sorted().map { "H\($0) x\(headingsByLevel[$0] ?? 0)" }.joined(separator: ", ")
        return "words \(words) (whitespace-separated), citation groups \(citationGroups) (\(distinctCitationGroups) distinct), "
            + "footnote marks \(footnoteMarks) (definitions \(footnoteDefinitions)), "
            + "comment/task/reference marks \(comments + tasks + references) (\(comments) comment, \(tasks) task, \(references) reference), "
            + "headings \(headings) (\(levels)), text blocks in the seed \(paragraphBlocks), block quotes \(blockQuotes), "
            + "CJK characters \(cjkCharacters), characters \(characters)"
    }
}

struct Phase4bDoc {
    let markdown: String
    let cslJSON: String
    let counts: Phase4bCounts
}

// swiftlint:disable cyclomatic_complexity
enum Phase4bGenerator {
    /// A deterministic pseudo-random sequence: the same document every run.
    struct Rng {
        var state: UInt64
        mutating func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) & 0x7FFF_FFFF)
        }
        mutating func pick(_ count: Int) -> Int { next() % count }
    }

    /// Invented filler words (no relation to any real text).
    static let words = [
        "alpine", "harbor", "ledger", "meridian", "cobalt", "thicket", "quorum", "lattice", "ember", "tundra", "parchment", "orchard",
        "lantern", "vessel", "margin", "cadence", "furrow", "gallery", "hinge", "isthmus", "juniper", "kettle", "lagoon", "mosaic",
        "nectar", "outpost", "pillar", "quarry", "ribbon", "summit", "terrace", "umber", "vantage", "willow", "yarrow", "zenith",
        "archive", "bridge", "compass", "dynamo", "estuary", "fabric", "granite", "horizon", "inlet", "journal", "keystone", "ledge",
        "meadow", "narrative", "oracle", "pattern", "register", "signal", "thread", "uplands", "village", "workshop", "account",
        "boundary", "census", "district", "evidence", "foundry", "guild", "heritage", "inquiry", "jurisdiction", "kinship", "lineage",
        "market", "network", "ordinance", "passage", "question", "record", "survey", "tradition", "usage", "variation", "witness", "yield"
    ]

    /// Invented Chinese clauses (Traditional and Simplified mixed, as in a real manuscript), each ending in its own full stop.
    static let cjk = [
        "這個問題需要更仔細的檢視與討論。", "这一发现改变了我们对地方档案的理解。", "他們把帳冊收在潮濕的木箱裡。", "村里的老人仍然記得那條河的名字。",
        "我们需要重新考虑这些数字的来源。", "學者對於這份文件的年代有不同的看法。", "这座桥在雨季之前就已经修好了。", "每一頁邊緣都留下了不同人的筆跡。",
        "调查的结果和最初的假设并不一致。", "市場上的價格每個月都在變化。", "这些记录说明了日常生活的细节。", "她把名單抄了三遍才交出去。"
    ]

    /// "Family, Given" and the year (20 Latin-script authors).
    static let latinAuthors: [(name: String, year: Int)] = [
        ("Alder, Ines", 2011), ("Brandt, Corin", 2019), ("Castell, Maja", 2008), ("Dewitt, Aldo", 2015), ("Ekwall, Sana", 2002),
        ("Farouk, Lena", 2017), ("Garrido, Tomas", 2013), ("Holm, Ravi", 2010), ("Ibarra, Noor", 2020), ("Jovic, Petra", 2006),
        ("Kaplan, Odile", 1999), ("Lindqvist, Emil", 2014), ("Morita, Yuki", 2018), ("Novak, Selma", 2005), ("Okafor, Dara", 2012),
        ("Petrov, Irena", 2016), ("Quist, Leif", 2009), ("Rahman, Zara", 2021), ("Soto, Mateo", 2007), ("Tanaka, Hana", 2003)
    ]

    /// The citekey, then "family|given|title" (15 CJK-script authors).
    static let cjkAuthors: [(key: String, fields: String)] = [
        ("wang2016", "王|小明|地方檔案與日常生活"), ("li2012", "李|雅婷|市場價格的長期變化"), ("chen2018", "陳|志強|河流與村落的歷史"),
        ("zhang2009", "张|伟|账册中的家庭经济"), ("liu2014", "刘|芳|桥梁修建与地方社会"), ("huang2011", "黄|文杰|文件的年代考证"),
        ("zhao2020", "赵|敏|名单与身份的记录"), ("wu2005", "吳|佩珊|筆跡與書寫的社會史"), ("zhou2017", "周|建国|雨季与农业周期"),
        ("xu2008", "徐|静|潮濕之地的紀錄保存"), ("sun2013", "孙|磊|调查方法与假设检验"), ("ma2019", "馬|俊豪|日常生活的細節"),
        ("hu2004", "胡|琳|数字的来源与解释"), ("guo2015", "郭|明華|傳統與變遷"), ("lin2010", "林|家豪|村里的老人與記憶")
    ]

    static func family(_ name: String) -> String { String(name.prefix(while: { $0 != "," })) }

    /// The 35 citekeys (20 Latin-author, 15 CJK-author) in a fixed order.
    static var citekeys: [String] {
        latinAuthors.map { "\(family($0.name).lowercased())\($0.year)" } + cjkAuthors.map { $0.key }
    }

    /// One CSL item per citekey, so the editor formats real citations and the app writes a real bibliography.
    static func cslJSON() -> String {
        var rng = Rng(state: 77)
        var items: [[String: Any]] = []
        for author in latinAuthors {
            let title = (0..<4).map { _ in words[rng.pick(words.count)] }.joined(separator: " ").capitalized
            let isBook = author.year % 2 == 0
            let given = author.name.components(separatedBy: ", ").last ?? ""
            var item: [String: Any] = [
                "id": "\(family(author.name).lowercased())\(author.year)", "type": isBook ? "book" : "article-journal", "title": title,
                "author": [["family": family(author.name), "given": given]], "issued": ["date-parts": [[author.year]]]
            ]
            if isBook { item["publisher"] = "\(words[rng.pick(words.count)].capitalized) Press" } else {
                item["container-title"] = "Journal of \(words[rng.pick(words.count)].capitalized) Studies"
                item["volume"] = String(1 + rng.pick(40))
                item["page"] = "\(10 + rng.pick(200))-\(220 + rng.pick(40))"
            }
            items.append(item)
        }
        for author in cjkAuthors {
            let fields = author.fields.components(separatedBy: "|")
            items.append([
                "id": author.key, "type": "book", "title": fields[2], "author": [["family": fields[0], "given": fields[1]]],
                "issued": ["date-parts": [[Int(author.key.suffix(4)) ?? 0]]], "publisher": "學術出版社"
            ])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "[]" }
        return String(bytes: data, encoding: .utf8) ?? "[]"
    }

    /// How many groups of each shape the article body holds (66 in all; the two footnote definitions that cite make it 68).
    static let formCounts: [(form: Int, count: Int)] = [
        (0, 20), (1, 6), (2, 13), (3, 4), (4, 4), (5, 4), (6, 2), (7, 2), (8, 1), (9, 6), (10, 1), (11, 3)
    ]

    static func citationText(form: Int, slot: Int, rng: inout Rng) -> String {
        let keys = citekeys
        func key(_ offset: Int) -> String { keys[(slot * 13 + offset * 17) % keys.count] }
        let page = 3 + rng.pick(180)
        let pageEnd = page + 2 + rng.pick(9)
        switch form {
        case 0: return "[@\(key(0))]"
        case 1: return "[@\(key(0)); @\(key(1))]"
        case 2: return "[@\(key(0)), {p. \(page)}]"
        case 3: return "[@\(key(0)), {pp. \(page)–\(pageEnd)}]"
        case 4: return "[@\(key(0)), {p. \(page), \(pageEnd)}]"
        case 5: return "[@\(key(0)), {§ \(1 + rng.pick(30))}; @\(key(1)), {p. \(page)}]"
        case 6: return "[@\(key(0)), {§ 六(一)}]"
        case 7: return "[@\(key(0)), {附件二}]"
        case 8: return "[@\(key(0)); @\(key(1)); @\(key(2)), {p. \(page)}]"
        case 9: return "[@\(key(0)), {p. \(page)}; @\(key(1)), {p. \(pageEnd)}]"
        case 10: return "[@\(key(0)), {表\(1 + rng.pick(5))-\(1 + rng.pick(5))}]"
        default: return "[@\(key(0)), {§ \(1 + rng.pick(40))}]"
        }
    }

    /// The comment / task / reference mark at index `index` of 30: 14 comments, 9 tasks, 7 references.
    static func markText(index: Int, rng: inout Rng) -> String {
        let kinds = ["comment", "task", "comment", "reference", "task", "comment", "reference", "comment", "task", "comment"]
        let kind = kinds[index % kinds.count]
        let isLong = [4, 15, 26].contains(index)
        let isMedium = !isLong && index % 4 == 1
        let count = isLong ? 110 + rng.pick(60) : (isMedium ? 32 + rng.pick(14) : 8 + rng.pick(14))
        var text = (0..<count).map { _ in words[rng.pick(words.count)] }.joined(separator: " ")
        if index % 3 == 0 { text += " " + cjk[rng.pick(cjk.count)] }
        if kind == "task" { text = (index % 2 == 0 ? "[ ] " : "[x] ") + text }
        return "<!-- ::\(kind):: \(text) -->"
    }

    static func sentences(wordCount: Int, rng: inout Rng) -> [String] {
        var tokens: [String] = []
        while tokens.count < wordCount {
            let length = min(8 + rng.pick(9), wordCount - tokens.count)
            for position in 0..<length {
                var word = words[rng.pick(words.count)]
                if position == 0 { word = word.capitalized }
                if position == length - 1 { word += "." }
                tokens.append(word)
            }
        }
        return tokens
    }

    struct BodyPlan {
        var citationSlots = 0..<0
        var markSlots = 0..<0
        var footnote: Int?
        var bold = false
        var italic = false
        var cjkClauses = 0
    }

    /// One body paragraph: filler sentences with the planned constructs spread through them.
    static func paragraph(plan: BodyPlan, wordCount: Int, formSchedule: [Int], rng: inout Rng) -> String {
        var tokens = sentences(wordCount: wordCount, rng: &rng)
        var inserts: [String] = []
        if plan.bold { inserts.append("**\(words[rng.pick(words.count)]) \(words[rng.pick(words.count)])**") }
        for _ in 0..<plan.cjkClauses { inserts.append(cjk[rng.pick(cjk.count)]) }
        var marks = Array(plan.markSlots)
        for (offset, slot) in plan.citationSlots.enumerated() {
            var text = citationText(form: formSchedule[slot], slot: slot, rng: &rng)
            if offset == 0, let mark = marks.first {
                text += " " + markText(index: mark, rng: &rng)
                marks.removeFirst()
            }
            inserts.append(text)
        }
        for mark in marks { inserts.append(markText(index: mark, rng: &rng)) }
        if plan.italic { inserts.append("*\(words[rng.pick(words.count)]) \(words[rng.pick(words.count)])*") }
        if let footnote = plan.footnote { inserts.append("[^\(footnote)]") }
        for (index, insert) in inserts.enumerated() {
            let position = min(tokens.count - 1, tokens.count * (index + 1) / (inserts.count + 1))
            tokens[position] += " " + insert
        }
        return tokens.joined(separator: " ")
    }

    /// The article's body: its headings, the 14 anchor paragraphs "Anchor01 line of the fixture document." ... "Anchor14 ...", the body
    /// paragraphs, the block quote and the nine footnote definitions.
    static func articleBody(wordsPerParagraph: Int) -> (blocks: [String], definitions: [String]) {
        var rng = Rng(state: 20_261_009)
        var formSchedule: [Int] = []
        for entry in formCounts { formSchedule += Array(repeating: entry.form, count: entry.count) }
        for index in stride(from: formSchedule.count - 1, to: 0, by: -1) { formSchedule.swapAt(index, rng.pick(index + 1)) }

        let paragraphTotal = 60
        var blocks: [String] = ["# The Quiet Archive: Notes on Ledgers and Lanterns"]
        for number in 1...14 { blocks.append("Anchor\(String(format: "%02d", number)) line of the fixture document.") }
        var paragraphIndex = 0
        func nextParagraph() -> String {
            let index = paragraphIndex
            paragraphIndex += 1
            var plan = BodyPlan()
            plan.citationSlots = (66 * index / paragraphTotal)..<(66 * (index + 1) / paragraphTotal)
            plan.markSlots = (30 * index / paragraphTotal)..<(30 * (index + 1) / paragraphTotal)
            if index >= 4, (index - 4) % 6 == 0, (index - 4) / 6 < 9 { plan.footnote = (index - 4) / 6 + 1 }
            plan.bold = index % 3 == 0
            plan.italic = index % 4 == 1
            plan.cjkClauses = index % 2 == 0 ? (index % 5 == 0 ? 2 : 1) : 0
            let count = wordsPerParagraph + (index * 7) % 21 - 10
            return paragraph(plan: plan, wordCount: count, formSchedule: formSchedule, rng: &rng)
        }
        blocks.append(nextParagraph())
        let sectionTitles = [
            "Ledgers and Their Keepers", "The Village Registers", "Prices at the Market", "Bridges and Boundaries", "Lanterns After Dark"
        ]
        for (sectionIndex, sectionTitle) in sectionTitles.enumerated() {
            blocks.append("## 1.\(sectionIndex + 1) \(sectionTitle)")
            for _ in 0..<3 { blocks.append(nextParagraph()) }
            if sectionIndex == 2 {
                let quote = sentences(wordCount: 55, rng: &rng).joined(separator: " ") + " " + cjk[rng.pick(cjk.count)]
                blocks.append("> " + quote)
            }
            for subIndex in 1...2 {
                let first = words[rng.pick(words.count)].capitalized
                let second = words[rng.pick(words.count)].capitalized
                blocks.append("### 1.\(sectionIndex + 1).\(subIndex) \(first) and \(second)")
                for _ in 0..<4 { blocks.append(nextParagraph()) }
            }
        }
        blocks.append("## 1.6 Conclusion")
        for _ in 0..<4 { blocks.append(nextParagraph()) }

        var definitions: [String] = []
        for number in 1...9 {
            var text = sentences(wordCount: 38 + rng.pick(30), rng: &rng).joined(separator: " ")
            if number == 3 || number == 7 { text += " See " + citationText(form: 2, slot: number * 3, rng: &rng) + "." }
            if number % 2 == 0 { text += " " + cjk[rng.pick(cjk.count)] }
            definitions.append("[^\(number)]: \(text)")
        }
        return (blocks, definitions)
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// Counts everything from the final text of a document.
    static func count(_ markdown: String) -> Phase4bCounts {
        var counts = Phase4bCounts()
        counts.characters = markdown.utf16.count
        counts.words = markdown.split(whereSeparator: { $0.isWhitespace }).count
        counts.cjkCharacters = markdown.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }.count
        counts.paragraphBlocks = markdown.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        for line in markdown.components(separatedBy: "\n") {
            let hashes = line.prefix(while: { $0 == "#" }).count
            if hashes > 0, hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") {
                counts.headings += 1
                counts.headingsByLevel[hashes, default: 0] += 1
            }
            if line.hasPrefix("> ") { counts.blockQuotes += 1 }
        }
        let groups = matches(#"\[[^\]\n]*@[^\]\n]*\]"#, in: markdown)
        counts.citationGroups = groups.count
        counts.distinctCitationGroups = Set(groups).count
        counts.footnoteMarks = matches(#"\[\^\d+\](?!:)"#, in: markdown).count
        counts.footnoteDefinitions = matches(#"(?m)^\[\^\d+\]:"#, in: markdown).count
        let marks = matches(#"<!--\s*::(comment|task|reference)::[\s\S]*?-->"#, in: markdown)
        counts.comments = marks.filter { $0.contains("::comment::") }.count
        counts.tasks = marks.filter { $0.contains("::task::") }.count
        counts.references = marks.filter { $0.contains("::reference::") }.count
        return counts
    }

    static func build(wordsPerParagraph: Int) -> String {
        let body = articleBody(wordsPerParagraph: wordsPerParagraph)
        let blocks = body.blocks + ["# Notes"] + body.definitions
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The reference article's size: the words per paragraph that bring the article closest to this many characters.
    static let targetArticleCharacters = 58_600

    static let tuned: Int = {
        var best = (words: 100, distance: Int.max)
        for candidate in stride(from: 70, through: 200, by: 2) {
            let distance = abs(build(wordsPerParagraph: candidate).utf16.count - targetArticleCharacters)
            if distance < best.distance { best = (candidate, distance) }
        }
        return best.words
    }()

    static func make() -> Phase4bDoc {
        let markdown = build(wordsPerParagraph: tuned)
        return Phase4bDoc(markdown: markdown, cslJSON: cslJSON(), counts: count(markdown))
    }
}
// swiftlint:enable cyclomatic_complexity

// MARK: - Scenario pieces

/// The fixture the tests run on. Only the article (about 58,600 characters) is part of the permanent set; the type keeps the waits that are
/// sized for it in one place.
enum Phase4bSize {
    case article

    var title: String { "ARTICLE (x1)" }

    /// The H2 deleted (with its two H3 children): the middle section of the article.
    var deleteTitle: String { "1.3 Prices at the Market" }

    /// Waits sized for the document.
    var loadTimeout: TimeInterval { 90 }
    var bibliographyTimeout: TimeInterval { 180 }
    var operationTimeout: TimeInterval { 90 }
    /// The run's own wall-clock budget: the runner's hard cap kills the guest and loses every attachment, so waits shrink instead.
    var budgetSeconds: TimeInterval { 15 * 60 }
}

/// Where the caret goes: the paragraph "Anchor05 line of the fixture document." (a one-line plain paragraph near the top of
/// the article, far from the deleted section), from ONE accessibility snapshot, so nothing walks the tree while an operation runs.
struct Phase4bSpot {
    var leaf: CGRect
    var editor: CGRect
}

/// One line of the app's diagnostic log: its UTC stamp (`2026-10-11T13:12:34.567Z`, 24 characters) and the whole line.
struct Phase4bLogLine {
    let stamp: String
    let text: String

    /// The `+<n>ms` of a `[STRUCT-TRACE] t=..ms +<n>ms <label> op=...` line: milliseconds since that operation started (app clock).
    var plusMs: Int? {
        guard let range = text.range(of: #" \+\d+ms "#, options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst(2).dropLast(3))
    }

    var date: Date? { WriteQueuePhase4bTraceE2ETests.stampFormatter.date(from: stamp) }
}

/// The diagnostic log lines at or after a stamp, read from inside the guest across the rotation files (oldest file first).
struct Phase4bLog {
    var lines: [Phase4bLogLine] = []
    var rotated = false

    static func read(since: String) -> Phase4bLog {
        var log = Phase4bLog()
        let urls = UnifiedUndoE2ETests.diagnosticLogCandidateURLs().sorted { (Int($0.pathExtension) ?? 0) > (Int($1.pathExtension) ?? 0) }
        var keeping = false
        var stamp = ""
        for url in urls {
            guard let handle = FileHandle(forReadingAtPath: url.path) else { continue }
            let data = handle.readDataToEndOfFile()
            try? handle.close()
            if url.lastPathComponent != "diagnostic.log" { log.rotated = true }
            let text = String(bytes: data, encoding: .utf8) ?? ""
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let head = Array(raw.utf8.prefix(24))
                if head.count == 24, head[4] == UInt8(ascii: "-"), head[10] == UInt8(ascii: "T") {
                    stamp = String(raw.prefix(24))
                    keeping = stamp >= since
                }
                if keeping { log.lines.append(Phase4bLogLine(stamp: stamp, text: String(raw))) }
            }
        }
        return log
    }

    /// A Swift trace line `[STRUCT-TRACE] t=..ms +..ms <label> op=<id> <step>` (see StructuralUndoController.StructTrace).
    /// `step: "start"` also finds the lines whose step opens with "start (" (the quick undo and redo log `start (quick)`; the editor-first
    /// delete logs `start (editor-first) ...`): before slice 2b the suffix match alone did not see them, which made every "no structural
    /// undo started" check pass without looking at a quick undo (verdict-v1 M22).
    func opLine(label: String, step: String, since: String) -> Phase4bLogLine? {
        lines.first {
            $0.stamp >= since && $0.text.contains("[STRUCT-TRACE] t=") && $0.text.contains(" \(label) op=")
                && ($0.text.hasSuffix(" \(step)") || (step == "start" && Self.opensWithStartBracket($0.text, label: label)))
        }
    }

    /// True when the line's step (the text after ` <label> op=<id> `) begins with "start (".
    private static func opensWithStartBracket(_ text: String, label: String) -> Bool {
        guard let marker = text.range(of: " \(label) op=") else { return false }
        let rest = text[marker.upperBound...]
        guard let space = rest.firstIndex(of: " ") else { return false }
        return rest[rest.index(after: space)...].hasPrefix("start (")
    }

    /// A refusal or failure the controller (or the sidebar action that called it) logged.
    func failureLine(since: String) -> Phase4bLogLine? {
        lines.first {
            $0.stamp >= since && (($0.text.contains("[StructuralUndoController]") && ($0.text.contains(" failed") || $0.text.contains("refus")))
                || $0.text.contains("[ContentView] deleteSectionFromSidebar: op ")
                || $0.text.contains("[ContentView] duplicateSectionFromSidebar: op "))
        }
    }

    /// The editor's own explanation when Cmd-Z was not routed to the structural undo (the JS `routing-refused` probe).
    /// With `direction` ("undo" or "redo") only that direction's refusal counts.
    func routingRefusal(since: String, direction: String? = nil) -> Phase4bLogLine? {
        let needle = direction.map { "[STRUCT-TRACE] routing-refused direction=\($0)" } ?? "[STRUCT-TRACE] routing-refused"
        return lines.first { $0.stamp >= since && $0.text.contains(needle) }
    }
}

struct Phase4bOpOutcome {
    var start: Phase4bLogLine?
    var done: Phase4bLogLine?
    var failure: Phase4bLogLine?
    var timedOut = false

    var description: String {
        let state = done != nil ? "FINISHED" : (failure != nil ? "FAILED OR REFUSED" : (timedOut ? "NOT FINISHED within the wait" : "unknown"))
        return "\(state); start line: \(start?.text ?? "none"); done line: \(done?.text ?? "none"); failure line: \(failure?.text ?? "none")"
    }
}

/// What a structural undo or redo did after its key was pressed (see `waitForStructural`).
struct Phase4bStructuralOutcome {
    var description: String
    /// The app's own `<label> op=<id> performed` line; nil unless the operation finished.
    var performed: Phase4bLogLine?
    var failedOrRefused = false
    /// The editor itself declined to route the key to the structural operation (the JS `routing-refused` line).
    var refusedByEditor = false

    var didPerform: Bool { performed != nil }
}

// MARK: - The test class

/// The permanent regression set for the Phase 4b Cmd-Z fix: Cmd-Z after a section delete or duplicate on the article fixture, both once the
/// automatic rewrites have landed and while they are still landing. See the file header for what each method asserts.
final class WriteQueuePhase4bTraceE2ETests: XCTestCase {
    var app: XCUIApplication!
    var size = Phase4bSize.article
    var methodName = ""
    var doc: Phase4bDoc?
    var startedAt = Date()
    var logSinceStamp = ""
    var summaryLines: [String] = []
    var markReference: Date?
    var evidenceWritten = false
    var markerFirstSeenInDb: Date?
    var markerInDbNow = false

    static let anchorLabel = "Anchor05"
    /// The number in `anchorLabel`: the caret goes to the end of this anchor line, where the typed word lands.
    static let anchorLineNumber = 5

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        // Fast typing into the WKWebView editor: the inline predictive-text feature can swallow keystrokes (e2e-verify skill).
        app.launchArguments += ["-NSAutomaticInlinePredictionEnabled", "NO"]
        // The `[STRUCT-TRACE]` lines reach diagnostic.log only with diagnostics on; the environment variable bypasses the UI-test defaults wipe.
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
        app.launchEnvironment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] = "1"
        try TestFixtureHelper.setupFixture(from: self)
    }

    override func tearDownWithError() throws {
        writeEvidence()
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }
}

// MARK: - Launch and readiness

extension WriteQueuePhase4bTraceE2ETests {
    static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The app's own log stamp format (UTC, milliseconds): comparable as text.
    static func stamp(_ date: Date = Date()) -> String { stampFormatter.string(from: date) }
    static func seconds(_ value: TimeInterval) -> String { String(format: "%.2f", value) }
    static func yesNo(_ flag: Bool) -> String { flag ? "YES" : "NO" }

    func capped(_ timeout: TimeInterval) -> TimeInterval {
        max(5, min(timeout, size.budgetSeconds - Date().timeIntervalSince(startedAt)))
    }

    func begin(method: String, size: Phase4bSize) {
        methodName = method.replacingOccurrences(of: "()", with: "")
        self.size = size
        startedAt = Date()
        let generated = Phase4bGenerator.make()
        doc = generated
        note("METHOD \(methodName) started \(Self.stamp(startedAt)) (UTC)")
        note("FIXTURE \(size.title): \(generated.counts.reportLine)")
    }

    /// The fixture counts, repeated beside every result so a number never stands alone.
    var fixtureTag: String {
        guard let counts = doc?.counts else { return size.title }
        let marks = counts.comments + counts.tasks + counts.references
        return "[\(size.title): \(counts.words) words, \(counts.citationGroups) citation groups, \(counts.footnoteMarks) footnote marks, "
            + "\(marks) comment/task/reference marks, \(counts.headings) headings, \(counts.paragraphBlocks) text blocks]"
    }

    /// Seeds the markdown (and clears `block`, which the shared helper does in the same statement) and reads it back.
    func seedMarkdown(_ markdown: String) {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: markdown)
        guard dbInt("SELECT length(markdown) FROM content;") == markdown.unicodeScalars.count, dbInt("SELECT count(*) FROM block;") == 0 else {
            fail("the seeded markdown does not read back as written (database \(TestFixtureHelper.fixturePath)/content.sqlite)")
            return
        }
    }

    /// Seed, launch, and wait until the document is loaded, its citations resolved, its bibliography generated and the block table steady.
    func launchScenario() {
        guard let doc else { return }
        logSinceStamp = Self.stamp()
        seedMarkdown(doc.markdown)
        let libraryPath = NSTemporaryDirectory() + "ff-p4b-csl-\(UUID().uuidString).json"
        do {
            try doc.cslJSON.write(toFile: libraryPath, atomically: true, encoding: .utf8)
        } catch {
            fail("cannot write the CSL library file \(libraryPath): \(error)")
            return
        }
        app.launchEnvironment["FF_UI_TESTING_ZOTERO_MOCK"] = "1"
        app.launchEnvironment["FF_UI_TESTING_ZOTERO_MOCK_LIBRARY_FILE"] = libraryPath
        let baseArguments = app.launchArguments
        app.launchArguments = baseArguments + ["-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        if !app.editorArea.waitForExistence(timeout: 15) {
            note("no window appeared with -ApplePersistenceIgnoreState YES; relaunching without it")
            app.launchArguments = baseArguments
            app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        }
        guard app.editorArea.waitForExistence(timeout: capped(30)) else { fail("the editor area never appeared after the launch"); return }
        guard app.staticTexts["status-bar-word-count"].waitForValueNot("== '0 words'", timeout: capped(size.loadTimeout)) else {
            fail("the status bar still shows 0 words \(Int(size.loadTimeout)) s after the launch (the seeded document did not load)")
            return
        }
        if !waitForLog(containing: "editor-ready gate satisfied", timeout: capped(90)) {
            guard !readLog().lines.isEmpty else {
                fail("the app wrote nothing to diagnostic.log since \(logSinceStamp): diagnostics logging is not working")
                return
            }
            note("the diagnostic log has no \"editor-ready gate satisfied\" line (it does have other lines); continuing")
        }
        guard locateAnchor(timeout: capped(size.loadTimeout)) != nil else {
            fail("the paragraph \"\(Self.anchorLabel)\" never showed up in the editor's accessibility snapshot")
            return
        }
        let readyAfter = waitForBibliography(timeout: capped(size.bibliographyTimeout))
        let degraded = "NOT generated within \(Int(size.bibliographyTimeout)) s (citations may be unresolved; the fixture is degraded)"
        note("generated bibliography: \(readyAfter.map { "ready after \(Self.seconds($0)) s" } ?? degraded)")
        note("block rows once steady: \(waitForBlocksToSettle()); seconds since the test began: \(Self.seconds(Date().timeIntervalSince(startedAt)))")
    }

    /// Polls the project database until the generated bibliography section exists and has stopped changing.
    func waitForBibliography(timeout: TimeInterval) -> Double? {
        let began = Date()
        var last = ""
        while Date().timeIntervalSince(began) < timeout {
            let text = dbText("SELECT markdownContent FROM section WHERE isBibliography = 1;")
            if text.count > 200, text == last { return Date().timeIntervalSince(began) }
            last = text
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))
        }
        return nil
    }

    func waitForBlocksToSettle() -> Int {
        var last = -1
        var steady = 0
        let deadline = Date(timeIntervalSinceNow: capped(60))
        while Date() < deadline {
            let count = dbInt("SELECT count(*) FROM block;") ?? -1
            steady = count == last ? steady + 1 : 0
            last = count
            if steady >= 3 { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        }
        return last
    }

    // MARK: Finding the paragraph

    static func leafFrame(in snapshot: XCUIElementSnapshot, startingWith prefix: String) -> CGRect? {
        if snapshot.elementType == .staticText {
            if let value = snapshot.value as? String, value.hasPrefix(prefix) { return snapshot.frame }
            if snapshot.label.hasPrefix(prefix) { return snapshot.frame }
        }
        for child in snapshot.children {
            if let frame = leafFrame(in: child, startingWith: prefix) { return frame }
        }
        return nil
    }

    /// The anchor paragraph's frame from one snapshot of the editor; nil unless it is well inside the editor (a click within about a
    /// line of the top or bottom edge is inert: e2e-verify, `placeCaretByClicking`).
    func anchorSpot() -> Phase4bSpot? {
        do {
            let snapshot = try app.editorArea.snapshot()
            guard let leaf = Self.leafFrame(in: snapshot, startingWith: Self.anchorLabel) else { return nil }
            guard leaf.midY >= snapshot.frame.minY + 60, leaf.midY <= snapshot.frame.maxY - 60 else { return nil }
            return Phase4bSpot(leaf: leaf, editor: snapshot.frame)
        } catch {
            print("[P4B-TRACE] editor-area snapshot failed: \(error)")
            return nil
        }
    }

    func requireAnchor() -> Phase4bSpot? {
        let spot = locateAnchor(timeout: capped(90))
        if spot == nil { fail("the paragraph \"\(Self.anchorLabel)\" cannot be found in the editor") }
        return spot
    }

    /// Polls for the anchor paragraph; one Cmd-Up (scroll to the top of the document) after the first miss.
    func locateAnchor(timeout: TimeInterval) -> Phase4bSpot? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var pressedTop = false
        repeat {
            if let spot = anchorSpot() { return spot }
            if !pressedTop {
                pressedTop = true
                app.typeKey(.upArrow, modifierFlags: .command)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        } while Date() < deadline
        return nil
    }
}

// MARK: - Driving the app

extension WriteQueuePhase4bTraceE2ETests {
    /// A coordinate click on the middle of the anchor paragraph (cached frame, no tree walk), then Cmd-Right to the end of its line.
    func placeCaret(_ spot: Phase4bSpot) {
        app.activateAndWaitForForeground()
        let pointX = min(max(spot.leaf.midX, spot.editor.minX + 12), spot.editor.maxX - 12)
        app.editorArea.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: pointX - spot.editor.minX, dy: spot.leaf.midY - spot.editor.minY)).click()
        app.typeKey(.rightArrow, modifierFlags: .command)
    }

    func typeMarker(_ marker: String) {
        mark("typeStart")
        // e2e-lint: allow raw-typetext -- ONE typeText call before the held-back rewrites land; the verifying helper would wait and retype.
        app.typeText(marker)
        mark("typeEnd")
    }

    /// The deliberate holds (`hold`) are the only waits that are not conditions: a run loop spin until a wall-clock moment.
    func holdUntil(_ date: Date) {
        while Date() < date { RunLoop.current.run(until: min(date, Date(timeIntervalSinceNow: 0.05))) }
    }

    @discardableResult
    func mark(_ name: String) -> Date {
        let now = Date()
        let offset = markReference.map { " (+\(Self.seconds(now.timeIntervalSince($0))) s after the reference click)" } ?? ""
        note("MARK \(name) at \(Self.stamp(now))\(offset)")
        return now
    }

    /// Scrolls the Outline sidebar until the card is inside its scroll view (a card can exist in the tree while clipped: e2e-verify).
    /// With `failIfMissing` false a card that cannot be brought into view returns nil without failing the test (used to ASK whether a
    /// section is on the sidebar, e.g. after an undo).
    func bringSidebarCardIntoView(_ title: String, failIfMissing: Bool = true) -> XCUIElement? {
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        guard scroll.waitForExistence(timeout: capped(30)) else {
            if failIfMissing { fail("the outline sidebar's scroll view never appeared") }
            return nil
        }
        let card = scroll.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
        var direction: CGFloat = 1
        for attempt in 1...25 {
            let band = scroll.frame
            guard card.exists else {
                scroll.scroll(byDeltaX: 0, deltaY: -500 * direction)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
                continue
            }
            let frame = card.frame
            if band.insetBy(dx: 0, dy: 20).contains(frame) {
                note("SIDEBAR card \"\(title)\" in view after \(attempt - 1) scroll(s): card y \(frame.minY), view y \(band.minY)-\(band.maxY)")
                return card
            }
            let wanted = max(-1200, min(1200, frame.midY - band.midY))
            scroll.scroll(byDeltaX: 0, deltaY: -wanted * direction)
            app.waitForStableFrame(card)
            // The card should have moved opposite to `wanted`; if it moved the other way the scroll sign is the other one.
            if card.exists, (card.frame.midY - frame.midY) * (-wanted) < 0 { direction = -direction }
        }
        let detail = "the sidebar card \"\(title)\" could not be scrolled into view (scroll view \(scroll.frame), card exists: \(card.exists))"
        if failIfMissing { fail(detail) } else { note(detail) }
        return nil
    }

    /// Right-click the card, choose Delete Section; returns the moment the menu click returned.
    func deleteSection(card: XCUIElement) -> Date { chooseCardMenuItem(card: card, item: "Delete Section", markName: "deleteClick") }

    /// Right-click the card, choose Duplicate Section; returns the moment the menu click returned.
    func duplicateSection(card: XCUIElement) -> Date { chooseCardMenuItem(card: card, item: "Duplicate Section", markName: "duplicateClick") }

    func chooseCardMenuItem(card: XCUIElement, item: String, markName: String) -> Date {
        app.activateAndWaitForForeground()
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.menuItem(titleStartingWith: item).click()
        let clicked = Date()
        markReference = clicked
        note("MARK \(markName) at \(Self.stamp(clicked)) (reference for the offsets below)")
        return clicked
    }
}

// MARK: - Reading the app's log and database

extension WriteQueuePhase4bTraceE2ETests {
    func readLog(since: String? = nil) -> Phase4bLog { Phase4bLog.read(since: since ?? logSinceStamp) }

    func waitForLog(containing needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if readLog().lines.contains(where: { $0.text.contains(needle) }) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    func dbText(_ sql: String) -> String {
        FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dbInt(_ sql: String) -> Int? { Int(dbText(sql)) }

    /// Anchored to the heading marker (`# <title>`), as `Phase4bDelHarness.headingRows` is: a number-prefixed subsection title is also a
    /// substring of the same title in chapters 10 to 12. Only stricter than the plain substring; a title that is a prefix of a longer heading
    /// ("... copy") still counts, as the duplicate checks rely on. (This class only drives the one-chapter article.)
    func headingRows(_ title: String) -> Int {
        dbInt("SELECT count(*) FROM block WHERE blockType = 'heading' AND instr(markdownFragment, '# \(FixtureDatabase.escape(title))') > 0;") ?? -1
    }

    func waitForHeadingRows(_ title: String, equalTo wanted: Int, timeout: TimeInterval) -> Int {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var rows = headingRows(title)
        while rows != wanted, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            rows = headingRows(title)
        }
        return rows
    }

    /// Whether the typed marker is in the block table right now (`markerInDbNow`); notes when it is first seen and when it vanishes again.
    func pollMarker(_ marker: String) {
        let present = (dbInt("SELECT count(*) FROM block WHERE instr(markdownFragment, '\(FixtureDatabase.escape(marker))') > 0;") ?? 0) > 0
        if present, markerFirstSeenInDb == nil {
            markerFirstSeenInDb = Date()
            note("MARKER \(marker) first seen in the block table at \(Self.stamp())")
        }
        if !present, markerInDbNow {
            note("MARKER \(marker) is GONE from the block table again at \(Self.stamp())")
        }
        markerInDbNow = present
    }

    /// Waits for the app's own `<label> op=<id> performed` line (or a logged refusal/failure).
    func waitForOp(label: String, since: Date, timeout: TimeInterval, startRequiredWithin: TimeInterval?) -> Phase4bOpOutcome {
        let sinceStamp = Self.stamp(since)
        let began = Date()
        var outcome = Phase4bOpOutcome()
        repeat {
            let log = readLog(since: sinceStamp)
            outcome.start = log.opLine(label: label, step: "start", since: sinceStamp)
            outcome.done = log.opLine(label: label, step: "performed", since: sinceStamp)
            outcome.failure = log.failureLine(since: sinceStamp)
            if outcome.done != nil || outcome.failure != nil { return outcome }
            if let limit = startRequiredWithin, outcome.start == nil, Date().timeIntervalSince(began) > limit {
                fail("no `[STRUCT-TRACE] ... \(label) op=... start` line within \(Int(limit)) s of the click: the menu click did not reach the app")
                return outcome
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        } while Date().timeIntervalSince(began) < timeout
        outcome.timedOut = true
        return outcome
    }

    /// The same wait for either direction: `label` is the Swift trace label, "undo" (Cmd-Z) or "redo" (Cmd-Shift-Z).
    func waitForStructural(label: String, since stamp: String, timeout: TimeInterval) -> Phase4bStructuralOutcome {
        let began = Date()
        let shouting = label.uppercased()
        var refusalSeenAt: Date?
        repeat {
            let log = readLog(since: stamp)
            if let done = log.opLine(label: label, step: "performed", since: stamp) {
                return Phase4bStructuralOutcome(description: "STRUCTURAL \(shouting) PERFORMED (\(done.text))", performed: done)
            }
            let start = log.opLine(label: label, step: "start", since: stamp)
            let refusal = log.routingRefusal(since: stamp, direction: label)
            if let failure = log.failureLine(since: stamp), start != nil || refusal == nil {
                return Phase4bStructuralOutcome(
                    description: "STRUCTURAL \(shouting) FAILED OR REFUSED BY THE CONTROLLER (\(failure.text)); start line: \(start?.text ?? "none")",
                    failedOrRefused: true)
            }
            if let refusal {
                refusalSeenAt = refusalSeenAt ?? Date()
                // The editor refused to route the key to the structural operation; give a late Swift start a few seconds, then report it.
                if start == nil, Date().timeIntervalSince(refusalSeenAt ?? Date()) > 4 {
                    let keyName = label == "undo" ? "CMD-Z" : "CMD-SHIFT-Z"
                    return Phase4bStructuralOutcome(
                        description: "\(keyName) REFUSED BY THE EDITOR, no structural \(label) started (\(refusal.text))",
                        failedOrRefused: true, refusedByEditor: true)
                }
            }
            if start == nil, refusalSeenAt == nil, Date().timeIntervalSince(began) > 25 {
                return Phase4bStructuralOutcome(
                    description: "NO STRUCTURAL \(shouting) ACTIVITY: the key did nothing the trace can see within 25 s "
                        + "(no \(label) start line, no routing-refused line)",
                    failedOrRefused: true)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        } while Date().timeIntervalSince(began) < timeout
        return Phase4bStructuralOutcome(
            description: "STRUCTURAL \(shouting) STARTED BUT NOT FINISHED within \(Int(timeout)) s", failedOrRefused: true)
    }
}

// MARK: - Final state and evidence

extension WriteQueuePhase4bTraceE2ETests {
    func note(_ line: String) {
        summaryLines.append(line)
        print("[P4B-TRACE] \(methodName) \(line)")
        fflush(stdout)
    }

    func result(_ line: String) { note("RESULT \(fixtureTag) \(line)") }

    func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        note("HARNESS FAILURE: \(message)")
        XCTFail("HARNESS: \(message)", file: file, line: line)
    }

    func attachText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Attaches the run summary and this method's slice of the app's log (`diagnostic.log`). Called from tearDown, so a failure keeps its evidence.
    func writeEvidence() {
        guard !evidenceWritten, !methodName.isEmpty else { return }
        evidenceWritten = true
        let log = readLog()
        let trace = log.lines.filter { $0.text.contains("[STRUCT-TRACE]") }
        note("APP LOG: \(log.lines.count) lines since \(logSinceStamp); rotation files present: \(Self.yesNo(log.rotated)); "
            + "[STRUCT-TRACE] lines: \(trace.count)")
        let excerpt = ["--- [STRUCT-TRACE] lines (first 250 of \(trace.count)) ---"] + trace.prefix(250).map { String($0.text.prefix(700)) }
        attachText("trace-summary-\(methodName).txt", (summaryLines + excerpt).joined(separator: "\n"))
        attachText("diagnostic-\(methodName).log", log.lines.map(\.text).joined(separator: "\n"))
    }
}

// MARK: - Cmd-Z after a section operation, once the automatic rewrites have landed
//
// The undo-outcome checks are real assertions. Every result line carries the fixture counts (`fixtureTag`). Every wait for an operation to
// finish reads the app's own log; the only unconditional waits are the deliberate 15 s holds, during which the Notes, footnote and
// bibliography rewrites land on the document.
// Run one: scripts/vmtest/vmtest run --scope "final finalUITests/WriteQueuePhase4bTraceE2ETests/testDeleteWaitUndoRedo_article" --timeout 1500

extension WriteQueuePhase4bTraceE2ETests {
    /// How long the document is left alone after an operation, so the automatic rewrites that follow it have landed.
    static let quietHoldSeconds: TimeInterval = 15

    // MARK: Delete, hold, Cmd-Z, hold, Cmd-Shift-Z

    func testDeleteWaitUndoRedo_article() { runDeleteWaitUndoRedo(.article, method: #function) }

    // MARK: Duplicate a section that holds a footnote and citations, hold, Cmd-Z

    func testDuplicateWaitUndo_article() { runDuplicateWaitUndo(.article, method: #function) }

    func runDeleteWaitUndoRedo(_ size: Phase4bSize, method: String) {
        begin(method: method, size: size)
        launchScenario()
        let title = size.deleteTitle
        let before = headingRows(title)
        note("heading rows titled \"\(title)\" before the delete: \(before); block rows: \(dbInt("SELECT count(*) FROM block;") ?? -1)")
        guard before >= 1 else { fail("the seeded document has no heading \"\(title)\" in the block table"); return }
        guard let deleted = deleteAndWait(title: title) else { return }
        result("delete of \"\(title)\": its own timeline finished at +\(Self.msText(deleted.performed)) after it started")

        hold(Self.quietHoldSeconds, why: "the automatic rewrites after the delete land; then Cmd-Z")
        guard let undoStamp = pressChord("z", flags: .command, name: "cmdZPressed") else { return }
        result(rewriteQuiet(after: deleted.performed, until: undoStamp))
        let undo = waitForStructural(label: "undo", since: undoStamp, timeout: capped(size.operationTimeout))
        let restored = waitForHeadingRows(title, equalTo: before, timeout: capped(15))
        let cardBack = bringSidebarCardIntoView(title, failIfMissing: false) != nil
        let undoRefusal = readLog(since: undoStamp).routingRefusal(since: undoStamp, direction: "undo")
        result("(c) Cmd-Z \(Int(Self.quietHoldSeconds)) s after the delete: \(undo.description); undo timeline +\(Self.msText(undo.performed)); "
            + "heading rows \"\(title)\": \(before) before, 0 after the delete, \(restored) after Cmd-Z; sidebar card back: \(Self.yesNo(cardBack))")
        assertCheck(undo.didPerform,
                    "Cmd-Z must run the structural undo after the delete and \(Int(Self.quietHoldSeconds)) s of rewrites; saw: \(undo.description)")
        assertCheck(undoRefusal == nil, "no `routing-refused` line after Cmd-Z; saw: \(undoRefusal?.text ?? "none")")
        assertCheck(restored == before, "the heading \"\(title)\" must be back in the block table (\(before) row(s)); found \(restored)")
        assertCheck(cardBack, "the sidebar card \"\(title)\" must be back after Cmd-Z")

        hold(Self.quietHoldSeconds, why: "the automatic rewrites after the undo land; then Cmd-Shift-Z")
        guard let redoStamp = pressChord("z", flags: [.command, .shift], name: "cmdShiftZPressed") else { return }
        let redo = waitForStructural(label: "redo", since: redoStamp, timeout: capped(size.operationTimeout))
        let afterRedo = waitForHeadingRows(title, equalTo: 0, timeout: capped(15))
        result("Cmd-Shift-Z \(Int(Self.quietHoldSeconds)) s after the undo: \(redo.description); redo timeline +\(Self.msText(redo.performed)); "
            + "heading rows \"\(title)\" after the redo: \(afterRedo)")
        assertCheck(redo.didPerform,
                    "Cmd-Shift-Z must run the structural redo after the undo and \(Int(Self.quietHoldSeconds)) s; saw: \(redo.description)")
        assertCheck(afterRedo == 0, "the heading \"\(title)\" must be gone again after the redo; found \(afterRedo) row(s)")
    }

    /// Duplicate the section "1.3 Prices at the Market" (it holds footnote mark 5 and about a dozen citation groups), hold, Cmd-Z: the copy must go.
    func runDuplicateWaitUndo(_ size: Phase4bSize, method: String) {
        begin(method: method, size: size)
        launchScenario()
        let title = size.deleteTitle
        let before = headingRows(title)
        note("heading rows titled \"\(title)\" before the duplicate (the original; the copy's title also contains it): \(before)")
        guard before >= 1 else { fail("the seeded document has no heading \"\(title)\" in the block table"); return }
        guard let card = bringSidebarCardIntoView(title) else { return }
        let click = duplicateSection(card: card)
        let outcome = waitForOp(label: "sectionDuplicate", since: click, timeout: capped(size.operationTimeout), startRequiredWithin: 30)
        note("DUPLICATE OPERATION \(outcome.description)")
        guard let done = outcome.done else { fail("the duplicate of \"\(title)\" did not finish: \(outcome.description)"); return }
        let afterDuplicate = waitForHeadingRows(title, equalTo: before + 1, timeout: capped(15))
        guard afterDuplicate == before + 1 else {
            fail("after the duplicate finished the block table holds \(afterDuplicate) heading row(s) containing \"\(title)\" "
                + "(expected \(before + 1))")
            return
        }
        result("duplicate of \"\(title)\": its own timeline finished at +\(Self.msText(done)); "
            + "heading rows containing the title: \(before) before, \(afterDuplicate) after")

        hold(Self.quietHoldSeconds, why: "the automatic rewrites after the duplicate land; then Cmd-Z")
        guard let undoStamp = pressChord("z", flags: .command, name: "cmdZPressed") else { return }
        let undo = waitForStructural(label: "undo", since: undoStamp, timeout: capped(size.operationTimeout))
        let afterUndo = waitForHeadingRows(title, equalTo: before, timeout: capped(15))
        let refusal = readLog(since: undoStamp).routingRefusal(since: undoStamp, direction: "undo")
        result("(c) Cmd-Z \(Int(Self.quietHoldSeconds)) s after the duplicate: \(undo.description); undo timeline +\(Self.msText(undo.performed)); "
            + "heading rows containing \"\(title)\": \(afterUndo) (the copy is gone when this is \(before))")
        assertCheck(undo.didPerform,
                    "Cmd-Z must run the structural undo \(Int(Self.quietHoldSeconds)) s after the duplicate; saw: \(undo.description)")
        assertCheck(refusal == nil, "no `routing-refused` line after Cmd-Z; saw: \(refusal?.text ?? "none")")
        assertCheck(afterUndo == before,
                    "the copy must be gone after Cmd-Z: expected \(before) heading row(s) containing \"\(title)\", found \(afterUndo)")
    }
}

// MARK: - Cmd-Z pressed while the automatic rewrites are still landing
//
// These are the "Cmd-Z pressed while the automatic rewrites are still landing" checks. The user's rule: nobody should have to wait before
// pressing Cmd-Z after deleting a section; if waiting is needed, something is wrong. `testDeleteWaitUndoRedo_article` leaves the document
// alone for 15 s first, so it never exercised the real app with Cmd-Z pressed EARLY, while the footnote renumber, the Notes rebuild and the
// bibliography rebuild (which lands about 4 s after the delete finished on the article) are still in flight. Before the Phase 4b fix, Cmd-Z was
// refused as early as about 0.4 s after the operation.
//
// The one method, `testDeleteUndoAtOnce_article`, runs the everyday flow: right-click the section in the sidebar, choose Delete Section, press
// Cmd-Z. THE PRESS GOES OUT WITH NO CLICK IN THE TEXT, NO CARET CLICK AND NO ANCHOR LOOKUP (`pressBareChord`): a first version pressed through
// `pressChord`, whose accessibility snapshot of the long article and caret click took 12 to 14 s in the VM, so it only repeated the 15 s test.
// "AT ONCE" MEANS "AS EARLY AS THE TEST TOOL ALLOWS": the tool waits until the app is responsive before it sends a key, so in the VM the key
// reached the editor between 0.5 s and 2.8 s after the delete finished, depending on how busy the VM was (real-app runs, 2026-10-12: +2.84 s
// for presses requested 87 ms and 2008 ms after it; +0.52 s for a press requested at +39 ms, whose key call returned at +676 ms, with no
// timer-driven rewrite line in the log yet; the delete itself takes 0.5 to 0.9 s on the article, and the last automatic rewrite lands about
// 4 s after it finishes). A press before about 0.5 s cannot be made with this tool: that window is covered only by the unit tests of the
// per-chain advance (web/milkdown/src/__tests__/structural-undo-derived-rewrites.test.ts). The old build refused from about 0.4 s after the
// delete, so a press at 0.5 s is already inside the window that used to fail. Between the delete's own `performed` line and the press nothing reads
// the accessibility tree or the block table: the `performed` line is found by following the app's log file every 50 ms (`Phase4bLogFollower`),
// its own timestamp is time zero, and the key goes out at once (the shared function `runDeleteEarlyUndo` takes a hold in seconds after that
// time zero, and this method passes 0: no sleep at all).
// The result line gives the real delay, in ms from the `performed` line to the press (the test process and the app run in the same VM, so the
// press stamp and the log stamps are on one wall clock), and the first line in which the editor reacted. The rewrites run on their real timers
// (the rewrite-delay seam of testTypeEarlyThenUndo_article is NOT set). Everything heavy (the structural-undo wait, the block table, the sidebar)
// is read only AFTER the press.
// Three outcomes are told apart in the result line: (a) the structural undo was performed; (b) the editor refused it (`routing-refused`),
// which is the bug under test; (c) nothing reacted within 5 s (no undo line, no refusal, no routing-equivalence, no `[UnifiedUndo]` keydown or
// menu line): the key did not reach the editor because focus was not in the document, reported as "Cmd-Z NOT DELIVERED to the editor". A press
// that reached the editor without starting an undo or a refusal is reported as its own outcome (d). The assertions are the same as in the 15 s
// test and a method that turns out unreliable (a press that lands on a rewrite boundary) is allowed to fail: nothing is loosened. There is no
// redo part.
// Run it: scripts/vmtest/vmtest run --scope "final finalUITests/WriteQueuePhase4bTraceE2ETests/testDeleteUndoAtOnce_article" --timeout 1500

extension WriteQueuePhase4bTraceE2ETests {
    func testDeleteUndoAtOnce_article() { runDeleteEarlyUndo(.article, holdSeconds: 0, method: #function) }

    /// Right-click Delete Section, then press Cmd-Z `holdSeconds` after the delete's own `performed` line (0: no hold), with no caret click in
    /// between, and assert the section comes back through the structural undo. Nothing between the `performed` line and the press reads the
    /// accessibility tree or the block table; everything heavy is read after the press.
    func runDeleteEarlyUndo(_ size: Phase4bSize, holdSeconds: TimeInterval, method: String) {
        begin(method: method, size: size)
        launchScenario()
        let title = size.deleteTitle
        let before = headingRows(title)
        note("heading rows titled \"\(title)\" before the delete: \(before); block rows: \(dbInt("SELECT count(*) FROM block;") ?? -1)")
        guard before >= 1 else { fail("the seeded document has no heading \"\(title)\" in the block table"); return }
        guard let card = bringSidebarCardIntoView(title) else { return }
        // From here on the app's log file is the only thing read until the press: the follower starts at the end of the file as it is now.
        let follower = Phase4bLogFollower()
        let clickStamp = Self.stamp()
        _ = deleteSection(card: card)
        let outcome = waitForPerformedLine(label: "sectionDelete", since: clickStamp, follower: follower, timeout: capped(size.operationTimeout))
        note("DELETE OPERATION \(outcome.description)")
        guard let performed = outcome.done ?? readLog(since: clickStamp).opLine(label: "sectionDelete", step: "performed", since: clickStamp),
              let performedAt = performed.date
        else { fail("the delete of \"\(title)\" did not finish: \(outcome.description)"); return }
        result("delete of \"\(title)\": its own timeline finished at +\(Self.msText(performed)) after it started; "
            + "its `performed` line is stamped \(performed.stamp) (time zero for the press below)")

        // The deliberate hold: until the performed line's own stamp plus `holdSeconds` on the app's clock (the VM's, shared with this process).
        if holdSeconds > 0 {
            let target = performedAt.addingTimeInterval(holdSeconds)
            let remaining = target.timeIntervalSinceNow
            let state = remaining > 0
                ? "\(Self.seconds(remaining)) s still to wait"
                : "already over by \(Self.seconds(-remaining)) s (the line was found late)"
            note("HOLD until the performed line + \(Int(holdSeconds)) s: \(state)")
            holdUntil(target)
        } else {
            note("NO HOLD: Cmd-Z goes out the moment the performed line was found")
        }
        let press = pressBareChord("z", flags: .command, name: "cmdZPressed")
        let pressMs = Int(press.requested.timeIntervalSince(performedAt) * 1000)
        let returnedMs = Int(press.returned.timeIntervalSince(performedAt) * 1000)

        // After the press only: did anything react at all?
        let reacted = waitForUndoReaction(since: press.stamp, follower: follower, timeout: 5)
        let keySignal = follower.log(since: press.stamp).undoKeySignal(since: press.stamp)
        let keyText = keySignal.map { "(\($0.text.suffix(110))) \(offsetText($0, from: performedAt))" } ?? "none"
        let timerDriven = timerDrivenRewrites(after: performed, until: press.stamp).count
        result("Cmd-Z went out \(pressMs) ms after the delete's performed line (hold \(Int(holdSeconds)) s; "
            + "the key press call returned at +\(returnedMs) ms; no anchor lookup, no caret click; measured on the VM's wall clock, "
            + "which the test process and the app's log stamps share); first editor line about the key: \(keyText); "
            + "timer-driven rewrite lines (footnote deadline, renumber posting, late bibliography update) already in the log at the press: "
            + "\(timerDriven); \(rewriteQuiet(after: performed, until: press.stamp))")
        guard reacted else {
            result("OUTCOME (c) Cmd-Z NOT DELIVERED to the editor: focus was not in the document (within 5 s of the press: no structural undo "
                + "line, no routing-refused line, no routing-equivalence line, no `[UnifiedUndo]` keydown or menu line)")
            assertCheck(false, "Cmd-Z NOT DELIVERED to the editor: focus was not in the document")
            return
        }

        let undo = waitForStructural(label: "undo", since: press.stamp, timeout: capped(size.operationTimeout))
        let restored = waitForHeadingRows(title, equalTo: before, timeout: capped(15))
        let cardBack = bringSidebarCardIntoView(title, failIfMissing: false) != nil
        let log = readLog(since: press.stamp)
        let undoRefusal = log.routingRefusal(since: press.stamp, direction: "undo")
        let equivalence = log.firstLine(since: press.stamp, containing: ["[STRUCT-TRACE] routing-equivalence", "direction=undo"])
        let totalMs = equivalence.flatMap { Self.number("totalMs", in: $0.text) }
        let equivalenceText = equivalence.map {
            "yes (decision=\(Self.word("decision", in: $0.text) ?? "n/a"), result=\(Self.word("result", in: $0.text) ?? "n/a"), "
                + "totalMs \(totalMs.map { "\($0) ms" } ?? "n/a"))"
        } ?? "none (the press needed no fallback comparison)"
        let outcomeText: String
        if undo.didPerform {
            outcomeText = "OUTCOME (a) STRUCTURAL UNDO PERFORMED"
        } else if undoRefusal != nil || undo.refusedByEditor {
            outcomeText = "OUTCOME (b) REFUSED BY THE EDITOR (routing-refused line): this is the bug under test"
        } else {
            outcomeText = "OUTCOME (d) the editor handled the key but no structural undo started and no refusal was logged"
        }
        result("\(outcomeText): \(undo.description); undo timeline +\(Self.msText(undo.performed)); "
            + "heading rows \"\(title)\": \(before) before the delete, \(restored) after Cmd-Z; "
            + "sidebar card back: \(Self.yesNo(cardBack)); routing-equivalence line: \(equivalenceText)")
        assertCheck(undo.didPerform,
                    "Cmd-Z must run the structural undo when pressed \(pressMs) ms after the delete finished (hold \(Int(holdSeconds)) s); "
                        + "saw: \(undo.description)")
        assertCheck(undoRefusal == nil, "no `routing-refused` line after Cmd-Z; saw: \(undoRefusal?.text ?? "none")")
        assertCheck(restored == before, "the heading \"\(title)\" must be back in the block table (\(before) row(s)); found \(restored)")
        assertCheck(cardBack, "the sidebar card \"\(title)\" must be back after Cmd-Z")
    }

    /// Waits for the delete's own `<label> op=<id> performed` line (or a logged refusal/failure) by following the log file every 50 ms: log reads
    /// only, no accessibility tree, no block table. Same meaning as `waitForOp`, which reads the whole log every 0.4 s.
    func waitForPerformedLine(label: String, since stamp: String, follower: Phase4bLogFollower, timeout: TimeInterval) -> Phase4bOpOutcome {
        let began = Date()
        var outcome = Phase4bOpOutcome()
        repeat {
            follower.poll()
            let log = follower.log(since: stamp)
            outcome.start = log.opLine(label: label, step: "start", since: stamp)
            outcome.done = log.opLine(label: label, step: "performed", since: stamp)
            outcome.failure = log.failureLine(since: stamp)
            if outcome.done != nil || outcome.failure != nil { return outcome }
            if outcome.start == nil, Date().timeIntervalSince(began) > 30 {
                fail("no `[STRUCT-TRACE] ... \(label) op=... start` line within 30 s of the click: the menu click did not reach the app")
                return outcome
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        } while Date().timeIntervalSince(began) < timeout
        outcome.timedOut = true
        return outcome
    }

    /// True when, within `timeout` of the press stamped `stamp`, ANY line shows that something reacted to Cmd-Z: a structural undo starting or
    /// finishing, a `routing-refused` or `routing-equivalence` line, a controller failure, or one of the editor's own `[UnifiedUndo]` keydown / menu
    /// lines (`Phase4bLog.undoKeySignal`). False means the key never reached the editor. Follows the log file every 50 ms.
    func waitForUndoReaction(since stamp: String, follower: Phase4bLogFollower, timeout: TimeInterval) -> Bool {
        let began = Date()
        repeat {
            follower.poll()
            let log = follower.log(since: stamp)
            if log.opLine(label: "undo", step: "start", since: stamp) != nil
                || log.opLine(label: "undo", step: "performed", since: stamp) != nil
                || log.routingRefusal(since: stamp, direction: "undo") != nil
                || log.firstLine(since: stamp, containing: ["[STRUCT-TRACE] routing-equivalence", "direction=undo"]) != nil
                || log.failureLine(since: stamp) != nil
                || log.undoKeySignal(since: stamp) != nil { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        } while Date().timeIntervalSince(began) < timeout
        return false
    }
}

/// A key press made by `pressBareChord`: `stamp` is the log stamp taken just before the press (for `since:`), `requested` the moment before the
/// key call and `returned` the moment the call returned (the app may have received the key somewhere in between).
struct Phase4bBarePress {
    let stamp: String
    let requested: Date
    let returned: Date
}

extension Phase4bLog {
    /// The first line at or after `stamp` in which the editor says it received a Cmd-Z: the earliest keydown line (`handleSlashKeydown entered
    /// for Cmd-Z`, written before any routing), the routing line (`keydown direction=undo`), or the menu path's (`menu-path-invocation
    /// direction=undo`). The sources are web/milkdown/src/slash-commands.ts and undo-coordinator.ts.
    func undoKeySignal(since stamp: String) -> Phase4bLogLine? {
        lines.first { line in
            line.stamp >= stamp
                && (line.text.contains("[UnifiedUndo] handleSlashKeydown entered for Cmd-Z")
                    || line.text.contains("[UnifiedUndo] keydown direction=undo")
                    || line.text.contains("[UnifiedUndo] menu-path-invocation direction=undo"))
        }
    }
}

/// Follows the app's `diagnostic.log` from the moment it is created: each `poll()` reads only the bytes written since the last one, so a 50 ms
/// poll stays cheap on a long run (`Phase4bLog.read` re-reads and re-splits every rotation file each time). Reads the log file and nothing else.
final class Phase4bLogFollower {
    private var path: String?
    private var offset: UInt64 = 0
    /// Bytes of a last line the app has not finished writing yet.
    private var unfinished = Data()
    private var stamp = ""
    private(set) var lines: [Phase4bLogLine] = []

    init() {
        path = Self.currentLogPath()
        if let path, let attributes = try? FileManager.default.attributesOfItem(atPath: path), let size = attributes[.size] as? NSNumber {
            offset = size.uint64Value
        }
    }

    private static func currentLogPath() -> String? {
        UnifiedUndoE2ETests.diagnosticLogCandidateURLs()
            .first { $0.lastPathComponent == "diagnostic.log" && FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    /// The lines read so far that are stamped at or after `since`.
    func log(since: String) -> Phase4bLog { Phase4bLog(lines: lines.filter { $0.stamp >= since }) }

    func poll() {
        if path == nil { path = Self.currentLogPath() }
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; unfinished = Data() }  // the file was rotated: the new one starts again at its beginning
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        var bytes = unfinished
        bytes.append(data)
        guard let lastNewline = bytes.lastIndex(of: UInt8(ascii: "\n")) else { unfinished = bytes; return }
        unfinished = Data(bytes[bytes.index(after: lastNewline)...])
        let text = String(bytes: bytes[...lastNewline], encoding: .utf8) ?? ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let head = Array(raw.utf8.prefix(24))
            if head.count == 24, head[4] == UInt8(ascii: "-"), head[10] == UInt8(ascii: "T") { stamp = String(raw.prefix(24)) }
            lines.append(Phase4bLogLine(stamp: stamp, text: String(raw)))
        }
    }
}

// MARK: - Helpers for the Cmd-Z methods

extension WriteQueuePhase4bTraceE2ETests {
    /// A real assertion about an undo or redo outcome: noted in the summary and, when it does not hold, fails the test with the fixture counts
    /// and the reason. The caller records its `result(...)` lines BEFORE asserting, because a failure stops the method.
    func assertCheck(_ holds: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        note("\(holds ? "CHECK PASSED" : "CHECK FAILED"): \(message)")
        if !holds { XCTFail("\(fixtureTag) \(message)", file: file, line: line) }
    }

    /// The `+<n>ms` of a trace line, or "n/a ms" when there is no such line.
    static func msText(_ line: Phase4bLogLine?) -> String { line?.plusMs.map { "\($0) ms" } ?? "n/a ms" }

    /// The number after `key=` in a trace line (`totalMs=2.3` gives 2.3), or nil. A letter before the key does not count (`ms` is not `totalMs`).
    static func number(_ key: String, in text: String) -> Double? {
        guard let range = text.range(of: "(?<![A-Za-z])\(key)=[0-9]+(\\.[0-9]+)?", options: .regularExpression) else { return nil }
        return Double(text[range].dropFirst(key.count + 1))
    }

    /// The word after `key=` in a trace line (`decision=structural` gives "structural"), or nil. A letter before the key does not count.
    static func word(_ key: String, in text: String) -> String? {
        guard let range = text.range(of: "(?<![A-Za-z])\(key)=[A-Za-z]+", options: .regularExpression) else { return nil }
        return String(text[range].dropFirst(key.count + 1))
    }

    /// A deliberate, unconditional wait: the automatic rewrites that follow an operation land during it.
    func hold(_ seconds: TimeInterval, why: String) {
        note("HOLD \(Int(seconds)) s: \(why)")
        holdUntil(Date(timeIntervalSinceNow: seconds))
    }

    /// Delete the section on the sidebar card titled `title` and wait for the app's own `sectionDelete ... performed` line, then for the heading
    /// to be gone from the block table. Nil (already reported as a harness failure) when any of that does not happen.
    func deleteAndWait(title: String) -> (performed: Phase4bLogLine, clickedAt: Date)? {
        guard let card = bringSidebarCardIntoView(title) else { return nil }
        let click = deleteSection(card: card)
        let outcome = waitForOp(label: "sectionDelete", since: click, timeout: capped(size.operationTimeout), startRequiredWithin: 30)
        note("DELETE OPERATION \(outcome.description)")
        guard let done = outcome.done else { fail("the delete of \"\(title)\" did not finish: \(outcome.description)"); return nil }
        let rows = waitForHeadingRows(title, equalTo: 0, timeout: capped(15))
        note("heading rows titled \"\(title)\" after the delete finished: \(rows)")
        guard rows == 0 else { fail("after the delete finished the block table still holds \(rows) heading row(s) \"\(title)\""); return nil }
        return (done, click)
    }

    /// Optionally puts the caret back at the end of the anchor paragraph (so the chord reaches the editor), then presses the chord. Returns the
    /// log stamp taken just before the press; nil when the anchor cannot be found (already reported as a harness failure).
    func pressChord(_ key: String, flags: XCUIElement.KeyModifierFlags, name: String, replaceCaret: Bool = true) -> String? {
        if replaceCaret {
            guard let spot = requireAnchor() else { return nil }
            placeCaret(spot)
        }
        let stamp = Self.stamp()
        app.typeKey(key, modifierFlags: flags)
        mark(name)
        return stamp
    }

    /// The key press of an everyday user right after the sidebar menu: ONLY the stamp and the key, with no anchor lookup (an accessibility snapshot
    /// of the whole article) and no caret click, so the press goes to whatever has focus. `pressChord` stays as it is for the other tests.
    func pressBareChord(_ key: String, flags: XCUIElement.KeyModifierFlags, name: String) -> Phase4bBarePress {
        let requested = Date()
        app.typeKey(key, modifierFlags: flags)
        let returned = Date()
        mark(name)
        return Phase4bBarePress(stamp: Self.stamp(requested), requested: requested, returned: returned)
    }

    /// Block rows whose text contains `needle`.
    func blocks(containing needle: String) -> Int {
        dbInt("SELECT count(*) FROM block WHERE instr(markdownFragment, '\(FixtureDatabase.escape(needle))') > 0;") ?? -1
    }

    /// How long after the delete's `performed` line the LAST automatic rewrite finished before Cmd-Z. A finished rewrite is a
    /// `[bib] [CV:stateChange] bibliographyUpdate→idle` line (Notes and bibliography rebuilds both end there) or a `notes rebuild: finished` line.
    func rewriteQuiet(after performed: Phase4bLogLine, until stamp: String) -> String {
        let finishes = readLog(since: performed.stamp).lines.filter { line in
            line.stamp >= performed.stamp && line.stamp < stamp
                && ((line.text.contains("[CV:stateChange]") && line.text.contains("bibliographyUpdate→idle"))
                    || line.text.contains("notes rebuild: finished"))
        }
        guard let last = finishes.last, let lastDate = last.date, let base = performed.date else {
            return "rewriteQuietAfterMs: NO automatic-rewrite finish line (bibliographyUpdate→idle, notes rebuild finished) "
                + "between the delete's performed line and Cmd-Z"
        }
        let offsets = finishes.compactMap { $0.date.map { Int($0.timeIntervalSince(base) * 1000) } }
        return "rewriteQuietAfterMs = \(Int(lastDate.timeIntervalSince(base) * 1000)) ms after the delete's performed line "
            + "(\(finishes.count) rewrite-finish line(s), at +\(offsets) ms; last: \(last.text.prefix(160)))"
    }
}

// MARK: - Pressing Cmd-Z until the typed text is gone (used by testTypeEarlyThenUndo_article)
//
// HOW MANY PRESSES remove a typed word depends on how its typing split into undo groups: the editor's text history closes a group after a pause
// of about 500 ms between two edits, and in the virtual machine ONE typeText call of a 14 or 15 character word takes about 2 s. A real run
// (testTypeEarlyThenUndo_article) removed `PHASEFOURBEARLY` in two presses, the last character and then the other fourteen; the runs that
// passed earlier had the whole word in one group. Looking for the COMPLETE marker in the block table therefore does not prove "all typed
// text is gone": the marker is absent after the first press that removes ANY character. The test is the text of the anchor lines themselves:
// each must read exactly as seeded again (a fragment of the word fails that), and no block may hold the marker prefix.
//
// The assertion is: the section never returns while any typed character remains (no structural undo starts, no heading row comes back),
// and the section returns on the first press after the last typed character is gone (asserted by the caller on its restoring press).

/// What one Cmd-Z press of `undoUntilTypedTextIsGone` did, as the block table and the app's log showed it.
struct Phase4bUndoPress {
    let number: Int
    let stamp: String
    /// The anchor lines that still read differently from their seeded text after the press (empty: no typed character is left in them).
    let linesStillTyped: [Int]
    /// Blocks anywhere in the document that still hold the marker prefix after the press.
    let blocksWithMarkerPrefix: Int
    /// False when the anchor lines' text did not change within the wait after the press (the press did nothing the block table shows).
    let databaseChanged: Bool
    let headingRows: Int
    /// The `undo ... start` line of a structural undo this press started; nil when it started none.
    let structuralStart: Phase4bLogLine?
    /// The footnote renumber's posting after this press; nil when none was posted.
    let renumber: Phase4bLogLine?

    var textIsGone: Bool { linesStillTyped.isEmpty && blocksWithMarkerPrefix == 0 }
}

extension WriteQueuePhase4bTraceE2ETests {
    /// The start of every marker the Cmd-Z methods type ("PHASEFOURBEARLY").
    static let typedMarkerPrefix = "PHASEFOUR"
    /// The most presses one typed word may need before the test gives up. A word typed in about 2 s makes two or three groups; eight is wide.
    static let maxPressesPerTypedWord = 8
    /// The pause between two presses of the loop.
    static let secondsBetweenPresses: TimeInterval = 1.5

    /// The seeded text of the one-line paragraph "AnchorNN line of the fixture document." (the first 14 paragraphs after the title).
    static func anchorLine(_ number: Int) -> String { "Anchor\(String(format: "%02d", number)) line of the fixture document." }

    /// The block table's text of the one block that starts with anchor line `number` ("" when there is no such block).
    func anchorBlockText(_ number: Int) -> String {
        dbText("SELECT markdownFragment FROM block WHERE instr(markdownFragment, '\(FixtureDatabase.escape(Self.anchorLine(number)))') = 1;")
    }

    func anchorBlockTexts(_ numbers: [Int]) -> [String] { numbers.map { anchorBlockText($0) } }

    /// The anchor lines among `numbers` whose block text (`texts`, in the same order) is not the seeded paragraph.
    func anchorLinesDifferingFromSeed(_ numbers: [Int], texts: [String]) -> [Int] {
        zip(numbers, texts).filter { $0.1 != Self.anchorLine($0.0) }.map { $0.0 }
    }

    /// Harness check before anything is typed: every anchor line reads exactly as seeded, so "reads as seeded again" is a valid test for
    /// "all typed text is gone". False (already reported) when one does not.
    func requireAnchorLinesAsSeeded(_ numbers: [Int]) -> Bool {
        let texts = anchorBlockTexts(numbers)
        let differing = anchorLinesDifferingFromSeed(numbers, texts: texts)
        guard differing.isEmpty else {
            fail("before any typing the anchor line(s) \(differing) do not read as seeded in the block table; block text now: \(texts)")
            return false
        }
        return true
    }

    /// Polls the block table until the text of the anchor lines differs from `before`; false when it is still the same after `timeout`.
    func waitForAnchorTexts(_ numbers: [Int], toDifferFrom before: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if anchorBlockTexts(numbers) != before { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return anchorBlockTexts(numbers) != before
    }

    /// "3 press(es) (Cmd-Z 2 to 4)": how many presses the typed text took.
    func describe(_ presses: [Phase4bUndoPress]) -> String {
        let span = presses.count > 1 ? "Cmd-Z \(presses[0].number) to \(presses[presses.count - 1].number)" : "Cmd-Z \(presses.first?.number ?? 0)"
        return "\(presses.count) press(es) (\(span))"
    }

    /// Presses Cmd-Z until no typed character is left in the anchor lines `numbers` or anywhere else in the document, at most `maxPresses`
    /// times. After each press it waits (up to 10 s) for the block table to show the press's effect, then reads the table, the heading rows and the
    /// app's log, records ONE result line (fixture counts first), and asserts for that press, which was made while typed text remained: no
    /// structural undo started, the section's heading rows are still 0 and no footnote renumber was posted. The next press follows
    /// `secondsBetweenPresses` later. Returns the presses; the last one removed the last typed character. Nil after a reported failure,
    /// including typed text that is still there after `maxPresses`.
    func undoUntilTypedTextIsGone(lines numbers: [Int], title: String, firstNumber: Int, maxPresses: Int) -> [Phase4bUndoPress]? {
        var texts = anchorBlockTexts(numbers)
        guard !anchorLinesDifferingFromSeed(numbers, texts: texts).isEmpty else {
            fail("there is no typed text to undo: the anchor line(s) \(numbers) already read as seeded before the first press")
            return nil
        }
        var presses: [Phase4bUndoPress] = []
        for index in 0..<maxPresses {
            let number = firstNumber + index
            guard let stamp = pressChord("z", flags: .command, name: "cmdZ\(number)Pressed", replaceCaret: false) else { return nil }
            let changed = waitForAnchorTexts(numbers, toDifferFrom: texts, timeout: capped(10))
            texts = anchorBlockTexts(numbers)
            let log = readLog(since: stamp)
            let press = Phase4bUndoPress(
                number: number, stamp: stamp, linesStillTyped: anchorLinesDifferingFromSeed(numbers, texts: texts),
                blocksWithMarkerPrefix: blocks(containing: Self.typedMarkerPrefix), databaseChanged: changed, headingRows: headingRows(title),
                structuralStart: log.opLine(label: "undo", step: "start", since: stamp), renumber: log.renumberPosting(since: stamp))
            presses.append(press)
            result("Cmd-Z \(number): block table changed afterwards: \(Self.yesNo(changed)); typed text still in anchor line(s) "
                + "\(press.linesStillTyped), blocks holding \"\(Self.typedMarkerPrefix)\": \(press.blocksWithMarkerPrefix) "
                + "(all typed text gone: \(Self.yesNo(press.textIsGone))); heading rows \"\(title)\": \(press.headingRows); structural undo "
                + "started: \(Self.yesNo(press.structuralStart != nil)); new renumber posted: \(Self.yesNo(press.renumber != nil))")
            assertCheck(press.structuralStart == nil,
                        "Cmd-Z \(number) was pressed while typed text remained and must not start a structural undo; saw: "
                            + "\(press.structuralStart?.text ?? "none")")
            assertCheck(press.headingRows == 0,
                        "Cmd-Z \(number) was pressed while typed text remained and must not restore the section "
                            + "(\(press.headingRows) heading row(s) \"\(title)\")")
            assertCheck(press.renumber == nil,
                        "no new footnote renumber may be posted after Cmd-Z \(number); saw: \(press.renumber?.text ?? "none")")
            if press.textIsGone { return presses }
            hold(Self.secondsBetweenPresses, why: "typed text is still there after Cmd-Z \(number); the next press undoes the next typing group")
        }
        let last = presses.last
        assertCheck(false, "typed text is still in the document after \(maxPresses) Cmd-Z presses (anchor line(s) still different from the seed: "
            + "\(last?.linesStillTyped ?? []), blocks holding \"\(Self.typedMarkerPrefix)\": \(last?.blocksWithMarkerPrefix ?? -1)); "
            + "the section stayed deleted all along")
        return nil
    }
}

// MARK: - Typing BEFORE the automatic rewrites land, then Cmd-Z until the section returns
//
// The fallback comparison (web/*/src/derived-equivalence.ts): after a section delete the user types a word before the footnote renumber, the
// Notes update and the bibliography update land, those rewrites then land AFTER the typing, and the user presses Cmd-Z until the section comes
// back. Expected shape (the renumber is its own undo step, newest first): Cmd-Z 1 puts the footnote numbers back IN THE EDITOR (proved by the app's
// own `[FN-DIAG] ... refs changed old=<list> new=<list>` line; whether the Notes list in the database is relabelled by that press depends on the
// state and is only RECORDED, see `pressUndoOfTheRenumber`; after the last press, once the section is back, the Notes list must be the seeded one
// again, see `assertNotesAsSeeded`); the next presses remove the typed word (how many depends on how the typing split into undo groups: one in
// a fast run, two or more in the slow virtual machine, where the 15 character word takes about 2 s to type; `undoUntilTypedTextIsGone`
// presses until no typed character is left, at most eight times); and the press after the last typed character is gone restores the section.
// The assertion is: the section never returns while any typed character remains, and returns on the first press after the last one is gone.
// That last press can only route structurally through the fallback (the document is then the saved copy plus the rewrites, not equal to it),
// which the app's `routing-equivalence ... decision=structural result=true` line proves. The number of presses goes beside the fixture counts
// in the result lines.
//
// THE SEAM: `FF_UI_TESTING_REWRITE_DELAY_SECONDS` (TestMode.uiTestingRewriteDelaySeconds, inert without FF_UI_TESTING=1) stretches the two waits
// that hold the rewrites back (FootnoteSyncService.debounceInterval, 3 s, and BibliographySyncService.debounceInterval, 1 s) so the typing lands
// inside them every time. The delete's OWN immediate Notes rebuild (a few hundred ms after `performed`) is not behind either wait and always lands
// before the typing; the anti-vacuity check below therefore looks only for what the two waits hold back.
// Run one: scripts/vmtest/vmtest run --scope "final finalUITests/WriteQueuePhase4bTraceE2ETests/testTypeEarlyThenUndo_article"
//   --timeout 1500 --detach

extension Phase4bLog {
    /// The first line at or after `stamp` whose text contains every needle.
    func firstLine(since stamp: String, containing needles: [String]) -> Phase4bLogLine? {
        lines.first { line in line.stamp >= stamp && needles.allSatisfy { line.text.contains($0) } }
    }

    /// The footnote renumber's own posting: the Notes write ran its `prepare` step (which posts the renumber to the editor).
    func renumberPosting(since stamp: String) -> Phase4bLogLine? {
        firstLine(since: stamp, containing: ["[FN-DIAG]", "system write notesUpdate", "prepareRan=true"])
    }

    /// The editor's note that the fallback comparison ran for a Cmd-Z / Cmd-Shift-Z (exact equality had failed).
    func routingEquivalence(since stamp: String, decision: String) -> Phase4bLogLine? {
        firstLine(since: stamp, containing: ["[STRUCT-TRACE] routing-equivalence", "decision=\(decision)"])
    }

    /// Every `[footnotes] [FN-DIAG] ... refs changed old=<n>[<numbers>] new=<n>[<numbers>]` line at or after `stamp`, oldest first: the footnote
    /// numbers the editor's TEXT carried before and after a change the footnote service noticed.
    func refsChanges(since stamp: String) -> [Phase4bRefsChange] {
        lines.compactMap { line in
            guard line.stamp >= stamp, line.text.contains("[footnotes] [FN-DIAG]"),
                  let lists = Phase4bRefsChange.lists(in: line.text) else { return nil }
            return Phase4bRefsChange(line: line, old: lists.old, new: lists.new)
        }
    }
}

/// One `refs changed` line of the footnote service's diagnostics (see `Phase4bLog.refsChanges`).
struct Phase4bRefsChange {
    let line: Phase4bLogLine
    /// The footnote numbers (labels) of the text before the change, in document order.
    let old: [Int]
    /// The footnote numbers of the text after the change.
    let new: [Int]

    /// The two number lists of `refs changed old=8[1,2,3] new=8[1,2,4]` (an empty list reads `0[]`); nil when the text has no such part.
    static func lists(in text: String) -> (old: [Int], new: [Int])? {
        guard let range = text.range(of: #"refs changed old=\d+\[[0-9,]*\] new=\d+\[[0-9,]*\]"#, options: .regularExpression) else { return nil }
        let lists = text[range].split(separator: "[").dropFirst().map { part in
            part.prefix(while: { $0 != "]" }).split(separator: ",").compactMap { Int($0) }
        }
        guard lists.count == 2 else { return nil }
        return (lists[0], lists[1])
    }

    /// True when the change put higher footnote numbers back: the highest number after is above the highest before, and equals `restoredHighest`.
    func putsNumbersBack(restoredHighest: Int) -> Bool {
        guard let oldHighest = old.max(), let newHighest = new.max() else { return false }
        return newHighest > oldHighest && newHighest == restoredHighest
    }
}

/// What the held-back rewrites did after the typing (each nil when it never showed up in the log).
struct Phase4bHeldBackRewrites {
    var renumber: Phase4bLogLine?
    var bibliography: Phase4bLogLine?
    var notesRebuilt: Phase4bLogLine?
}

extension WriteQueuePhase4bTraceE2ETests {
    /// How long the two rewrite waits are stretched to (the seam). Typing, and everything that must land before it, has to fit inside this.
    static let seamedRewriteDelaySeconds: TimeInterval = 15

    func testTypeEarlyThenUndo_article() { runTypeEarlyThenUndo(.article, method: #function) }

    /// The numbers of the footnote definitions (`[^N]:` blocks) in the block table, ascending.
    func footnoteDefinitionLabels() -> [Int] {
        let text = dbText("SELECT substr(markdownFragment, 1, 12) FROM block WHERE substr(markdownFragment, 1, 2) = '[^';")
        return Phase4bGenerator.matches(#"(?m)^\[\^\d+\]:"#, in: text).compactMap { Int($0.filter(\.isNumber)) }.sorted()
    }

    /// The highest footnote definition number in the block table (-1 when there is none).
    var highestFootnoteLabel: Int { footnoteDefinitionLabels().last ?? -1 }

    /// Polls the block table until a footnote definition above `number` exists (the old, higher numbers are back); false after `timeout`.
    func waitForFootnoteHighest(above number: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if highestFootnoteLabel > number { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return highestFootnoteLabel > number
    }

    /// Lines that only a timer-driven rewrite can produce, between the delete's `performed` line and `stamp`: the footnote deadline firing, the
    /// renumber's posting, and a bibliography update starting more than 2 s after `performed` (the delete's own immediate rewrites are over by then).
    func timerDrivenRewrites(after performed: Phase4bLogLine, until stamp: String) -> [Phase4bLogLine] {
        let begin = performed.date ?? Date()
        return readLog(since: performed.stamp).lines.filter { line in
            guard line.stamp >= performed.stamp, line.stamp < stamp else { return false }
            let text = line.text
            let footnoteTimer = text.contains("[FN-DIAG]")
                && (text.contains("debounce fired") || (text.contains("system write notesUpdate") && text.contains("prepareRan=true")))
            let bibliographyTimer = text.contains("[CV:stateChange] idle→bibliographyUpdate")
                && (line.date?.timeIntervalSince(begin) ?? 0) > 2
            return footnoteTimer || bibliographyTimer
        }
    }

    /// Types the marker at once after the delete (the caret click is the slow part). Returns the log stamp taken right after the typing, or nil
    /// (already reported) when the typing ended after an automatic rewrite had landed, which would make the whole test vacuous.
    func typeBeforeTheRewrites(marker: String, deleted performed: Phase4bLogLine) -> String? {
        guard let spot = requireAnchor() else { return nil }
        placeCaret(spot)
        typeMarker(marker)
        let typedBy = Self.stamp()
        let early = timerDrivenRewrites(after: performed, until: typedBy)
        guard early.isEmpty else {
            fail("typing landed after an automatic rewrite: the test would be vacuous (\(early.count) timer-driven rewrite line(s) before the typing "
                + "ended, first: \(early[0].text.prefix(200)))")
            return nil
        }
        let sinceDelete = Date().timeIntervalSince(performed.date ?? Date())
        result("typing ended \(Self.seconds(sinceDelete)) s after the delete's performed line; no timer-driven rewrite (footnote deadline, "
            + "renumber posting, bibliography update) had landed yet")
        return typedBy
    }

    /// Waits for the held-back rewrites to land AFTER the typing: the renumber's posting, the Notes rebuild that follows it, the bibliography update.
    func waitForHeldBackRewrites(after typedBy: String, marker: String) -> Phase4bHeldBackRewrites {
        var landed = Phase4bHeldBackRewrites()
        let landBy = Date(timeIntervalSinceNow: capped(45 + Self.seamedRewriteDelaySeconds))
        repeat {
            pollMarker(marker)
            let log = readLog(since: typedBy)
            landed.renumber = log.renumberPosting(since: typedBy)
            landed.bibliography = log.firstLine(since: typedBy, containing: ["[CV:stateChange] bibliographyUpdate→idle"])
            landed.notesRebuilt = landed.renumber.flatMap { log.firstLine(since: $0.stamp, containing: ["[FN-DIAG]", "notes rebuild: finished"]) }
            if markerInDbNow, landed.renumber != nil, landed.bibliography != nil, landed.notesRebuilt != nil { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < landBy
        return landed
    }

    func offsetText(_ line: Phase4bLogLine?, from reference: Date) -> String {
        guard let moment = line?.date else { return "never" }
        return "+\(Int(moment.timeIntervalSince(reference) * 1000)) ms after performed"
    }

    /// Waits (polling the app's own log, never the accessibility tree) for the first `refs changed` line at or after `stamp` that puts the
    /// higher footnote numbers back (`Phase4bRefsChange.putsNumbersBack`). When none shows up within `timeout`, returns the first `refs changed`
    /// line after the stamp (nil when there is none either) so the failure message can say what the log did show.
    func waitForRenumberUndoneInTheEditor(
        since stamp: String, restoredHighest: Int, timeout: TimeInterval
    ) -> (proved: Bool, change: Phase4bRefsChange?) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var changes = readLog(since: stamp).refsChanges(since: stamp)
        while !changes.contains(where: { $0.putsNumbersBack(restoredHighest: restoredHighest) }), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            changes = readLog(since: stamp).refsChanges(since: stamp)
        }
        if let proof = changes.first(where: { $0.putsNumbersBack(restoredHighest: restoredHighest) }) { return (true, proof) }
        return (false, changes.first)
    }

    /// Cmd-Z 1 when a renumber was posted: it undoes the renumber (the newest step) IN THE EDITOR, then the renumber must stay undone past the
    /// stretched wait. `restoredHighest` is the highest footnote number the text had before the renumber (the seeded highest).
    ///
    /// What the press does to the Notes definitions in the database is NOT asserted, only recorded: the editor-side undo is proved by the app's
    /// own `refs changed` line, but a stored undo state relabels the Notes list only when the text's numbers match a recorded state, and with the
    /// section that holds a footnote still deleted none does (real-app run, article: the Notes list kept the new numbers). The Notes list is
    /// restored with the section, which `assertNotesAsSeeded` checks after the last press.
    func pressUndoOfTheRenumber(marker: String, title: String, highestAfterRewrites: Int, restoredHighest: Int) {
        guard let firstStamp = pressChord("z", flags: .command, name: "cmdZ1Pressed") else { return }
        // The press undoes the renumber at once in the editor (the app logs `refs changed` a few hundred ms later).
        let undone = waitForRenumberUndoneInTheEditor(since: firstStamp, restoredHighest: restoredHighest, timeout: capped(10))
        // Record whether the Notes definitions were relabelled by the press itself: the stretched footnote wait (15 s) cannot fire within 2 s,
        // so a relabel seen within 2 s did not come from that wait.
        let relabelledAtOnce = waitForFootnoteHighest(above: highestAfterRewrites, timeout: 2)
        let startedEarly = readLog(since: firstStamp).opLine(label: "undo", step: "start", since: firstStamp)
        let afterPress = highestFootnoteLabel
        let change = undone.change
        let changeText = change.map { "old highest \($0.old.max() ?? -1) -> new highest \($0.new.max() ?? -1)" } ?? "none"
        result("Cmd-Z 1: renumber undone in the editor (app log `refs changed` line after the press, highest number above the old numbers "
            + "and back to \(restoredHighest)): \(Self.yesNo(undone.proved)); that line: \(changeText); "
            + "RECORDED, not asserted: Notes list in the database right after the press: highest \(afterPress) "
            + "(\(highestAfterRewrites) before the press), relabelled at once (within 2 s): \(Self.yesNo(relabelledAtOnce)); "
            + "word still in the block table: \(Self.yesNo(blocks(containing: marker) > 0)); heading rows \"\(title)\": "
            + "\(headingRows(title)); structural undo started: \(Self.yesNo(startedEarly != nil))")
        assertCheck(undone.proved, "Cmd-Z 1 must undo the footnote renumber in the editor: the app's log must show a "
            + "`[footnotes] [FN-DIAG] ... refs changed` line after the press whose new numbers have the highest number "
            + "\(restoredHighest) (above the highest of the old numbers); "
            + "first `refs changed` line after the press: \(change?.line.text ?? "none")")
        assertCheck(blocks(containing: marker) > 0, "Cmd-Z 1 must NOT remove the typed word (the renumber is the newest step)")
        assertCheck(headingRows(title) == 0, "Cmd-Z 1 must not restore the section")
        assertCheck(startedEarly == nil, "Cmd-Z 1 must not start a structural undo; saw: \(startedEarly?.text ?? "none")")

        // Hold longer than the stretched wait; the renumber must stay undone (no second renumber). The hold starts within a few seconds of the
        // press, so it covers the FULL stretched wait plus 5 s during which a new renumber could still have been posted.
        hold(Self.seamedRewriteDelaySeconds + 5, why: "longer than the stretched rewrite wait: the renumber must stay undone")
        let afterPressLog = readLog(since: firstStamp)
        let reRenumber = afterPressLog.renumberPosting(since: firstStamp)
        let returnedEarly = afterPressLog.firstLine(since: firstStamp, containing: ["[FN-DIAG]", "perform returned early"])
        let highestHeld = highestFootnoteLabel
        result("after the hold: RECORDED, not asserted: Notes list in the database: highest \(highestHeld) (\(afterPress) right after Cmd-Z 1, "
            + "\(highestAfterRewrites) before it); the footnote service's own line that ended its run without relabelling: "
            + "\(returnedEarly.map { "(\($0.text.suffix(110)))" } ?? "none"); new renumber posting: "
            + "\(Self.yesNo(reRenumber != nil)) \(reRenumber.map { "(\($0.text.prefix(160)))" } ?? "")")
        assertCheck(reRenumber == nil, "no new renumber may be posted after Cmd-Z 1; saw: \(reRenumber?.text ?? "none")")
        assertCheck(blocks(containing: marker) > 0, "the typed word must still be in the block table after the hold")
    }

    /// The press that restores the section (press number `number`, the one after the last typed character is gone). Before the editor-first
    /// delete only the fallback comparison could route it (the document was the saved copy plus the rewrites); since then the saved copy
    /// follows the rewrites, so it routes exactly (no `routing-equivalence` line) or, when the rebase does not apply, through the fallback.
    func pressRestoreThroughTheFallback(number: Int, title: String, headingRowsBefore: Int, footnotesBefore: Int) {
        guard let stamp = pressChord("z", flags: .command, name: "cmdZ\(number)Pressed", replaceCaret: false) else { return }
        let undo = waitForStructural(label: "undo", since: stamp, timeout: capped(size.operationTimeout))
        let restored = waitForHeadingRows(title, equalTo: headingRowsBefore, timeout: capped(15))
        let cardBack = bringSidebarCardIntoView(title, failIfMissing: false) != nil
        let log = readLog(since: stamp)
        let equivalence = log.routingEquivalence(since: stamp, decision: "structural")
        let refusal = log.routingRefusal(since: stamp, direction: "undo")
        let costMs = equivalence.flatMap { Self.number("ms", in: $0.text) }
        let totalMs = equivalence.flatMap { Self.number("totalMs", in: $0.text) }
        result("Cmd-Z \(number): \(undo.description); undo timeline +\(Self.msText(undo.performed)); routing-equivalence line: "
            + "\(equivalence?.text.suffix(110) ?? "none") (fallback comparison cost \(costMs.map { "\($0) ms" } ?? "n/a"), whole routing decision "
            + "\(totalMs.map { "\($0) ms" } ?? "n/a")); heading rows \"\(title)\": \(restored); "
            + "sidebar card back: \(Self.yesNo(cardBack)); footnote definitions after: \(footnoteDefinitionLabels().count) "
            + "(before the delete: \(footnotesBefore))")
        let hint = "the fallback comparison did NOT route this press -- read the `reason=` text of the `routing-equivalence` line (and "
            + "`equivalenceReason=` on the `routing-refused` line) in the attached diagnostic log: it says which part of the two documents differs "
            + "(a position, a node type and a size, never document text) and how the bibliography region was recognised in each"
        assertCheck(undo.didPerform, "Cmd-Z \(number) must run the structural undo; saw: \(undo.description); \(hint)")
        // Phase 7 (board t-d7fd3bf4, 2026-11-11 run): since the editor-first delete the saved copy follows the rewrites (the rebase; see
        // write-queue-plan/phase4b-undo-fix/review-code-merged.md, G3: "exact, or the fallback when the rebase does not apply"), so the
        // press normally routes by exact equality and the fallback comparison never runs: there is NO `routing-equivalence` line, the
        // undo is performed and nothing is refused. Either route is correct; a `routing-equivalence` line, when there is one, must say
        // `result=true`.
        assertCheck(equivalence == nil || equivalence?.text.contains("result=true") == true,
                    "a `routing-equivalence ... decision=structural` line, if the fallback comparison ran, must say result=true; \(hint)")
        assertCheck(refusal == nil, "no `routing-refused` line after the last press; saw: \(refusal?.text ?? "none")")
        assertCheck(restored == headingRowsBefore, "the heading \"\(title)\" must be back (\(headingRowsBefore) row(s)); found \(restored)")
        assertCheck(cardBack, "the sidebar card \"\(title)\" must be back after the last Cmd-Z")
    }

    /// Delete a section, type a word before the automatic rewrites land, let them land, then press Cmd-Z until the section is back: Cmd-Z 1 undoes
    /// the footnote renumber in the editor (and no new renumber may follow; the Notes list in the database is only recorded), the next presses
    /// remove the typed word (as many as the typing's undo groups need, each asserted by `undoUntilTypedTextIsGone`: the section stays deleted, no
    /// structural undo, no new renumber), and the press after the last typed character is gone restores the section (by exact routing, or
    /// through the fallback comparison), after which the Notes list must be the seeded one again.
    func runTypeEarlyThenUndo(_ size: Phase4bSize, method: String) {
        begin(method: method, size: size)
        app.launchEnvironment["FF_UI_TESTING_REWRITE_DELAY_SECONDS"] = String(Int(Self.seamedRewriteDelaySeconds))
        // Phase 7 (board t-d7fd3bf4, diagnosis 2026-11-11): since the editor-first delete the footnote renumber no longer waits for the
        // stretched timers above. The delete's own follow-up work (`resyncAfterEditorFirstDelete`) runs `resyncNow`, which cancels the timer
        // and writes at once, about a second after the click, so the renumber landed while this test was still clicking back into the text
        // and the "typing landed after an automatic rewrite" guard below failed before any Cmd-Z. Holding the first settle for 10 s keeps
        // the follow-up work back until the word has been typed; the guard stays as it is (it catches the follow-up renumber too).
        app.launchEnvironment["FF_UI_TESTING_EF_SETTLE_HOLD_MS"] = "10000"
        launchScenario()
        let title = size.deleteTitle
        let marker = "PHASEFOURBEARLY"
        let before = headingRows(title)
        let labelsBefore = footnoteDefinitionLabels()
        note("heading rows titled \"\(title)\" before the delete: \(before); footnote definitions in the block table: \(labelsBefore.count) "
            + "(highest number \(labelsBefore.last ?? -1)); rewrite waits stretched to \(Int(Self.seamedRewriteDelaySeconds)) s")
        guard before >= 1 else { fail("the seeded document has no heading \"\(title)\" in the block table"); return }
        guard let highestBefore = labelsBefore.last else { fail("the block table holds no footnote definition (`[^N]:`) before the delete"); return }
        guard requireAnchorLinesAsSeeded([Self.anchorLineNumber]) else { return }
        guard let deleted = deleteAndWait(title: title) else { return }
        guard let typedBy = typeBeforeTheRewrites(marker: marker, deleted: deleted.performed) else { return }

        let landed = waitForHeldBackRewrites(after: typedBy, marker: marker)
        let performedAt = deleted.performed.date ?? Date()
        result("held-back rewrites after the typing: renumber posted \(offsetText(landed.renumber, from: performedAt)); bibliography update finished "
            + "\(offsetText(landed.bibliography, from: performedAt)); Notes rebuilt after the renumber "
            + "\(offsetText(landed.notesRebuilt, from: performedAt)); "
            + "word in the block table: \(Self.yesNo(markerInDbNow))")
        assertCheck(markerInDbNow, "the typed word \(marker) must reach the block table before the rewrites are undone")
        assertCheck(landed.bibliography != nil,
                    "the bibliography update must land after the typing (it is what the fallback comparison has to ignore)")
        // This method asserts the sequence "the renumber, the word, the section". A document in which the typing was NOT followed by a renumber
        // would be a different scenario that this method does not test: fail loudly instead of quietly starting with the word's presses.
        guard landed.renumber != nil else {
            fail("no footnote renumber was posted after the typing, so the sequence (renumber undone, word removed, section restored) this "
                + "method asserts cannot happen (the seam should hold the renumber back until after the typing; "
                + "read the [FN-DIAG] lines in the attached log)")
            return
        }
        let highestAfterRewrites = highestFootnoteLabel
        note("footnote definitions: highest number \(highestBefore) before the delete, \(highestAfterRewrites) after the rewrites landed")
        hold(5, why: "everything automatic has landed; then Cmd-Z")

        // Cmd-Z 1 puts the footnote numbers back in the editor; Cmd-Z 2 and the presses after it remove the word, one press per undo group its
        // typing made; the press after the last typed character is gone restores the section.
        pressUndoOfTheRenumber(marker: marker, title: title, highestAfterRewrites: highestAfterRewrites, restoredHighest: highestBefore)
        guard let wordPresses = undoUntilTypedTextIsGone(
            lines: [Self.anchorLineNumber], title: title, firstNumber: 2, maxPresses: Self.maxPressesPerTypedWord)
        else { return }
        let restorePress = (wordPresses.last?.number ?? 1) + 1
        result("the typed word \(marker) (\(marker.count) characters) took \(describe(wordPresses)) to remove, after Cmd-Z 1 undid the renumber; "
            + "the section is restored by the next press, Cmd-Z \(restorePress)")
        hold(3, why: "between the last two Cmd-Z presses")
        pressRestoreThroughTheFallback(number: restorePress, title: title, headingRowsBefore: before, footnotesBefore: labelsBefore.count)
        assertCheck(blocks(containing: marker) == 0, "the typed word must not come back with the section")
        // The section is back, so the Notes list (relabelled by the renumber, and not by Cmd-Z 1) must be the seeded one again. The Notes rebuild
        // after a restore can wait on the footnote deadline, which the seam stretches here.
        assertNotesAsSeeded(before: labelsBefore, timeout: capped(Self.seamedRewriteDelaySeconds + 10))
    }

    /// After the restoring press: the Notes definitions (the `[^N]:` blocks in the block table) are the seeded ones again, as many as were
    /// seeded and with the seeded highest number. Polls up to `timeout` (the Notes rebuild after a restore can wait on the footnote deadline).
    /// The result line is recorded before the assertion, so a failure leaves the evidence.
    func assertNotesAsSeeded(before seeded: [Int], timeout: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var labels = footnoteDefinitionLabels()
        while !(labels.count == seeded.count && labels.last == seeded.last), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            labels = footnoteDefinitionLabels()
        }
        let consistent = labels.count == seeded.count && labels.last == seeded.last
        result("after the section is back: Notes list holds \(labels.count) footnote definition(s), highest number \(labels.last ?? -1) "
            + "(seeded: \(seeded.count), highest \(seeded.last ?? -1)); numbers identical to the seeded ones: \(Self.yesNo(labels == seeded)); "
            + "Notes list consistent with the restored text again: \(Self.yesNo(consistent))")
        assertCheck(labels.last == seeded.last, "once the section is back the highest footnote number in Notes must be the seeded "
            + "\(seeded.last ?? -1) again; found \(labels.last ?? -1) after \(Int(timeout)) s")
        assertCheck(labels.count == seeded.count, "once the section is back Notes must hold the seeded \(seeded.count) footnote definition(s) "
            + "again; found \(labels.count) after \(Int(timeout)) s")
    }
}
