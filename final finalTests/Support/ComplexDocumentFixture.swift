//
//  ComplexDocumentFixture.swift
//  final finalTests
//
//  The synthetic stand-in for a long, complex academic document, shared by the unit tests of the book-length
//  switch plan (plan-book-length-switch.md, step A2): ModeSwitchTextRoundTripTests, BlockParserScalingTests and
//  SectionAnchorInjectionTests. Foundation only, so it can be compiled on its own.
//
//  It is a PORT of the article generator in the saved UI-test scratch class
//  (docs/architecture/write-queue-plan/phase3/e2e-scratch/WriteQueuePhase3bReplayPOC.swift.txt, `POCComplexGenerator`):
//  same random generator, same seeds, same paragraph plan, so the text here is byte for byte the text the VM
//  timing runs seeded (x1 = 58,764 characters, x6 = 349,810, x12 = 699,139). Invented filler text only; no real
//  document is read or copied.
//
//  WHAT ONE CHAPTER HOLDS: a title (H1), 14 `AnchorNN` lines (chapter 1 only), 60 body paragraphs under H2/H3
//  headings, 68 citation groups over 35 keys (page-number locators in braces, several keys, a section locator, a
//  Chinese locator), 30 comment/task/reference marks (three very long), 9 footnote marks with their definitions,
//  a block quote, bold and italic spans and Chinese sentences mixed into the Latin paragraphs. Chapters 2...n
//  repeat the chapter body under new chapter headings; one `# Notes` section with every footnote definition
//  closes the text.
//
//  TWO FORMS OF THE SAME DOCUMENT:
//   - `seedMarkdown`: what a writer's file holds before the app has generated anything: chapters, then the
//     Notes section. This is what the VM runs seed.
//   - `editorMarkdown`: what the editor holds once the app has generated the bibliography, in the order the app
//     itself writes it. Read from the code, not assumed: the first bibliography generation APPENDS its rows at the
//     end of the document (`BibliographySyncService+SystemWrite.swift`, `writeBibliographyRows`, "First-ever
//     generation ... append at the end"), so the order is chapters, `# Notes` with the footnote definitions, then
//     `# Bibliography` (the configured heading) with one paragraph per cited key (35); and
//     `BlockParser.assembleMarkdownForEditor` inserts `BlockParser.bibliographyEndMarker` as its own blank-line
//     separated fragment right after the LAST bibliography block, with no trailing newline. The entry text follows
//     `BibliographySyncService+EntryFormatting.swift` (author, year, title, container or publisher).
//

import Foundation

enum ComplexDocumentFixture {

    // MARK: - The two forms of one document

    struct Counts {
        var characters = 0
        var words = 0
        var cjkCharacters = 0
        var headings = 0
        var citationGroups = 0
        var distinctCitationGroups = 0
        var footnoteMarks = 0
        var footnoteDefinitions = 0
        var annotationMarks = 0
        var bibliographyEntries = 0

        var summary: String {
            "\(characters) characters, \(words) words, \(cjkCharacters) CJK characters, \(headings) headings, "
                + "\(citationGroups) citation groups (\(distinctCitationGroups) distinct), \(footnoteMarks) footnote marks / "
                + "\(footnoteDefinitions) definitions, \(annotationMarks) annotation marks, \(bibliographyEntries) bibliography entries"
        }
    }

    struct Document {
        let chapters: Int
        /// Chapters, then `# Notes` with every footnote definition; ends with one newline. No bibliography yet.
        let seedMarkdown: String
        /// The seed plus the generated bibliography and its end marker, as the app's editor holds it (see the header). No trailing newline.
        let editorMarkdown: String
        /// Counted from `seedMarkdown`, except `bibliographyEntries`.
        let counts: Counts
    }

    static let article = make(chapters: 1)
    static let book6 = make(chapters: 6)
    static let book12 = make(chapters: 12)

    /// The bibliography end marker the app writes (`BlockParser.bibliographyEndMarker`), repeated here so this file stays Foundation-only;
    /// the tests assert that it equals the app's constant.
    static let bibliographyEndMarker = "<!-- ::auto-bibliography-end:: -->"

