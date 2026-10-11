//
//  ComplexDocGenerator.swift
//  final finalTests
//
//  Phase 4a (t-94369a83): a COPY of the synthetic long-document generator from
//  docs/architecture/write-queue-plan/phase3/e2e-scratch/WriteQueuePhase3bReplayPOC.swift.txt
//  (lines 6492-6869: `POCComplexCounts`, `POCComplexDoc`, `POCComplexGenerator`), for unit use. A copy, not an import:
//  the saved scratch file is not compiled and its class no longer builds. Keep the two in step by hand if the generator
//  ever changes (it should not; the documents must stay the same ones every run).
//
//  Used by `MarkdownBlockDiffTests` (round trip on a generated article and a six-chapter book) and by the Phase 4a e2e.
//  Deterministic: the same document every run.
//

// swiftlint:disable cyclomatic_complexity identifier_name large_tuple line_length
// (a verbatim copy of the scratch generator: kept byte-for-byte so the documents never change)

import Foundation

/// What a generated document holds, counted from its final text (so the numbers are the document's, not the generator's intentions).
struct POCComplexCounts {
    var characters = 0
    var words = 0
    var cjkCharacters = 0
    var paragraphBlocks = 0
    var headings = 0
    var headingsByLevel: [Int: Int] = [:]
    var citationGroups = 0
    /// How many of the groups are different strings (a group repeated word for word, key and locator, counts once).
    var distinctCitationGroups = 0
    var citationGroupsWithLocator = 0
    var citationGroupsMultiKey = 0
    var distinctCitekeys = 0
    var footnoteMarks = 0
    var footnoteDefinitions = 0
    var comments = 0
    var tasks = 0
    var references = 0
    var marksOver300Chars = 0
    var longestMarkChars = 0
    var blockQuotes = 0
    var boldSpans = 0
    var italicSpans = 0
    var anchors = 0

    var summary: String {
        let levels = headingsByLevel.keys.sorted().map { "H\($0) x\(headingsByLevel[$0] ?? 0)" }.joined(separator: ", ")
        return "\(characters) characters, \(words) words (whitespace-separated), \(cjkCharacters) CJK characters, \(paragraphBlocks) blocks (text blocks split on blank lines), "
            + "headings \(headings) (\(levels)), citation groups \(citationGroups) (\(distinctCitationGroups) distinct, \(citationGroupsWithLocator) with a locator, \(citationGroupsMultiKey) with several keys), "
            + "distinct citekeys \(distinctCitekeys), footnote marks \(footnoteMarks) / definitions \(footnoteDefinitions), annotation marks \(comments + tasks + references) "
            + "(\(comments) comment, \(tasks) task, \(references) reference; \(marksOver300Chars) over 300 characters, longest \(longestMarkChars)), "
            + "block quotes \(blockQuotes), bold \(boldSpans), italic \(italicSpans), anchor paragraphs \(anchors)"
    }
}

struct POCComplexDoc {
    let id: String
    let title: String
    let chapters: Int
    let markdown: String
    let cslJSON: String
    /// The headings the saved document must hold, in order, the bibliography section left out (the Notes heading last).
    let expectedHeadings: [String]
    let counts: POCComplexCounts
}

enum POCComplexGenerator {
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

    static let latinAuthors: [(family: String, given: String, year: Int)] = [
        ("Alder", "Ines", 2011), ("Brandt", "Corin", 2019), ("Castell", "Maja", 2008), ("Dewitt", "Aldo", 2015), ("Ekwall", "Sana", 2002),
        ("Farouk", "Lena", 2017), ("Garrido", "Tomas", 2013), ("Holm", "Ravi", 2010), ("Ibarra", "Noor", 2020), ("Jovic", "Petra", 2006),
        ("Kaplan", "Odile", 1999), ("Lindqvist", "Emil", 2014), ("Morita", "Yuki", 2018), ("Novak", "Selma", 2005), ("Okafor", "Dara", 2012),
        ("Petrov", "Irena", 2016), ("Quist", "Leif", 2009), ("Rahman", "Zara", 2021), ("Soto", "Mateo", 2007), ("Tanaka", "Hana", 2003)
    ]

    static let cjkAuthors: [(stem: String, family: String, given: String, title: String, year: Int)] = [
        ("wang", "王", "小明", "地方檔案與日常生活", 2016), ("li", "李", "雅婷", "市場價格的長期變化", 2012), ("chen", "陳", "志強", "河流與村落的歷史", 2018),
        ("zhang", "张", "伟", "账册中的家庭经济", 2009), ("liu", "刘", "芳", "桥梁修建与地方社会", 2014), ("huang", "黄", "文杰", "文件的年代考证", 2011),
        ("zhao", "赵", "敏", "名单与身份的记录", 2020), ("wu", "吳", "佩珊", "筆跡與書寫的社會史", 2005), ("zhou", "周", "建国", "雨季与农业周期", 2017),
        ("xu", "徐", "静", "潮濕之地的紀錄保存", 2008), ("sun", "孙", "磊", "调查方法与假设检验", 2013), ("ma", "馬", "俊豪", "日常生活的細節", 2019),
        ("hu", "胡", "琳", "数字的来源与解释", 2004), ("guo", "郭", "明華", "傳統與變遷", 2015), ("lin", "林", "家豪", "村里的老人與記憶", 2010)
    ]

    /// The 35 citekeys (20 Latin-author, 15 CJK-author) in a fixed order.
    static var citekeys: [String] {
        latinAuthors.map { "\($0.family.lowercased())\($0.year)" } + cjkAuthors.map { "\($0.stem)\($0.year)" }
    }