    static func make(chapters: Int) -> Document {
        let built = build(chapters: chapters, wordsPerParagraph: tuned)
        let entries = bibliographyEntries()
        var counts = count(built.markdown)
        counts.bibliographyEntries = entries.count
        let withoutTrailingNewline = String(built.markdown.dropLast())
        let editorMarkdown = withoutTrailingNewline + "\n\n# Bibliography\n\n" + entries.joined(separator: "\n\n") + "\n\n" + bibliographyEndMarker
        return Document(chapters: chapters, seedMarkdown: built.markdown, editorMarkdown: editorMarkdown, counts: counts)
    }

    // MARK: - The generator (a port; keep in step with POCComplexGenerator)

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

    // The two author tables are plain data ported unchanged from the scratch class; a struct for each would only add noise.
    // swiftlint:disable large_tuple
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
    // swiftlint:enable large_tuple

    /// The 35 citekeys (20 Latin-author, 15 CJK-author) in a fixed order.
    static var citekeys: [String] {
        latinAuthors.map { "\($0.family.lowercased())\($0.year)" } + cjkAuthors.map { "\($0.stem)\($0.year)" }
    }

    /// How many groups of each shape the article holds (66 in all, in the proportions of the reference: single keys, locators with `{p. n}`
    /// braces, several keys, a CJK locator, a section locator).
    static let formCounts: [(form: Int, count: Int)] = [
        (0, 20), (1, 6), (2, 13), (3, 4), (4, 4), (5, 4), (6, 2), (7, 2), (8, 1), (9, 6), (10, 1), (11, 3)
    ]