    /// One CSL item per citekey: a mix of Latin and CJK authors and titles, so the editor formats real citations and the app writes a real bibliography.
    static func cslJSON() -> String {
        var rng = Rng(state: 77)
        var items: [[String: Any]] = []
        for author in latinAuthors {
            let title = (0..<4).map { _ in words[rng.pick(words.count)] }.joined(separator: " ").capitalized
            let isBook = author.year % 2 == 0
            var item: [String: Any] = [
                "id": "\(author.family.lowercased())\(author.year)", "type": isBook ? "book" : "article-journal", "title": title,
                "author": [["family": author.family, "given": author.given]], "issued": ["date-parts": [[author.year]]]
            ]
            if isBook { item["publisher"] = "\(words[rng.pick(words.count)].capitalized) Press" } else {
                item["container-title"] = "Journal of \(words[rng.pick(words.count)].capitalized) Studies"
                item["volume"] = String(1 + rng.pick(40))
                item["page"] = "\(10 + rng.pick(200))-\(220 + rng.pick(40))"
            }
            items.append(item)
        }
        for author in cjkAuthors {
            items.append([
                "id": "\(author.stem)\(author.year)", "type": "book", "title": author.title,
                "author": [["family": author.family, "given": author.given]], "issued": ["date-parts": [[author.year]]], "publisher": "學術出版社"
            ])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// How many groups of each shape the article holds (66 in all, in the proportions of the reference: single keys, locators with `{p. n}`
    /// braces, several keys, a CJK locator, a section locator).
    static let formCounts: [(form: Int, count: Int)] = [
        (0, 20), (1, 6), (2, 13), (3, 4), (4, 4), (5, 4), (6, 2), (7, 2), (8, 1), (9, 6), (10, 1), (11, 3)
    ]

    /// `shift` moves every page number, section number and table number in the group (BOOK-6-DISTINCT: a different shift per chapter, so a
    /// repeated chapter cites the same sources at different pages). It is added AFTER every random draw, so the random sequence, and with it
    /// every document built with `shift` 0, is exactly what it was before this parameter existed.
    static func citationText(form: Int, slot: Int, rng: inout Rng, shift: Int = 0) -> String {
        let keys = citekeys
        func key(_ offset: Int) -> String { keys[(slot * 13 + offset * 17) % keys.count] }
        let n = 3 + rng.pick(180) + shift
        let m = n + 2 + rng.pick(9)
        switch form {
        case 0: return "[@\(key(0))]"
        case 1: return "[@\(key(0)); @\(key(1))]"
        case 2: return "[@\(key(0)), {p. \(n)}]"
        case 3: return "[@\(key(0)), {pp. \(n)–\(m)}]"
        case 4: return "[@\(key(0)), {p. \(n), \(m)}]"
        case 5: return "[@\(key(0)), {§ \(1 + rng.pick(30) + shift)}; @\(key(1)), {p. \(n)}]"
        case 6: return "[@\(key(0)), {§ 六(一)}]"
        case 7: return "[@\(key(0)), {附件二}]"
        case 8: return "[@\(key(0)); @\(key(1)); @\(key(2)), {p. \(n)}]"
        case 9: return "[@\(key(0)), {p. \(n)}; @\(key(1)), {p. \(m)}]"
        case 10: return "[@\(key(0)), {表\(1 + rng.pick(5) + shift)-\(1 + rng.pick(5))}]"
        default: return "[@\(key(0)), {§ \(1 + rng.pick(40) + shift)}]"
        }
    }

    /// The comment / task / reference mark at index `index` of 30: 14 comments, 9 tasks, 7 references; most short, seven medium, three very long.
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
    static func paragraph(plan: BodyPlan, wordCount: Int, formSchedule: [Int], rng: inout Rng, shift: Int = 0) -> String {
        var tokens = sentences(wordCount: wordCount, rng: &rng)
        var inserts: [String] = []
        if plan.bold { inserts.append("**\(words[rng.pick(words.count)]) \(words[rng.pick(words.count)])**") }
        for _ in 0..<plan.cjkClauses { inserts.append(cjk[rng.pick(cjk.count)]) }
        var marks = Array(plan.markSlots)
        for (offset, slot) in plan.citationSlots.enumerated() {
            var text = citationText(form: formSchedule[slot], slot: slot, rng: &rng, shift: shift)
            if offset == 0, let mark = marks.first {
                text += " " + markText(index: mark, rng: &rng)
                marks.removeFirst()
            }
            inserts.append(text)
        }
        for mark in marks { inserts.append(markText(index: mark, rng: &rng)) }
        if plan.italic { inserts.append("*\(words[rng.pick(words.count)]) \(words[rng.pick(words.count)])*") }
        if let footnote = plan.footnote { inserts.append("[^{{FN\(footnote)}}]") }
        for (index, insert) in inserts.enumerated() {
            let position = min(tokens.count - 1, tokens.count * (index + 1) / (inserts.count + 1))
            tokens[position] += " " + insert
        }
        return tokens.joined(separator: " ")
    }

    /// The article body of one chapter: its headings, the body paragraphs, the block quote, and the nine footnote definitions
    /// (`{{FNn}}` placeholders are numbered by the caller). The same prose in every chapter (same seed).
    static func chapterBody(
        chapter: Int, chapters: Int, wordsPerParagraph: Int, withAnchors: Bool, locatorShift: Int = 0
    ) -> (blocks: [String], definitions: [String], headings: [String]) {
        var rng = Rng(state: 20_261_009)
        var formSchedule: [Int] = []
        for entry in formCounts { formSchedule += Array(repeating: entry.form, count: entry.count) }
        for index in stride(from: formSchedule.count - 1, to: 0, by: -1) { formSchedule.swapAt(index, rng.pick(index + 1)) }

        let paragraphTotal = 60
        let title = chapters == 1 ? "The Quiet Archive: Notes on Ledgers and Lanterns" : "Chapter \(chapter): The Quiet Archive and Its Ledgers"
        var blocks: [String] = ["# \(title)"]
        var headings = ["# \(title)"]
        if withAnchors {
            for number in 1...14 { blocks.append("Anchor\(String(format: "%02d", number)) line of the fixture document.") }
        }
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
            return paragraph(plan: plan, wordCount: count, formSchedule: formSchedule, rng: &rng, shift: locatorShift)
        }
        blocks.append(nextParagraph())
        let sectionTitles = ["Ledgers and Their Keepers", "The Village Registers", "Prices at the Market", "Bridges and Boundaries", "Lanterns After Dark"]
        for (sectionIndex, sectionTitle) in sectionTitles.enumerated() {
            let section = "## \(chapter).\(sectionIndex + 1) \(sectionTitle)"
            blocks.append(section)
            headings.append(section)
            for _ in 0..<3 { blocks.append(nextParagraph()) }
            if sectionIndex == 2 {
                let quote = sentences(wordCount: 55, rng: &rng).joined(separator: " ") + " " + cjk[rng.pick(cjk.count)]
                blocks.append("> " + quote)
            }
            for subIndex in 1...2 {
                let sub = "### \(chapter).\(sectionIndex + 1).\(subIndex) \(words[rng.pick(words.count)].capitalized) and \(words[rng.pick(words.count)].capitalized)"
                blocks.append(sub)
                headings.append(sub)
                for _ in 0..<4 { blocks.append(nextParagraph()) }
            }
        }
        let closing = "## \(chapter).6 Conclusion"
        blocks.append(closing)
        headings.append(closing)
        for _ in 0..<4 { blocks.append(nextParagraph()) }

        var definitions: [String] = []
        for number in 1...9 {
            var text = sentences(wordCount: 38 + rng.pick(30), rng: &rng).joined(separator: " ")
            if number == 3 || number == 7 { text += " See " + citationText(form: 2, slot: number * 3, rng: &rng, shift: locatorShift) + "." }
            if number % 2 == 0 { text += " " + cjk[rng.pick(cjk.count)] }
            definitions.append("[^{{FN\(number)}}]: \(text)")
        }
        return (blocks, definitions, headings)
    }

    static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// Counts everything from the final text of a document.
    static func count(_ markdown: String, chapters: Int) -> POCComplexCounts {
        var counts = POCComplexCounts()
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
        counts.citationGroupsWithLocator = groups.filter { $0.contains("{") }.count
        counts.citationGroupsMultiKey = groups.filter { $0.components(separatedBy: "@").count > 2 }.count
        var keys = Set<String>()
        for group in groups {
            for key in matches(#"@([A-Za-z0-9_:.\-]+)"#, in: group) { keys.insert(String(key.dropFirst())) }
        }
        counts.distinctCitekeys = keys.count
        counts.footnoteMarks = matches(#"\[\^\d+\](?!:)"#, in: markdown).count
        counts.footnoteDefinitions = matches(#"(?m)^\[\^\d+\]:"#, in: markdown).count
        let marks = matches(#"<!--\s*::(comment|task|reference)::[\s\S]*?-->"#, in: markdown)
        counts.comments = marks.filter { $0.contains("::comment::") }.count
        counts.tasks = marks.filter { $0.contains("::task::") }.count
        counts.references = marks.filter { $0.contains("::reference::") }.count
        counts.marksOver300Chars = marks.filter { $0.utf16.count > 300 }.count
        counts.longestMarkChars = marks.map { $0.utf16.count }.max() ?? 0
        counts.boldSpans = matches(#"\*\*[^*\n]+\*\*"#, in: markdown).count
        counts.italicSpans = matches(#"(?<!\*)\*[^*\n]+\*(?!\*)"#, in: markdown).count
        counts.anchors = matches(#"Anchor\d\d line of the fixture document\."#, in: markdown).count
        return counts
    }

    /// The page-number shift between one chapter and the next in BOOK-6-DISTINCT: more than the 191 values one chapter's page numbers
    /// span (3...193), so no locator group of one chapter equals a locator group of another.
    static let distinctChapterShift = 211

    static func build(chapters: Int, wordsPerParagraph: Int, distinctLocators: Bool = false) -> (markdown: String, headings: [String]) {
        var blocks: [String] = []
        var headings: [String] = []
        var definitions: [String] = []
        for chapter in 1...chapters {
            let body = chapterBody(
                chapter: chapter, chapters: chapters, wordsPerParagraph: wordsPerParagraph, withAnchors: chapter == 1,
                locatorShift: distinctLocators ? (chapter - 1) * distinctChapterShift : 0)
            let offset = (chapter - 1) * 9
            func numbered(_ text: String) -> String {
                var result = text
                for number in stride(from: 9, through: 1, by: -1) {
                    result = result.replacingOccurrences(of: "{{FN\(number)}}", with: String(offset + number))
                }
                return result
            }
            blocks += body.blocks.map(numbered)
            definitions += body.definitions.map(numbered)
            headings += body.headings
        }
        blocks.append("# Notes")
        blocks += definitions
        headings.append("# Notes")
        return (blocks.joined(separator: "\n\n") + "\n", headings)
    }

    /// The reference article's size: the words per paragraph that bring ONE chapter closest to this many characters.
    static let targetArticleCharacters = 58_600

    static func tunedWordsPerParagraph() -> Int {
        var best = (words: 100, distance: Int.max)
        for candidate in stride(from: 70, through: 200, by: 2) {
            let distance = abs(build(chapters: 1, wordsPerParagraph: candidate).markdown.utf16.count - targetArticleCharacters)
            if distance < best.distance { best = (candidate, distance) }
        }
        return best.words
    }

    static let tuned: Int = tunedWordsPerParagraph()

    static func make(id: String, title: String, chapters: Int, distinctLocators: Bool = false) -> POCComplexDoc {
        let built = build(chapters: chapters, wordsPerParagraph: tuned, distinctLocators: distinctLocators)
        return POCComplexDoc(
            id: id, title: title, chapters: chapters, markdown: built.markdown, cslJSON: cslJSON(), expectedHeadings: built.headings,
            counts: count(built.markdown, chapters: chapters))
    }
}

// swiftlint:enable cyclomatic_complexity identifier_name large_tuple line_length