    static func citationText(form: Int, slot: Int, rng: inout Rng) -> String {
        let keys = citekeys
        func key(_ offset: Int) -> String { keys[(slot * 13 + offset * 17) % keys.count] }
        let pageFrom = 3 + rng.pick(180)
        let pageTo = pageFrom + 2 + rng.pick(9)
        switch form {
        case 0: return "[@\(key(0))]"
        case 1: return "[@\(key(0)); @\(key(1))]"
        case 2: return "[@\(key(0)), {p. \(pageFrom)}]"
        case 3: return "[@\(key(0)), {pp. \(pageFrom)–\(pageTo)}]"
        case 4: return "[@\(key(0)), {p. \(pageFrom), \(pageTo)}]"
        case 5: return "[@\(key(0)), {§ \(1 + rng.pick(30))}; @\(key(1)), {p. \(pageFrom)}]"
        case 6: return "[@\(key(0)), {§ 六(一)}]"
        case 7: return "[@\(key(0)), {附件二}]"
        case 8: return "[@\(key(0)); @\(key(1)); @\(key(2)), {p. \(pageFrom)}]"
        case 9: return "[@\(key(0)), {p. \(pageFrom)}; @\(key(1)), {p. \(pageTo)}]"
        case 10: return "[@\(key(0)), {表\(1 + rng.pick(5))-\(1 + rng.pick(5))}]"
        default: return "[@\(key(0)), {§ \(1 + rng.pick(40))}]"
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
        if let footnote = plan.footnote { inserts.append("[^{{FN\(footnote)}}]") }
        for (index, insert) in inserts.enumerated() {
            let position = min(tokens.count - 1, tokens.count * (index + 1) / (inserts.count + 1))
            tokens[position] += " " + insert
        }
        return tokens.joined(separator: " ")
    }

    // swiftlint:disable large_tuple
    /// The article body of one chapter: its headings, the body paragraphs, the block quote, and the nine footnote definitions
    /// (`{{FNn}}` placeholders are numbered by the caller). The same prose in every chapter (same seed).
    static func chapterBody(
        chapter: Int, chapters: Int, wordsPerParagraph: Int, withAnchors: Bool
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
            return paragraph(plan: plan, wordCount: count, formSchedule: formSchedule, rng: &rng)
        }
        blocks.append(nextParagraph())
        let sectionTitles = [
            "Ledgers and Their Keepers", "The Village Registers", "Prices at the Market", "Bridges and Boundaries", "Lanterns After Dark"
        ]
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
                let firstWord = words[rng.pick(words.count)].capitalized
                let secondWord = words[rng.pick(words.count)].capitalized
                let sub = "### \(chapter).\(sectionIndex + 1).\(subIndex) \(firstWord) and \(secondWord)"
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
            if number == 3 || number == 7 { text += " See " + citationText(form: 2, slot: number * 3, rng: &rng) + "." }
            if number % 2 == 0 { text += " " + cjk[rng.pick(cjk.count)] }
            definitions.append("[^{{FN\(number)}}]: \(text)")
        }
        return (blocks, definitions, headings)
    }
    // swiftlint:enable large_tuple

    static func build(chapters: Int, wordsPerParagraph: Int) -> (markdown: String, headings: [String]) {
        var blocks: [String] = []
        var headings: [String] = []
        var definitions: [String] = []
        for chapter in 1...chapters {
            let body = chapterBody(chapter: chapter, chapters: chapters, wordsPerParagraph: wordsPerParagraph, withAnchors: chapter == 1)
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

    // MARK: - The generated bibliography

    private struct BibliographyEntry {
        let sortName: String
        let year: Int
        let text: String
    }

    /// One entry per cited key, in the order the app writes them (author name, then year) and in the shape
    /// `BibliographySyncService.formatBibliographyEntry` gives: authors, "(year).", the title (italic for a book, quoted for an article),
    /// the container with volume and pages, the publisher. The items come from the same random sequence as the scratch class's CSL library,
    /// so a key means the same source here and in the VM runs.
    static func bibliographyEntries() -> [String] {
        var rng = Rng(state: 77)
        var entries: [BibliographyEntry] = []
        for author in latinAuthors {
            let title = (0..<4).map { _ in words[rng.pick(words.count)] }.joined(separator: " ").capitalized
            let isBook = author.year % 2 == 0
            var parts = ["\(author.family), \(author.given).", "(\(author.year)).", isBook ? "*\(title)*." : "\"\(title).\""]
            if isBook {
                parts.append("\(words[rng.pick(words.count)].capitalized) Press.")
            } else {
                let journal = "Journal of \(words[rng.pick(words.count)].capitalized) Studies"
                let volume = String(1 + rng.pick(40))
                let page = "\(10 + rng.pick(200))-\(220 + rng.pick(40))"
                parts += ["*\(journal)*", volume, ": \(page)."]
            }
            entries.append(BibliographyEntry(sortName: author.family.lowercased(), year: author.year, text: parts.joined(separator: " ")))
        }
        for author in cjkAuthors {
            let parts = ["\(author.family), \(author.given).", "(\(author.year)).", "*\(author.title)*.", "學術出版社."]
            entries.append(BibliographyEntry(sortName: author.family.lowercased(), year: author.year, text: parts.joined(separator: " ")))
        }
        entries.sort { ($0.sortName, $0.year) < ($1.sortName, $1.year) }
        return entries.map(\.text)
    }

    // MARK: - Counting

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// Counts everything from the final text of a document.
    static func count(_ markdown: String) -> Counts {
        var counts = Counts()
        counts.characters = markdown.utf16.count
        counts.words = markdown.split(whereSeparator: { $0.isWhitespace }).count
        counts.cjkCharacters = markdown.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }.count
        for line in markdown.components(separatedBy: "\n") {
            let hashes = line.prefix(while: { $0 == "#" }).count
            if hashes > 0, hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") { counts.headings += 1 }
        }
        let groups = matches(#"\[[^\]\n]*@[^\]\n]*\]"#, in: markdown)
        counts.citationGroups = groups.count
        counts.distinctCitationGroups = Set(groups).count
        counts.footnoteMarks = matches(#"\[\^\d+\](?!:)"#, in: markdown).count
        counts.footnoteDefinitions = matches(#"(?m)^\[\^\d+\]:"#, in: markdown).count
        counts.annotationMarks = matches(#"<!--\s*::(comment|task|reference)::[\s\S]*?-->"#, in: markdown).count
        return counts
    }
}
