# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- **If two of your Zotero group libraries have the same name, citations from one of them could come up "not found"** even though the reference was right there — fixed; each library is now looked up separately. If the same citation key genuinely exists in two libraries, you're told it's ambiguous instead of getting a silently-picked one.

## [0.2.129] - 2026-08-30

### Fixed

- **Switching back to a project you'd already had open in this session could show a blank editor, or one with the wrong margins** — fixed.
- **Citations from a shared/group Zotero library could export as plain, inert text in Word and ODT exports instead of real citations**, even though they worked correctly everywhere else in the app — fixed.
- **Exporting a document with footnotes (Word, ODT, PDF, or Print > Print Formatted) could leave an empty "Notes" heading behind with nothing under it**, since your footnotes get moved to the bottom of the export automatically — fixed; the heading is now only removed when it's genuinely empty except for machine-managed footnote content, never when you've added content of your own under it.
- **A footnote's second paragraph could get separated from the footnote and left behind as ordinary body text**, most noticeable on export — fixed.
- **A duplicate Bibliography or Notes card could linger in the outline sidebar indefinitely** once a different card had already taken over as the real one, instead of being cleaned up — fixed; any of your own data on the leftover card (status, tags, word-count goal) now carries over to the card that stays before the duplicate is removed.
- **Switching projects, or opening the app for the first time, could briefly flash unstyled, raw-looking text before the editor's normal formatting appeared** — fixed.
- **The outline sidebar could occasionally show outdated section information after a fast edit**, if an older background refresh landed after a newer one had already finished — fixed.

## [0.2.128] - 2026-08-28

### Added

- **A "Notes" card now appears in the outline sidebar** alongside "Bibliography" whenever your document has footnotes, so you can see and navigate to it like any other section.

### Fixed

- **ODT (OpenDocument) exports looked visually inconsistent with Word and PDF exports, using generic default styling instead of the app's own look** — fonts, heading sizes, and margins in ODT exports now match Word and PDF exports.
- **Opening a document from the Open command (or double-clicking a file) could show it blank or with missing formatting until you clicked into it** — fixed.
- **Restoring a single section from Version History could silently delete your real footnote text**, leaving only an empty "Notes" heading behind with nothing under it — your footnotes are now protected during a restore, the same way your bibliography already was.
- **Switching between projects right after typing could, in rare timing, write your edit to the wrong project's file, or lose it entirely if you closed a project right after editing** — both fixed.
- **The outline sidebar could briefly flash an outdated heading or word count** after a fast edit — fixed.
- **Nested heading relationships (which section sits under which) are now saved to disk instead of only recalculated on the fly** — hardens the outline against reverting to the wrong nesting after certain reorder-then-quit sequences.

## [0.2.127] - 2026-08-26

### Added

- **Export preferences now lets you rename what your bibliography heading is called** — type a new name (or clear the field to go back to the default, "Bibliography") and the open document's heading updates instantly, with no need to save or reopen. Renaming works correctly even after renaming more than once, and typing an old name back in is recognized. If another heading in the document already uses the exact name you're switching to, the rename is refused with an on-screen explanation instead of silently doing nothing.

### Fixed

- **A heading elsewhere in your document that happens to share your bibliography's exact title could be mistaken for the real bibliography, silently swallowing every heading that comes after it into the outline** — fixed, including a follow-up case where a genuine heading appearing later in the same run could still slip through undetected.
- **Renaming your bibliography heading, or the app's own automatic detection of it, could create a second, duplicate bibliography instead of updating the existing one** — the app's internal "this is the bibliography" marker is now always kept accurate, instead of being re-derived from heading text every time.
- **A custom bibliography heading name set in Export preferences wasn't consistently recognized everywhere the app looks for the bibliography** — five of the six places that check for it were still comparing against the default name, or an untrimmed version of your custom one, which could cause mismatches if your custom name had extra whitespace or special characters.
- **Deleting a section, duplicating one, or restoring an old version could in rare cases silently strip your bibliography or Notes section of its special status, if the app's detection didn't recognize the heading during that operation** — fixed with a safety net that restores the correct status afterward.
- **Editing your document's Notes (footnotes) section could occasionally fail to save until you typed something else afterward** — a regeneration of the Notes section could skip its own database sync, so the change wasn't picked up until your next keystroke.

## [0.2.126] - 2026-08-22

### Added

- **Undo (⌘Z) and Redo (⌘⇧Z) now cover restoring a previous version and duplicating or deleting a section from the outline sidebar, not just typing** — before, once you confirmed a restore from Version History, or deleted or duplicated a section, that was final; now ⌘Z undoes it like anything else you did, and steps back through everything — typing included — in the exact order you did it. For example: type a sentence, restore an earlier version, then type another sentence; ⌘Z removes the second sentence, ⌘Z again reverts the restore, and a third ⌘Z removes the first sentence, with ⌘⇧Z replaying all three back in order. If there's genuinely nothing left to undo, you'll now hear a short beep instead of nothing happening.
- **Duplicate and Delete are new options when you right-click a section in the outline sidebar** — Delete removes the section and everything nested under it; Duplicate makes a copy right after it, with "copy" added to the heading. Both can be undone.
- **Dragging a section to reorder it in the outline sidebar can now be undone and redone too, just like typing** — before, dragging a section into a new position made any earlier restore, delete, or duplicate on that document permanently un-undoable, even though your regular typing undo kept working fine. This matters most right after restoring a section from Version History, since a restore often lands the section in the wrong spot and dragging it into place is really the second half of that one action; that combined restore-then-reorder sequence can now be undone as two separate steps, in the right order, including while zoomed into a section. One narrow, deliberate quirk of this and the changes above: if you type something and then delete it back to exactly how the document read right after a restore, delete, duplicate, or reorder, ⌘Z can undo that action one step sooner than you'd count keystrokes for, because nothing is left on screen to tell it otherwise — nothing is ever lost or corrupted, it just happens slightly earlier than expected in this one specific case.
- **Undo now steps back through automatic corrections instead of skipping them** — when the app automatically fixes something right where you were just typing (in the formatted editor, an automatic heading-level fix; in the source editor, any automatic correction landing on your last edit), ⌘Z now undoes that fix first, then undoes your typing, instead of jumping straight past it as if it never happened.

### Fixed

- **Right-clicking a section's word count to set writing goals stopped working** — it was being swallowed by the new right-click Duplicate/Delete Section menu (above), the same way right-clicking the status label already worked around it. Word count now has its own right-click again, side by side with the section menu. Hovering over either the status label or the word count now shows a subtle highlight, making clear those two spots do something different than the rest of the card.
- **Undoing a restore could silently stop working if you reordered the restored section right afterward** — restoring a section from Version History and then dragging it into place could make the restore itself permanently un-undoable, even though it still appeared available in the Undo menu. Undo now correctly reverts the restore in this situation.
- **Undo and Redo could stop working entirely after using Find** — closing the Find bar never returned keyboard focus to the document, so every ⌘Z and ⌘⇧Z after that silently did nothing — not just for the search, but for everything from that point on — until you clicked directly into the document again. Closing Find now hands focus back to the editor automatically.
- **⌘Z no longer goes dead right after switching between the formatted and plain-text editor views** — two separate bugs, both fixed. Switching modes using the keyboard shortcut alone (with no click) never handed keyboard focus to the newly shown editor, so Undo did nothing until you clicked into the document; and even with focus correctly restored, typing immediately after switching modes could have that typing's own undo history silently destroyed by a background correction running at the same time. Both are fixed, in both directions and both ways of switching (⌘/ and the status-bar mode label).
- **Deleting a section could leave an invisible leftover copy of it behind in the app's records** — the section disappeared from the outline as expected, but the underlying record was never actually removed, quietly accumulating forever. Deleting a section now fully removes it.
- **Duplicating a section could silently create a second, permanent extra copy alongside the one you asked for** — with no way to see or remove it. Duplicating a section now creates exactly the one copy you see.
- **The very first citation you add to a brand-new document could be miscounted in the outline sidebar as a regular section instead of recognized as the bibliography** — fixed.
- **In the plain-text editor, ⌘⇧K could silently delete the current line instead of inserting a citation** — a keyboard-shortcut collision meant the two features were fighting over the same shortcut. Inserting a citation with ⌘⇧K no longer deletes anything.

## [0.2.125] - 2026-08-17

### Added

- **Tables can now be deleted in one click** — the floating toolbar that appears over a table in the formatted editor has a new "Delete table" button that removes the whole table at once, leaving the surrounding text untouched. It's shown in red and set apart on its own, after the alignment dropdown, so it's not next to the row/column delete buttons where a stray click could take out an entire table by accident.
- **A new "Markdown Only" option in File ▸ Export Markdown** — exports your document as a single plain markdown file with no images and no extra folder alongside it, for when you just want the text. Code you've written inside a code block, and anything that merely looks like an image inside one, is left exactly as typed.
- **Export preferences now has a "Use custom citation style" option** — load your own citation style (`.csl`) file instead of being locked to the built-in Chicago style. Citations already on screen reformat live, with no reload needed, the moment you turn it on, change the file, or turn it back off.

## [0.2.124] - 2026-08-13

### Fixed

- **Typing could start to feel sluggish, especially in documents with a lot of sections, comments, or footnotes** — every autosave tick was quietly rebuilding every sidebar outline card and every comment/footnote card from scratch, even the ones nothing had changed about, forcing each one to tear down and redo its internal bookkeeping on every keystroke. In one measured case this accounted for roughly half of all the time the app spent doing work while you typed. Cards are now reused in place and only redone when something about them actually changed, so typing stays responsive as a document grows.

## [0.2.123] - 2026-08-11

### Fixed

- **An equation written on a single line as `$$…$$` was squeezed into the end of the paragraph above it instead of standing on its own** — the app couldn't tell a one-line display equation apart from a small inline one, so it rendered it as inline math. One-line display equations now get their own properly spaced block, and equations written inside an indented block keep their indentation instead of losing it.
- **The word and character counts in the status bar could stay stuck at zero after you closed a project and reopened it** — the counts were being remembered from the previous session and never refreshed. They now show the real numbers immediately on reopening.
- **Exporting a document with no citations in it could warn that Zotero wasn't running** — the check that decides whether Zotero is needed was stricter than the one that actually looks for citations, so ordinary text that vaguely resembled a citation triggered a warning for a document that never needed Zotero at all.
- **Triggering an export twice in quick succession could stack up two save dialogs or two warnings on top of each other** — only one export prompt can now be on screen at a time.
- **The Zotero connection indicator could keep showing an out-of-date state after an export** — a successful or failed export now updates it, instead of leaving whatever it last showed.
- **A long export error message was cut off mid-word** — error text is now trimmed at a sentence or word boundary so it still reads as a sentence.

## [0.2.122] - 2026-08-10

### Changed

- **A citation written without square brackets (for example, "Smith argues that...") is no longer recognized as a citation, in any export format or in the reference list built into the document itself** — it used to work by accident in PDF exports only, while every other format silently treated it as plain text. Rather than make that inconsistent, easy-to-get-wrong style work everywhere, it's been dropped everywhere in favor of one clear rule: a citation only counts if it's inside square brackets. Two bracketed styles that used to work in PDF only by accident — a citation with "see" written before it, and one that hides the author's name — now work consistently everywhere too.

### Fixed

- **Text typed right after your bibliography could disappear, then reappear in the wrong place** — three related bugs, all fixed the same way. Text after the bibliography could vanish outright when the document was saved; once that was fixed, it would export to PDF as if it came before the bibliography rather than after; and once that was fixed too, it would jump back to before the bibliography every time the bibliography regenerated, which happens whenever a citation anywhere in the document is added or changed. The app now always knows exactly where the bibliography ends, and keeps that correct through saving, reloading, switching between the formatted and source editors, exporting, and bibliography regeneration. Fixing this also caught two related bugs: a heading elsewhere in the document that happened to share the bibliography's own title could get mistaken for it, and your cursor could occasionally jump backward out of text you were actively typing just after the bibliography.
- **In the source editor, certain keyboard shortcuts used right next to the invisible marker that keeps track of where your bibliography ends could delete, move, or duplicate it, corrupting the document** — Delete, Backspace, and the shortcuts for moving, copying, or deleting a whole line. The formatted editor already guarded against this; the source editor now does too. A document with two such markers stacked on the same line — which could previously scramble the second one beyond repair — is now also read correctly.
- **PDF exports of a document with citations had no heading above the reference list at the end, and one broken or mistyped citation could silently delete the entire list instead of leaving just that one unresolved** — both are fixed: the reference list now gets a heading, matching Word and OpenDocument exports, and a single bad citation no longer takes the rest of the bibliography down with it.
- **A math equation containing an ampersand, hash, or percent sign (like `$x & y$`) could crash a PDF export outright, or silently cut off the rest of that line** — these characters have special meaning in the export process and weren't being handled inside equations. They're now recognized and escaped correctly, while equations that intentionally use them — some multi-line formulas use `&` for alignment — are left alone.
- **Citing the same reference under two different capitalizations of its citation key could split it into "found" and "not found" halves** — in the bibliography sidebar, and in Word, OpenDocument, and PDF exports, the miscased citation could be dropped or attributed to the wrong reference entirely. Citation keys are now matched without regard to case everywhere, unless doing so would make two different references ambiguous, in which case the mismatch is still reported rather than guessed at.
- **A web address ending in a closing parenthesis or square bracket had that character stripped from the link** — both when the app auto-linked a URL as you typed it, and when exporting to PDF, the last character was treated as ordinary sentence punctuation and cut from the link's destination, breaking links to pages whose address legitimately ends that way (for example, a Wikipedia article with a parenthetical in its title). Both places now check whether the character is actually closing a bracket that's part of the address itself before stripping it.
- **Exporting to Word or OpenDocument with citations no longer crashes when Zotero can't be reached** — it used to fail with a cryptic error (or produce a document with broken citations) if Zotero wasn't running, didn't have Better BibTeX installed, or couldn't be reached in time. Now you get a clear message telling you what's wrong and to try again once it's fixed. This message — and PDF export's own "Continue Export anyway?" warning about citations that can't be resolved — now appears as soon as you choose Export, before you're asked where to save the file, instead of only afterward once you'd already picked a save location.
- **Archive and gallery names no longer appear in citations for archival or artwork references** — Zotero can sometimes store a raw web address in this field instead of the archive's name (a known quirk of its Extra field), and that address used to print exactly as stored. There's no reliable way to tell a genuine archive name from a leaked web address, so this field is now left out of every such citation — including ones where it held a real archive name, not just the broken ones.
- **A long citation link (like a DOI or a tracking-parameter-heavy URL) could run off the edge of the page when exporting to PDF** — LaTeX only knows how to break a URL onto a new line at certain punctuation, and a long link with none of that (no slashes or hyphens) had nowhere to break, so it printed past the page margin instead of wrapping. Long links now wrap properly, and the fix also covers plain web addresses typed directly into your document's text, which had the same problem.

## [0.2.121] - 2026-08-07

### Added

- **Version History now opens with ⌘⌥V** — the shortcut was documented in the README but had never been attached to the menu item.

### Changed

- **Closing the Getting Started guide no longer asks whether you want to save your changes** — the guide is a playground, not a document you own, and the prompt implied work was about to be lost. Instead, the first time you edit it in a session, a brief message tells you that changes to the guide aren't saved.

### Fixed

- **Pasting malformed display math (`$$…$$`) could swallow everything after it into one broken block** — worse, the app's own equations became malformed simply by being saved and reopened, because the opening `$$` was written on the same line as the formula and then misread as something else when the document was parsed. Equations now save in a form that survives a round trip, documents already damaged this way repair themselves on open, and pasted math that arrives malformed is separated from the text that follows it.
- **A section-break marker, mode switch, or bibliography refresh happening mid-save could duplicate a paragraph** — a save already in flight when the document was rewritten wholesale (switching between the formatted and source editors, zooming into a section, or a background bibliography or notes rebuild) could land its stale text at the end of the document as a new, duplicate paragraph. Saves in flight are now abandoned when the document changes underneath them.
- **Deleting a paragraph that contained only a citation could scramble a nearby empty paragraph's identity** — the deleted paragraph's internal identity could be handed to an unrelated blank paragraph, so metadata attached to one could end up on the other.
- **In the source editor opened after the app had warmed up, pasting an oversized table silently dropped the extra rows** — the warning that the table had been truncated never appeared, though it did in a freshly opened editor. The warning now shows in both cases.
- **A heading like "3. Introduction" showed up in the outline sidebar as just "Introduction"** — the leading number was mistaken for an ordered-list marker and stripped. Headings now appear in the sidebar exactly as written.
- **Text inside code blocks and block quotes was indexed for search with leading numbers and bullets stripped off** — searching for a line like `1. install` inside a code block could miss it. What's shown on screen was never affected; the saved search text now matches the literal text.
- **Right-clicking in one window could be swallowed by the status badge in another** — the badge listened for right-clicks across the whole app rather than only in its own window, so a right-click or Control-click meant for a different window did nothing.
- **Citing an offline reference could fail when the citation key's capitalization didn't match** — offline lookup now ignores case, the way online lookup already did.
- **A failing Zotero export reported "Network error" even when the network was fine** — an unexpected response from Zotero was misreported as a connection problem. The message now reflects what actually went wrong.
- **Switching between the formatted and source editors left the previous editor's machinery running** — memory and background listeners accumulated with every switch instead of being released.

## [0.2.120] - 2026-08-05

### Fixed

- **Entering Focus Mode (⌘⇧F) paused for about half a second before the side panels moved** — the delay came from two hard-coded waits meant to outlast a system animation, but they didn't reliably match how long that animation actually took. Focus Mode now enters and exits instantly.
- **Pressing Esc while the window was still animating into or out of full screen could leave it stuck in full screen with Focus Mode turned off** — macOS silently discards a request to exit full screen if it arrives while the previous transition is still in progress, with no indication anything went wrong. A request that arrives mid-transition is now held and applied once the transition finishes, instead of being lost.
- **Dragging a window's corner to resize it could feel sluggish** — every tiny movement during the drag was being saved to disk immediately. The window's position is now saved once per drag instead of on every pixel of movement, and is still saved reliably if you quit while mid-drag.
- **The app's settings file could balloon to thousands of stale entries over time, gradually slowing down window dragging and tab switching, and causing a brief spinner when entering Focus Mode** — the app was generating a new, disposable internal bookkeeping entry for its main window and sidebar on every relaunch, without ever cleaning up the old ones. The main window and sidebar now reuse the same entry across relaunches, and any old orphaned entries left behind by past versions are cleaned up automatically.

## [0.2.119] - 2026-08-03

### Added

- A new **Citation…** item in the Insert menu.
- Table and Equation get keyboard shortcuts for the first time (⌘⇧D and ⌘⇧E).

### Fixed

- **Most of the Insert menu's keyboard shortcuts never actually worked, in either editor** — Task, Comment, Reference, Citation, Footnote, and Image were all advertised in the Getting Started guide with shortcuts that did nothing, because the menu items had never been wired up to respond to a key press. Section Break and Highlight had the same problem. All of them work now, in both the formatted and source editors. Citation, which used to work only in the formatted editor, now works in the source editor too. Inline Code has moved from ⌘⇧C to ⌘⌥` (Option and the backtick key), so ⌘⇧C now inserts a comment the way the Insert menu and Getting Started guide always said it would.
- **A second heading with the same title as an earlier one could lose its identity every time the document was re-parsed** — its tags, status, and other metadata could jump onto the first heading with that title instead, and a plain heading that happened to share a title with the built-in Notes or Bibliography section could delete that section's identity outright. Duplicate-titled headings now keep their own identity across edits.
- **Citing a reference from Zotero could fail with a "not found" error or show a red, broken citation placeholder** when that reference's citation key didn't match its underlying Zotero ID — which happens with older references carrying a legacy "Citation Key" entry in Zotero's Extra field. Citation lookup, caching, and insertion now match on the correct underlying ID throughout, so these references cite correctly.

## [0.2.118] - 2026-07-31

### Fixed

- **The Recent Projects list, and other remembered settings, could be permanently wiped out by a routine app update** — every release build ran the app's test suite first, and that test suite was accidentally sharing the same storage as your real Recent Projects list, last-opened project, and a few other preferences, clearing all of it out as a side effect. Testing now uses its own separate, disposable storage, so updating the app can no longer touch your real settings. Internal test and scratch files also no longer appear in your Recent Projects list.
- **Text could wrap into oddly short lines while actively typing a paragraph, then "fix itself" once the paragraph grew longer** — a paragraph that had just wrapped onto a second line could get its two lines forced to roughly half-width each instead of filling the first line normally. This no longer happens; paragraphs wrap normally while you type.
- **A comment landing right at the start or end of bold or italic text could scramble that paragraph** — if a comment annotation touched a formatting mark right at its edge, the paragraph's text could come out garbled the next time the document was parsed. Comments now stay out of the way of the formatting they sit next to.
- **A section-break marker placed right next to a paragraph, with no blank line between them, could silently wipe that paragraph's text** — this happened both in the formatted editor and in the source editor. Both now correctly keep the marker and the paragraph separate instead of losing the paragraph. A marker line with a trailing stray space is also now recognized correctly.
- **Highlighted text (`==like this==`) exported to PDF as literal equals signs** instead of being rendered as highlighted or plain text — export now strips the marker syntax so the exported document matches what you see in the editor.
- **Section titles in the outline sidebar weren't readable by VoiceOver** — the sidebar had no accessibility label for a section's title, so VoiceOver couldn't announce or locate a section by name. Section titles are now properly labeled.

## [0.2.117] - 2026-07-29

### Fixed

- **Hovering a collapsed comment, task, reference, or a footnote showed a cramped pop-up box, even when there was plenty of room to make it wider, and could occasionally show two pop-ups at once** — both are now sized properly to the text they're showing, match each other's text size (and stay proportional if you change your body text size), and each disappears the instant you start typing instead of getting stuck on screen.
- **In rare cases, typing at the very start of a zoomed-in section could land your text at the very start of the whole document instead** — a split-second timing gap right after zooming into a section (or right after reordering sections by dragging, or switching between the formatted and source editors while zoomed in) could briefly confuse the app about where "the start" actually was. That gap is now closed.
- **New comments didn't start folded up, even with "collapse annotations" already turned on** — you had to switch the setting off and back on again before a newly inserted comment would behave. Any editor opened after the setting was already set — a fresh document, or switching between the formatted and source views — never picked the setting up, because the app only told the editor about it at the moment it changed. New comments now appear folded straight away.

## [0.2.116] - 2026-07-28

### Added

- **The equation dialog's Display mode now accepts multi-line LaTeX** — the LaTeX box only ever allowed a single line, so multi-line math like `\begin{aligned}...\end{aligned}` couldn't be typed when inserting an equation. Display mode now shows a resizable, scrollable text box for multi-line entry (Inline mode stays single-line, as before), and pressing Return now adds a new line instead of accidentally submitting the dialog early.

### Fixed

- **Opening a corrupted or missing project file could fail with no explanation** — if no project was already open, double-clicking a `.ff` file in Finder, choosing File > Open, launching the app by opening a file, or picking it from Open Recent could all silently do nothing when the file's database was corrupted or missing, with no indication anything had gone wrong. All of these now show the same clear error alert.
- **A paragraph that merely mentioned the section-break marker text could be mistaken for an actual section break** — writing about the marker in a sentence, rather than using it to actually mark a break, could get it misclassified as a real section boundary. It's now only treated as a break when it's the whole line or sits at the very start of one.

## [0.2.115] - 2026-07-27

### Fixed

- **Typing `---` to make a horizontal divider line worked at first but vanished when you reopened the document** — the divider was never saved. Worse, opening a document that already contained one could throw the whole document out of alignment internally, so edits after that point could be saved to the wrong paragraph. Divider lines now save and reload correctly, whether you type them or the document arrives with them already in place.
- **A code block placed directly beneath a table, with no blank line between them, could scramble everything after it** — the app read the code block as part of the table and lost track of where each piece of the document started and ended. A table and a code block can now sit back to back safely.
- **Documents with more than one section break could mix up the information attached to them** — a section's status, tags, and word goal could jump to a different section, and one section could disappear from the outline entirely. Each section break is now identified by its actual content rather than by its generic name, so they no longer get confused with one another.
- **Clicking a collapsed comment, reference, or task did nothing useful** — you couldn't open it for editing, and clicking a collapsed task ticked it off as complete instead. Clicking any collapsed annotation now opens the same edit popup you get when it's expanded, and ticking a task off still works normally when it's expanded.
- **A project opened through a linked or aliased folder path could appear twice in Recent Projects, or open a second window instead of switching to the window already showing it** — the app was comparing two different spellings of the same folder. Both checks now use the same one.

## [0.2.114] - 2026-07-26

### Fixed

- **In the source editor, inserting a citation could revert back to the literal `/cite` text a second or two later, and jump the document back to the top** — picking a reference from Zotero showed the citation correctly at first, but a background bibliography refresh could then overwrite it with stale text and reset your scroll position. Citations now stay put, and the document no longer jumps to the top when the bibliography updates in the background.
- **Citing a reference from a shared Zotero library could fail with a "Citation Error" saying the reference wasn't found** — citations from your personal library always worked, but the same reference in a group or shared library could be rejected even though Zotero clearly had it. Citing from a shared library now works the same as citing from your own library, including exporting to PDF and reopening a document later.

## [0.2.113] - 2026-07-22

### Added

- **Print command** — File > Print now offers two options: Formatted (⌘P) prints the document the same way it would export to PDF, and Raw Markdown prints the literal markdown source text.

### Fixed

- **Numbered lists split by a pasted or dropped image could restart at 1 instead of continuing** — inserting an image in the middle of a numbered list didn't carry the numbering across it, and even once that part was fixed, simply reopening the document afterward could still reset the count back to 1. Both are now fixed, so a numbered list keeps counting correctly through an inserted image, before and after reopening the document.
- **Nested lists, quoted text, and headings could silently lose their formatting on the next save** — a numbered or bulleted list, a blockquote, or a heading nested inside a list item could have its marker stripped the next time anything in that block was saved, even from an unrelated edit, turning it back into plain text. They now keep their formatting through every save.
- **Dropping an image into the middle of a nested list could turn it into plain text and merge the list back together** — if a nested list was split by a dropped image with no blank line around it, the app could misread the image as ordinary text on the next save, silently demoting it and rejoining the two halves of the list.
- **Images dropped or pasted into the middle of a paragraph could end up permanently broken, and could vanish from the saved document entirely** — after such an image was reparsed on a later save, it could show a broken-image icon that never recovered, and in some cases its reference could be silently dropped from the document's saved data too. Both are now fixed.
- **Grammar and style checking silently gave up partway through longer documents** — LanguageTool has its own size limit per request, and a document whose text passed that limit went unchecked past that point, with no indication anything was wrong. Long documents are now automatically split into multiple checks and the results merged back together, so checking now covers documents of any length.
- **Manual snapshots (⌘⇧S), automatic snapshots, and background auto-backups could capture a block at its old position** — if a block had been moved in the editor without otherwise being edited, these could save it at its previous location instead of where you'd actually moved it to, the same issue already fixed for exporting. All three now always capture your latest changes.
- **Editing a link right at the end of a line could crash the app** — clicking a link, or pressing ⌘K to add or edit one, could crash the app if the cursor landed exactly at the end of a heading, paragraph, or list item's text.

## [0.2.112] - 2026-07-19

### Fixed

- **The toolbar's Cite button didn't insert a citation** — clicking it only refreshed the citations already in the document, and in the source editor it did nothing at all. It now inserts a citation at the cursor in both editing modes, behaving exactly like the `/cite` command and the ⌘⇧K shortcut.
- **Inserting citations in quick succession could duplicate or scramble a paragraph** — picking a citation from Zotero doesn't block the app, so you could start a second insertion (or keep editing) while the first was still waiting, and the app only kept track of one insertion spot at a time. Each pending citation now remembers its own spot and keeps it accurate while you edit, in both editing modes.
- **Deleting a citation couldn't be undone** — the background bibliography refresh that runs after a citation change used to rewrite the whole document behind the scenes, which scrambled the undo history for anything you'd just edited. The refresh now only touches the parts of the document that actually changed, so undo works normally again.
- **Deleting a citation was awkward and unpredictable** — the citation popup now has a Delete button, pressing Backspace or Delete next to a citation removes it cleanly in one press instead of behaving erratically, and the leftover double space is tidied up automatically. Also fixed: the popup's buttons could occasionally ignore a click if the mouse drifted slightly while clicking.
- **The bibliography could silently end up out of date** — two background updates finishing out of order could let an older snapshot of your citations overwrite a newer, correct one, with no error shown. Updates now confirm they're still current before writing.
- **The citation editing popup ignored dark mode** — it always appeared in light-mode colors, and in the Low Contrast Night theme its preview text was nearly unreadable. It now follows the app's theme, with readable text in all four themes.
- **Dragging an image into the document could insert it twice** — macOS sometimes reports the same drop twice, a moment apart, and the app's existing protection only caught near-instant duplicates. A single drag now always inserts a single image.

## [0.2.111] - 2026-07-16

### Fixed

- **Editing an image's position and then exporting right away (without closing and reopening the project first) could export it at its old position** — moving a block without changing its content wasn't picked up by the quick sync export normally relies on, so a mid-session export could show images (or other moved content) back where they used to be. Exporting now always re-syncs the whole document first, so moves are never missed.
- **Pasting an image could land it in the wrong place** — pasting always dropped the image below whichever paragraph the cursor happened to be in, ignoring where the cursor actually was. It's now inserted exactly where the cursor is, matching how dragging an image in already worked.
- **Dragging an image to a new spot could land it at the end of the document instead of where you dropped it** — roughly half the time, both dragging a file in from outside the app and moving an image within the document ignored the actual drop point. A visual drop indicator now also shows exactly where the image will land while you're dragging.
- **Exported PDFs could show an image drifting away from the paragraph it belonged to, especially across a page break, and every image showed a "Figure N: filename.jpg" caption instead of the one you actually typed** — in PDF, Word, and ODT exports alike. Captions you write now show up correctly in all three formats, and images without a caption no longer drift or gain a fake one.
- **Exporting could show an "Export Complete with Warnings" alert with no real warnings** — an internal diagnostic check used to investigate PDF export ordering ran on every export and could trigger the alert for no reason. It's now off by default, with an opt-in toggle under Preferences > Diagnostics for anyone who needs it.
- **Citations and footnotes typed right before quitting, or right before switching to a different project, could be lost** — the bibliography and footnote list save a moment after you stop typing, and quitting or switching projects during that short window could discard the last few seconds of that work. Both are now saved before the app quits or switches projects.

## [0.2.110] - 2026-07-11

### Fixed

- **Selecting text underlined by LanguageTool was nearly impossible** — clicking or dragging across a flagged word or phrase to select it would instead pop open the suggestion popover, which blocked the selection and kept reappearing even after you tried to dismiss it. Clicking and dragging across flagged text now selects it normally, and the popover closes on its own once you move the cursor away instead of getting in the way.
- **Grammar and style checking could silently stop partway through a document** — if a document contained a `&`, `+`, or `=` character anywhere in the text (for example, a journal name like "Context & Media"), LanguageTool would only ever check the text up to that character, with nothing checked after it and no indication anything was wrong. Also fixed: re-checking the same unchanged text more than once in a row, which could occasionally cause LanguageTool to return inconsistent results. Grammar and style checking now reliably covers the whole document.
- **Fixing a flagged spelling or grammar mistake left its underline on screen for a moment** — the underline used to stick around until the next background check caught up, even right after you'd corrected the word. It now clears the instant you edit it.
- **LanguageTool sometimes flagged the space right before a citation as an error** — for example, `schooling [@key].` could get flagged for the space before the citation, even though it was typed correctly. Fixed at the source instead of filtering out the false alarm afterward.

## [0.2.109] - 2026-07-11

### Added

- **Smart quotes** — straight quotes now curl into matching "curly" pairs as you type, in both the visual and source editors, and a pair can no longer end up mismatched (an opening quote without its closing match, or vice versa). A new toggle in the Edit menu, and a matching button in the status bar, lets you turn this off if you prefer straight quotes. The setting is now remembered correctly even when you switch between the two editing modes.

### Fixed

- **Double-clicking a document in Finder could silently do nothing, or open a stray blank window** — if no project was already open, double-clicking a document in Finder did nothing at all. Fixing that surfaced a second bug: opening a document from Finder (whether or not one was already open) could also pop open an extra, empty window alongside the correct one. Both are now fixed.
- **Added extra protection against content silently ending up in the wrong place** — closes off another way the editor's internal bookkeeping could, in rare cases, attach an existing piece of writing (like a footnote) to the wrong, blank spot instead of its own. This is the same category of bug fixed in an earlier release, now guarded against in a different part of the app.
- **Restoring a document to an older version could corrupt the wrong section** — in rare cases, deleting a section and then restoring an earlier version of the document could misidentify a different, unrelated section as the one being restored, silently corrupting it while the section you actually wanted stayed lost. The app now checks that a section's title or content actually matches before treating it as the one being restored.
- **The Recent Projects list could lose or duplicate entries** — a project could silently disappear from the list, or show up twice, because of how the app tracked where projects were stored. The list now updates reliably, and a one-time cleanup removes any duplicate entries left over from before this fix.

## [0.2.108] - 2026-07-10

### Added

- **New Diagnostics pane in Preferences** — an off-by-default toggle turns on persistent logging, and a "Generate Diagnostic Report" button bundles the log and some system info into a folder you can share when troubleshooting a hard-to-reproduce problem.

### Fixed

- **The app didn't remember your window's size and position after quitting** — resizing or moving the main window, then quitting and reopening the app, used to reset it back to a default size and position every time instead of where you left it. It now reopens at the same size and position, and returns to full screen if that's how you left it.
- **The Help menu's "Report an Issue" link went to a page that didn't exist** — it now goes to the correct place.

## [0.2.107] - 2026-07-09

### Fixed

- **The `/break` slash command could delete real text, not just the command itself** — typing a section break right after existing text in a paragraph (for example, `Some notes /break`) could delete that text along with the command, leaving only the break behind. The break now always lands in the right place relative to your text instead of eating it.
- **Converting a paragraph to a heading could silently drop a citation or footnote** — using `/h1` through `/h6` on a paragraph that contained a citation or footnote could remove it from the resulting heading with no warning.
- **Typing a section break didn't create a new section in the outline sidebar** — the break symbol appeared in the document, but the sidebar never picked it up as a new section, so the outline stayed out of sync with what you'd actually written.

## [0.2.106] - 2026-07-07

### Fixed

- **ODT export could show placeholder sample text instead of your actual document** — exporting to ODT was, in some cases, given the Word template as its style reference, which isn't valid for ODT and produced a garbled file containing the Word template's own placeholder content instead of what you wrote. ODT export now always uses a proper ODT-native style template.
- **Exporting to PDF while another PDF export was already in progress could crash the app** — overlapping PDF exports shared some of the same temporary files behind the scenes and could interfere with each other. Each export now uses its own private files, so running multiple exports at once is safe.
- **A heading added right before an already-written paragraph could export below that paragraph instead of above it** — for example, writing a paragraph, then coming back later to add a heading right before it, could cause the exported document (Word, PDF, ODT, or Markdown) to show the paragraph first and the heading second, the opposite of what you'd written.
- **Pressing Enter to start a new line, then filling it in later, could leave stray content or wrong ordering on export** — coming back to a blank line you'd created earlier (for instance, pasting text above an existing heading) could leave an invisible empty line behind and cause the new content to land in the wrong place when the document was exported.

## [0.2.105] - 2026-07-06

### Fixed

- **Deleting a header could sometimes delete the wrong content instead** — under certain conditions, removing a heading (and the text under it) could misattribute what should be deleted, silently wiping out unrelated surviving content while leaving the deleted heading's entry behind. Also fixes a related crash that could occur when replacing very large amounts of document content at once.
- **Restoring a section from version history, then editing it right away, could silently lose that edit** — for example, restoring a section and immediately deleting its header could make the deletion vanish without being saved. Also fixed: restoring a duplicate section, or reordering sections by drag-and-drop, could merge two sections' text together with no separation between them, making one section's header disappear from the outline sidebar.
- **Footnote definitions could disappear, duplicate, or get scrambled** — inserting several footnotes back-to-back, or editing a footnote's note text while another change was still saving, could drop a definition entirely (leaving only the reference marker in the text), create a duplicate, or leave two definitions with clashing numbers. The footnote notes section is now updated definition-by-definition instead of being torn down and rebuilt from scratch on every change. Also fixed: a newly inserted footnote could scroll the editor to the wrong spot, and the Getting Started guide could show a "you have unsaved changes" prompt with nothing actually changed.
- **Footnotes could export blank or broken if you exported right after typing them** — insert a footnote, type its note, and export to Word (or PDF, ODT, Markdown) right away, and the footnote could show up as raw leftover text in the body with an empty note, instead of a proper footnote marker and definition. Export now always waits for your latest edits to finish saving before it reads the document, closing two separate timing gaps that could each cause this on their own.
- **Using slash commands (for citations, footnotes, images, equations, etc.) near other special content could eat nearby text** — if your cursor sat right after a citation, footnote, image, or equation when you typed a slash command, the app could miscount where the command started and delete real text along with it (for example, turning `regulation"` into `regulati(citation`). Slash commands now always find the correct position no matter what precedes them.
- **Text typed right after a link could get absorbed into the link** — clicking to the end of a line ending in a link and continuing to type could pull the new text inside the link instead of after it. Fixed a display quirk that caused the cursor to jump backward into the link on the very next keystroke.
- **New headings and paragraphs added in quick succession could land in the wrong order in the outline sidebar** — when several new blocks were saved at once, one could lose track of where it belonged and get appended to the end of the document instead, and a subsequent drag-and-drop could lock in that wrong order permanently. Each new block now correctly finds its place relative to the others.
- **Code examples containing table or math syntax could corrupt nearby content** — a code block that itself contained lines starting with `|` (table syntax) or a `$$` math block was being misread as an actual table or equation, silently splitting the code block into two pieces behind the scenes and shifting which paragraph or heading later edits applied to. This had already corrupted the bundled Getting Started guide, which is repaired as part of this fix.
- **Reopening a math equation for editing could show outdated text** — after editing an equation and closing the edit popup, reopening it again could still display the previous version instead of what you'd just typed.
- **The bundled Getting Started guide had gone stale** — recent additions to the guide (covering features like tables and math equations) weren't making it into the copy shipped with the app. It's now up to date.

## [0.2.104] - 2026-06-12

### Added

- **Math equations** — write mathematical formulas in LaTeX, both inline (like `$x^2$` inside a sentence) and as centered blocks (`$$...$$`). Insert them from the toolbar, the `/equation` slash command, or the Insert menu. In the visual editor an equation appears as properly typeset math; click it to edit the LaTeX code with a live preview, then press Enter to save or Escape to cancel. Equations are saved with your document and export to PDF and Word as real typeset formulas.

### Fixed

- **Inline code no longer swallows the text you type after it** — when you formatted a word as `code` in the middle of a line and kept typing, the new text used to get pulled into the code styling along with it. Now, when your cursor sits right at the edge of a code span, whatever you type next is ordinary text by default. If you do want to keep adding to the code, the left and right arrow keys step in and out of the span as a separate stop, and a faint outline appears around the code to show when your next keystroke would join it. The cursor also stays the same height whether it's inside code or not, instead of jumping slightly.

## [0.2.103] - 2026-06-11

### Added

- **Selection word count** — select any text and the status bar shows how many words are selected, as "123 of 4,567 words". It works in both editing modes, counts the selection with the same rules as the document total (so the two numbers always agree, citations included), and returns to the normal display when you click away.
- **Word count while zoomed** — when you zoom into a section, the status bar now shows that section's count alongside the whole document's, as "1,234 of 10,000 words". Previously it showed only the document total.

### Fixed

- **Word count stopped updating while zoomed into a section** — and worse, anything written in a *new* paragraph while zoomed wasn't saved until you zoomed back out. Editing paragraphs that already existed worked fine, which made the bug look random. The cause: paragraphs created during zoom never received the internal tag that live saving relies on (a safeguard meant only for the temporary footnotes section shown while zoomed, applied too broadly). The safeguard is now limited to that footnotes section, so everything you write while zoomed counts and saves immediately. New tests cover both sides: zoomed writing syncs, and the temporary footnotes section still never leaks into the document.

## [0.2.102] - 2026-06-10

### Fixed

- **`==highlight==` markers inflated word counts and leaked into previews** — `MarkdownUtils.stripMarkdownSyntax` strips `**bold**`, `*italic*`, `~~strike~~`, backticks, links, and images but had no rule for highlight marks, so the literal `==` delimiters survived into the word-count tokenizer and section preview strings. Added a `==(.+?)==` stripper alongside the other inline-mark rules, with two new `WordCountCalculationTests` cases.
- **Table-truncation alert never fired on the common startup path** — the preloaded-WebView claim block in `MilkdownEditor.swift` re-registers fourteen message handlers but omitted `tableInsertTruncated`, so pasting an oversized table (>1000×100 cap) on a preloaded-editor session threw a silent JS `TypeError` instead of surfacing the `NSAlert`. The handler is now registered on both paths.

## [0.2.101] - 2026-05-10

### Added

- **GFM table support across both editors** — full table feature in Milkdown (WYSIWYG) and CodeMirror (source). Three insertion paths (`/table` slash command, Insert menu, toolbar button) drop a 3×2 table (1 header + 2 data rows). Milkdown gets a floating cell toolbar with row/column add/delete and per-column alignment; CodeMirror keeps the GFM markdown. Slash command auto-hides when the cursor is inside an existing table to prevent GFM-invalid nesting.
- **TSV / HTML table paste** — pasting TSV or `<table>` HTML outside a table builds real ProseMirror table nodes (Milkdown) or inserts a GFM markdown block (CodeMirror); inside a cell the content is flattened to plain text. Capped at 1000×100 with a `tableInsertTruncated` WKScriptMessage bridge that surfaces an `NSAlert` from the Swift coordinator.
- **Markdown link InputRule inside cells** — typing `[text](url)` then `)` inside a table cell converts to a real link mark. Registered as `markdownLinkPlugin` alongside `autolinkPlugin`.
- **Three-layer table test suite** — 13 Vitest serializer cases (marks, alignment, pipe escaping, hard-break, header rows, padding idempotency) guard `block-sync-plugin.ts:474`; five `MilkdownTableMarkTests` exercise bold / italic / code / link / highlight inside cells across the 500ms block-sync poll cycle; `TableRoundtripTests` asserts AST equality for 5-cycle round-trips, a 10×10 performance smoke, and DOCX export integrity. Adds a `tables-roundtrip.md` golden fixture covering alignment, edge cases, and empty cells.
- **Shared `formatTable()` utility** at `web/shared/format-table.ts` — single source of truth for compact pipe-table formatting; consumed by both editors and by the paste plugins. `truncateParsedTable` was hoisted here too, eliminating duplicate copies in `milkdown/table-paste-plugin.ts` and `codemirror/table-paste.ts`.
- **`docs/lessons/tables/`** — `serializer-rules.md` (8 rules, dual-path explanation, `compareTableASTs` position-key stripping note) and `export-checklist.md` (automated CI checks + manual DOCX/ODT/PDF/Markdown visual checklist). Tables section added to Getting Started, replacing the prior "Tables and Formulas — coming soon" stub.

### Fixed

- **Table serializer stub silently produced empty markdown** in `block-sync-plugin.ts:474` — replaced with the real `mdast-util-gfm-table` GFM serializer, so tables now persist correctly to SQLite. The Vitest Layer 1 suite is the regression guard.
- **In-cell paste dropped link marks** — ProseMirror's `handlePaste` chain is bypassed for inside-cell pastes (Milkdown's clipboard plugin runs first and strips marks). `tablePastePlugin` now installs a capture-phase `paste` listener on `editorView.dom` via a `view()` callback; the listener `preventDefault` + `stopImmediatePropagation` and runs the existing `buildInlineContent[FromHTML]` path that preserves link marks. Image pastes are deferred to `imagePasteDropPlugin` via `clipboardData.items` detection (mirrors `image-plugin.ts:556-563`; the `types[]` array is unreliable on Safari/WebKit). The `view()` returns a `destroy()` that removes the listener on editor recreate. Defense-in-depth: the inside-cell branch in `handlePaste` is preserved in case ProseMirror does dispatch for some path.
- **Cross-cell content bleed on table paste** — the inside-cell branch now fires first and always returns true, blocking Milkdown's generic clipboard plugin from inserting block content across cell boundaries. `TextSelection.near($head, 1)` narrows any active `CellSelection` before `replaceWith`.
- **Toolbar buttons misbehaved on multi-cell selection** — added `narrowToHeadCell()` helper that collapses `CellSelection` to a single cell at `sel.head` before any of the six toolbar commands fire. Skips `TextSelection` (no multi-cell span possible).
- **Cross-editor undo polluted the timeline** — eight programmatic content-replacement dispatch sites in CodeMirror (`setContent`) and Milkdown (`setContent` / `applyBlocks` / `setContentWithBlockIds`, including the image-metadata `metaTr` follow-ups) now mark transactions with `addToHistory: false`. Lesson recorded in `docs/lessons/prosemirror/content-handling.md`.
- **`/table` left a stray blank paragraph above the inserted table** — Milkdown `insertTable` now replaces an empty top-level paragraph instead of inserting after it; CodeMirror `insertTableCommand` drops the extra leading newline on empty lines and inserts no newline at all at the very top of the document.
- **Inside-table heuristic missed pasted content following a table line** — CodeMirror `table-paste.ts` now also checks the previous non-blank line for a leading pipe character. TSV detection threshold tightened to `header.length >= 2 && rows.length >= 1` in both editors to suppress false-positive table conversion.
- **`compareTableASTs` false negatives from column-width changes** — now strips `position` keys before JSON comparison, so column-width padding shifting source offsets no longer breaks AST equality assertions in `TableRoundtripTests`.

### Changed

- **Compact table source format** — `tablePipeAlign: false` on `remarkGFMPlugin` (mode-switch path) plus rewritten `formatTable()` (block-sync path) emit single-space cells and single-dash separators instead of width-padded columns. Both paths must match so DB writes and mode-switch reads stay consistent.
- **`mdast-util-from-markdown`, `mdast-util-gfm-table`, `micromark-extension-gfm-table` promoted to direct milkdown package dependencies** — they were transitive-only, which caused Rollup to fail resolution once the real GFM serializer was wired up.
- **Diagnostic noise removed** — dropped the `[table-paste]` log helper and six call sites; trimmed verbose factory-init / `handlePaste` entry payloads; collapsed dead-info comments left over from the bug3 investigation. ~50 lines removed from `table-paste-plugin.ts` with no behavior change. Biome auto-fix pass on 17 files (template literals, literal keys, optional chains, import order).
- **`isEditorReady` / `isCleanedUp` guard** added to Milkdown's `insertTableObserver` to mirror the CodeMirror pattern; removes a class of "observer fires after editor torn down" hazards. Removed `TEMPORARY` comment labels and a stray canary log from `table-tools-plugin.ts`.

## [0.2.100] - 2026-05-05

### Fixed

- **Highlight mark broke `getMarkdown()` on every keystroke** — `editor.action(getMarkdown())` threw `Cannot handle unknown node highlight` whenever a `==highlighted==` span was present in the document, because the highlight plugin registered a remark parse extension but no `mdast-util-to-markdown` stringify handler. The throw silently broke five downstream consumers (content push timer, mode-toggle, heading-level update, cursor helpers, quit-time sync). Registers a custom `highlight` handler via Milkdown's `remarkStringifyOptionsCtx` slice. Also drops the inert `{ open, close }` props from the `state.withMark()` call (never consumed by the serializer pipeline).
- **Annotation reconcile silently overwrote rows sharing a `(type, bucket)` key** — `AnnotationSyncService` keyed `dbLookup` as `[String: Annotation]`, so when two DB annotations hashed to the same bucket the second clobbered the first, leaving one parsed annotation orphaned and one DB id stolen. `dbLookup` is now `[String: [Annotation]]` with best-candidate selection (exact-offset → exact-text → minimum-distance → array-order tiebreakers) and consume-on-match so one parsed annotation cannot steal another's DB id. The new `reconcileBucketCollisionPreservesBothAnnotations` test was confirmed to fail against the old code and pass with the fix.
- **`findPrecedingHighlight` whitespace trim missed trailing newlines** — switched from `.whitespaces` to `.whitespacesAndNewlines`. Defensive: the highlight regex's `\s*$` already absorbs trailing newlines before trim runs, so this is a latent-bug fix rather than the primary symptom.
- **Recent Projects menu stale after project switch** — `RecentProjectsMenu` snapshotted `DocumentManager.shared.recentProjects` into `@State` via `.onAppear`, but `@Observable` change-tracking only fires for property reads inside a tracked render pass; the `.onAppear` read did not subscribe, so the menu kept showing the pre-switch list. Reads `DocumentManager.shared.recentProjects` directly in `body`. Also drops the dead `Task { @MainActor in }` wrapper from the Clear button (the call site is already `@MainActor` via the class annotation).
- **Pre-commit test hook fired on the wrong commands and missed Swift Testing failures** — the `pre-commit-tests.sh` PreToolUse hook triggered on any Bash command containing the string `git commit` (so `git commit-tree`, `grep 'git commit'`, etc. all ran tests), and its failure regex only matched XCTest markers, so Swift Testing failures slipped through with exit 0. Trigger now anchors to `git commit` / `git -C <path> commit` via a `case` match. Failure regex adds Swift Testing markers (`✘ Test`, `recorded an issue`, `Expectation failed`); `◇ Test` is deliberately excluded since it appears on every passing-test boundary. Hardening: `LC_ALL` pin for multibyte grep, `TEST_EXIT=$?` captured immediately after `xcodebuild`, `tr -d '\r'` on output, tail-30 fallback, empty/whitespace `COMMAND` safety log.

### Added

- **Highlight round-trip integration tests** in `block-sync-marks.test.ts` — three new cases that mount a real Milkdown editor (jsdom) and assert `==highlight==` delimiters survive parse → serialize round-trips. Adds `jsdom` as a devDependency.
- **`AnnotationSyncTests` collision suite** — six new `@MainActor` cases covering bucket-collision preservation, exact-offset preference, exact-text preference, minimum-distance tiebreaker, array-order tiebreaker, and consume-on-match semantics.
- **`docs/lessons/milkdown-mdast-stringify-handlers.md`** — documents the parse-extension/stringify-extension symmetry pattern surfaced by the highlight fix; any custom mdast node type needs registration on both sides or `getMarkdown()` will throw.
- **`docs/lessons/swiftui-commands-observable.md`** — documents the `Commands` → `NSMenu` `@Observable` bridge: property reads must happen inside `body` for change-tracking to subscribe, not in `.onAppear` snapshots. Recents-menu manual-verification checklist appended to `docs/guides/testing-overview.md`.



### Fixed

- **Code-span serializer round-trip corruption** — two bugs in the `codeMark` branch of `serializeInlineContent` in `web/milkdown/src/block-sync-plugin.ts`. First, an unconditional reopen loop ran after emitting every code span, producing stray empty delimiter pairs whenever the next child had fewer marks (e.g. `[strong]'hello'` + `[inlineCode]'code'` + `[]'world'` serialized as `**hello**\`code\`****world`). Dropped the reopen loop — the next child's own prefix-matching path already opens whatever marks it actually has. Second, a hard-coded single-backtick delimiter corrupted content with internal backticks (`foo\`bar` serialized as `\`foo\`bar\``, which parses as `code('foo') + 'bar' + stray backtick`). New `codeSpanFor()` helper implements CommonMark §6.1: delimiter length = longest internal backtick run + 1, with symmetric space padding when content starts or ends with a backtick. The old `padCodeSpan` is retained but `@deprecated`.

### Added

- **`codeSpanFor` unit suite (6 cases)** and **"code span round-trip fixes" integration suite** in `block-sync-marks.test.ts` covering asymmetric mark shape, internal backtick, and trailing backtick scenarios. Updated the existing "inlineCode with leading backtick" test whose expected output was the old broken form.

### Changed

- **`codeSpanFor` fast-paths the no-backtick common case** — avoids a `matchAll` + `String.repeat(1)` allocation on every code-mark text node. When the content contains no backticks the delimiter is always a single backtick and padding never applies, so the full CommonMark §6.1 algorithm is unnecessary.

## [0.2.98] - 2026-04-22

### Added

- **Sparkle auto-update** — replaces the hand-rolled GitHub-API + NSAlert update checker with `SPUStandardUpdaterController`. `Help > Check for Updates…` now drives Sparkle's standard UI; automatic background checks are configured via `SUFeedURL`/`SUPublicEDKey`/`SUEnableAutomaticChecks` in Info.plist. New `scripts/release.sh` automates appcast generation and homepage push after each build. See `docs/guides/sparkle-updates.md`.

### Removed

- **`UpdateChecker.swift`** — GitHub Releases API polling + `NSAlert` update prompt, superseded by Sparkle.

## [0.2.97] - 2026-04-20

### Fixed

- **Inline marks silently stripped during block-sync to SQLite** — `serializeInlineContent` in `block-sync-plugin.ts` read `child.text` directly, discarding every mark. Links, bold, italic, inline code, strikethrough, and highlight were dropped on the sync-to-DB path, so exports read already-broken data from SQLite even though the editor displayed the marks correctly. Rewrote the text-block branch to walk marks mirroring prosemirror-markdown's `MarkdownSerializer.renderInline`: link (with href/title escaping), strong, emphasis/em, inlineCode/code_inline, strike_through/strikethrough, and highlight. Schema aliases handled explicitly; unknown marks warn once and emit text without delimiters; expected marks asserted on plugin init. Recovery is passive — new edits self-heal, pre-fix blocks keep their stripped fragments until edited. Active backfill migration and table-cell mark serialization tracked as deferred stubs under `docs/deferred/`.

### Added

- **34 round-trip mark tests** in `block-sync-plugin.test.ts` covering each mark, combinations (bold-in-link, link-in-bold, code exclusivity), per-block-type paths, and the paragraph leading `\#` / `\[^N]:` structural escapes.
- **`docs/findings/inline-marks-stripped-on-export.md`** — root cause, fix, and consumer-audit conclusions. Linked alongside the two new deferred stubs from `docs/INDEX.md`.

### Changed

- **Block-sync mark serializer hot-path optimization** — plain-text children (no marks, no active stack) now skip the mark-alignment and keep-prefix machinery entirely; this is the overwhelming common case while typing. Flat `CANONICAL_BY_NAME` lookup replaces the `Object.entries` + `Array.includes` scan in `canonicalMarkKey` (O(1), no allocation on the hot path). `MARK_RANK` record replaces `MARK_OPEN_ORDER.indexOf` in the sort comparator. Parallel `openFor`/`closeFor` switches collapsed into a single `MARK_DELIMITERS` table with per-mark `{open, close}` entries; adding a mark is now one row instead of two.
- **Biome formatter pass** on `block-sync-plugin.ts` and its new test file (parameter wrapping, template literals in tests). No behavior change.

## [0.2.96] - 2026-04-20

### Fixed

- **Sidebar and status-bar word count stopped updating after edits** — `observeOutlineBlocks` had `.removeDuplicates()` re-added by an unrelated perf-batch commit (`a004534`, Feb 27) that silently reverted the deliberate Feb 19 fix. The tracking closure returns only heading + pseudo-section rows, but the downstream sidebar derives per-section word counts from body blocks; body-only paragraph edits left the heading projection unchanged, so dedup suppressed the emission and the sidebar stayed frozen at open-time values. Today's `recomputeStoredBlockWordCounts` migration masked the regression by updating counts at project open, but subsequent edits were invisible. Removed the dedup, added a hostile-to-drive-by comment block citing the four architectural docs that agree the line must not be present, and asserted the property by `OutlineObservationTests.bodyEditReEmits`.

### Removed

- **Dead code: `ProjectDatabase.observeBlocks(for:)`** — unused since the pre-block-sync architecture (zero call sites in HEAD). Its co-existence alongside `observeOutlineBlocks` invited confusion about when `.removeDuplicates()` on a ValueObservation is safe. Only `observeOutlineBlocks` is now defined.

### Added

- **`OutlineObservationTests`** — three Swift Testing cases covering body-edit re-emission (the durable guardrail against `.removeDuplicates()` regressions), heading-edit re-emission (positive baseline), and metadata-column write re-emission on headings (covers the `updateSection` path).

## [0.2.95] - 2026-04-20

### Fixed

- **Block-id Phase-1 figure ID theft** — when a user typed a single character inside a paragraph, every figure block whose offset shifted by +1 silently claimed the paragraph ID that had been at its new offset before the shift. `detectChanges` then reported the paragraph as "textContent went from N chars to empty" (the content is now on the figure node), cascading into a `u=15 i=85 d=85` diff per keystroke that grew the DB from 135 → 184 blocks on a single character. Root cause was `block-id-plugin.ts` Phase 1's `typeMatches` short-circuit (`!structureChanged || …`) that bypassed the type check whenever block count was unchanged. Fix introduces `ATOMIC_BLOCK_TYPES = {'figure'}` and a pure `phase1CanClaim` helper: cross-type Phase-1 claims are allowed for legitimate input-rule conversions (paragraph↔heading via `# `, paragraph↔table via `|a|b|`, paragraph↔hr via `---`, etc.) but blocked when either side is `figure`. The Phase-2 type-filtered proximity match correctly relocates the deferred figure to its actual position.
- **Word count jumped on first edit** — bundled `getting-started.ff` (and any user project saved before today's word-count rule changes) ships a pre-populated `content.sqlite` with `block.wordCount` values precomputed under the old rules. On open the app read those stored values directly, displaying a stale total; the first edit then recalculated one block under the new rules, making the displayed total swing unexpectedly. New `ProjectDatabase.recomputeStoredBlockWordCounts(projectId:)` runs idempotently at every project open inside `configureForCurrentProject()`, recomputes every block under current rules, and writes back only changed rows via a partial-column update (`block.update(db, columns: [.wordCount])`) so `updatedAt` stays frozen.
- **Bibliography blocks hard-zeroed** — `Block.recalculateWordCount()` returned `0` for `isBibliography == true`, which defeated the existing "Exclude Bibliography" toggle. Many journals count bibliography; the user's toggle is the right policy lever. Bibliography blocks now count their actual prose. The `filteredTotalWordCount` filter at `EditorViewState.swift:164` remains the single exclusion lever.
- **Citations stripped entirely** — `[@smith2020]` contributed `0` words under the v1 strip rule. Journal counts include rendered citations. `stripForWordCount` now substitutes each `@key` with `CIT CIT` (2 tokens, approximating "Smith 2020") and each `-@key` with `CIT` (1 token, approximating "2020"), preserving locator words inside the bracket. Email addresses and autolinks (`<alice@host.org>`) are excluded via lookbehind + ordering.
- **Image stripping ran after link stripping in `stripMarkdownSyntax`** — the link regex matched `[alt](url)` inside the image syntax, leaving a stray `!alt text` that leaked alt words into the count. Image stripping now runs first, and the link regex has a `(?<!!)` lookbehind as belt-and-braces.
- **Force-cast crash hazard in `batchWordCounts`** — `row["wordCount"] as Int` would crash if the column was ever NULL (e.g. after half-finished migrations). Replaced with `(row["wordCount"] as Int?) ?? 0` and a SQL `COALESCE(wordCount, 0)`.
- **`try?` swallowed `batchWordCounts` errors** — a silently-zeroed sidebar would never surface. Replaced with explicit `catch` + `DebugLog.log(.outline, …)` and hopped the call off the main thread.
- **Missing `recalculateWordCount()` after creating "Notes" heading blocks** — both `SectionSyncService` and `FootnoteSyncService` construct a `# Notes` heading block programmatically; neither initialized its `wordCount` (defaulted to 0). Both now call `recalculateWordCount()` before insert.
- **`BlockParser.parse` bypassed the canonical helper** — computed `wordCount` inline via `MarkdownUtils.wordCount(for:)` instead of calling `Block.recalculateWordCount()` after block construction. Code-block and image blocks parsed from markdown therefore got inflated counts at parse time. Now routes through the canonical helper.
- **Duplicated `SYNC_DIAG_DETAIL` constant** — `block-sync-plugin.ts` redeclared the flag locally instead of importing it from `block-id-plugin`. Flipping one to `true` silently left the other `false`. Now imported from a single source.

### Added

- **`phase1CanClaim` helper + 20 vitest cases** in `web/milkdown/src/__tests__/block-id-phase1.test.ts` covering same-type, input-rule conversions, atomic-type theft (forward and reverse), already-claimed, empty-offset.
- **Swift safety net** — `BlockSyncService.shouldRejectAsStale` (refactored from existing inline guard, preserves the pre-existing 100%-delete-no-inserts hard reject at `blockCount > 2`) and `hasBalancedMassiveChurnSignature` (warning-only telemetry that detects the catastrophic-churn pattern observed during the bug). Both helpers are `nonisolated static` and pure-over-`Sendable`-value-types.
- **`BlockSyncStaleGuardTests`** — 13 Swift Testing cases parity-asserting the hard-reject rule and exercising the warning-signature arithmetic against legitimate-bulk-op edge cases.
- **`MarkdownUtils.stripForWordCount(from:)`** — comprehensive strip pass handling fenced code, display + inline math (with Pandoc currency guard), Pandoc citations (render-count), HTML tags + comments, YAML frontmatter, reference-style link definitions, Pandoc attribute blocks (`{#id}`, `{.class}`, `{key=val}`), task-checkbox markers, table separator rows, table pipe separators, and em/en-dash word splitting. 15 regex patterns precompiled to `private static let NSRegularExpression` so the sweep stays cheap in tight loops.
- **`[WordCount] recomputed …` migration summary log** — unconditional `DebugLog.always` print at every project open so a stale-count recompute is visible without enabling categories.
- **`[batchWordCounts]` total log** (`.outline` category) — prints `total=<N>` on every sidebar refresh, making spurious swings traceable.
- **`[Blocks:edit]` per-edit delta log** (`.data` category) — fires inside `applyBlockChangesFromEditor` when a block's `wordCount` actually changes, pinpointing which block moved and by how much.
- **57 new word-count tests** — `WordCountCalculationTests` (37, covering code blocks, math, citations policy, HTML, frontmatter, task checkboxes, dashes, autolinks, inline code) + `BatchWordCountsTests` (20, covering boundary semantics, migration correctness, bibliography-not-zeroed, code-block zeroing, `updatedAt` preservation, empty project, multi-project isolation, `excludeBibliography` toggle end-to-end).

### Changed

- **`Block.recalculateWordCount()` is now block-type-aware** — zero for `.codeBlock`, `.horizontalRule`, `.sectionBreak`, `.image` (no user prose by definition); real prose count for everything else including `isBibliography` blocks.
- **`EditorViewState` word-count reads are off-main** — `startObserving` and `refreshSections` now perform `batchWordCounts` via `Task.detached(priority: .userInitiated)`, hopping back to `@MainActor` only for the final `sections` assignment.
- **`DebugLog.enabled` now includes `.outline` and `.data`** temporarily for word-count debugging — gives per-refresh totals and per-edit deltas in the console.
- **Dead code removed from `Database+BlocksWordCount.swift`** — `recalculateBlockWordCounts`, `totalWordCount`, `sectionOnlyWordCount`, `wordCountForHeading` (all unreferenced; `batchWordCounts` is now the single public entry point).
- **Dead code removed from `Database+Sections.swift`** — `recalculateWordCounts(projectId:)` and `aggregatedWordCount(sectionId:)` (both unreferenced).
- **`batchWordCounts` hardened** — safe NULL handling via `COALESCE`, multi-project-span warning log, doc comments spelling out section-only vs aggregate semantics.
- **Dead diagnostic counters removed from `BlockSyncService`** — `staleSnapshotRejectCount` and `suspectedChurnCount` had no readers anywhere in the codebase; the `DebugLog.always` lines already carried the events.
- **`block-sync-plugin` diagnostic logs gated** — the `SKIP` snapshot log and per-UPDATE detect log fired unconditionally on every keystroke (allocating `typeStr` and a `changes[]` array that are diagnostic-only); both now gated behind `SYNC_DIAG_DETAIL`.

## [0.2.94] - 2026-04-18

### Fixed

- **Spell/grammar popup priority on overlapping ranges** — when NSSpellChecker and LanguageTool both covered the same text range, the web editor rendered both underlines but the click handler returned NSSpellChecker's result first, so clicking a blue-underlined word opened the spell menu instead of LT's grammar/style popup. `SpellCheckService.check()` now suppresses any NSSpellChecker result whose range overlaps an active LT result. Built-in mode (LT off) is unchanged.

### Added

- **`.proofing` DebugLog category** — LT request/response instrumentation (disabled by default; enable when diagnosing coverage or filter balance).
- **`DebugLog.isEnabled(_:)`** — lets logging helpers early-return instead of running unconditional string/loop work on every scan.

### Changed

- **Proofing diagnostics simplified** — gated `logRequestBoundary`, `logResponseBoundary`, and the dispatcher-level summary behind `DebugLog.isEnabled(.proofing)` so their NSString substring/replace and per-type counting loops no longer run on the MainActor every ~400ms when disabled.
- **Deduplicated type-counting loops** — extracted `SpellCheckService.countByType(_:) -> TypeCounts` to remove duplicated switch-on-String-type loops in `SpellCheckService` and `LanguageToolProvider`.
- **Split parse-drop counters** — `ParseDiagnostics.droppedZeroLength` split into `droppedMissingFields` (guard-let failure) and `droppedZeroLength` (length ≤ 0); log line reports both.
- **`LanguageToolProvider.check()` refactor** — extracted `buildCheckRequest` and diagnostic-logging helpers to stay under the cyclomatic-complexity limit.
- **`boundaryPreviewChars` constant** (200) replaces the magic number in boundary logging.
- **Boundary-filter comment** updated with measured note ("~20% of raw matches on prose with citations/footnotes/annotations") instead of the prior speculative claim.

## [0.2.93] - 2026-04-18

### Fixed

- **Tiny window on first launch** — the main `WindowGroup` had no sizing modifier, so macOS sized the window to the loading view's intrinsic content. Added `.defaultWindowPlacement` that targets a 13-inch laptop's usable area (1400×900) and clamps to the visible screen: on smaller displays the window fills the screen, on larger displays it stays "13-inch sized" and centered. Last-used size/position and fullscreen state still restore automatically via SwiftUI's built-in scene persistence — the default only applies when there's no saved state.

## [0.2.88] - 2026-03-19

### Fixed

- **Hierarchy enforcement sibling normalization** — when a header was clamped (e.g., H4→H3), only the first child was adjusted; siblings at the same level passed the predecessor+1 constraint. Simplified by replacing delta propagation with direct demotion, with early-return guard for the common case where hierarchy is already valid.
- **Cursor sync drift on atom-containing paragraphs** — ProseMirror `textContent` produces double spaces for atom nodes (citations, footnotes), causing position mismatch during sync. Normalized whitespace at all comparison sites, clamped `Selection.near()` to matched block bounds to prevent cross-paragraph jumps, and stripped annotation syntax in `stripMarkdownSyntax()`.
- **Spellcheck skipping inline code** — `SKIP_MARK_TYPES` used wrong mark name (`code_inline` instead of Milkdown's `inlineCode`), so inline code spans were spell-checked.
- **Auto-backup lifecycle methods never called** — `appWillQuit()`, `projectWillSwitch()`, `contentDidSave()` were defined on AutoBackupService but never wired up; snapshots before quit/switch were not taken. Connected all three, added 3s timeout for quit snapshot, and fixed `performProjectClose()` race by awaiting backup before reset.
- **Backup pruning blocking project switch/quit** — pruning ran synchronously on the project-switch/quit path. Moved to idle-time execution.

### Added

- **Inline code toggle** (Cmd+E / Cmd+Shift+C) — `toggleInlineCode` command in both Milkdown and CodeMirror editors, wired through EditorCommands and ViewNotificationModifiers. Includes backtick-wraps-selection ProseMirror plugin for WKWebView.
- **HierarchyEnforcementTests** — 8 unit tests covering sibling normalization, nested subtrees, subtree exit, H1-first rule, deep nesting chains, and independent subtrees.

## [0.2.87] - 2026-03-18

### Fixed

- **False 'Zotero Not Running' alert on app launch** — `isConnected` guard in `fetchItemsForCitekeys` threw `.notRunning` without attempting an HTTP request. At launch, `isConnected` defaults to false, so citation resolution raced against `connectToZotero()` and always lost. Removed the premature guard; now sets `isConnected=true` on successful fetch and maps `URLError` connection-refused to `.notRunning`.

### Changed

- **ZoteroServiceConnectionTests tightened** — second test now verifies the method actually attempts HTTP when `isConnected` is false and sets `isConnected=true` on success (previously accepted any `ZoteroError` and could never fail).

## [0.2.86] - 2026-03-18

### Fixed

- **Persistent image size reset** — image width was stored only in a DB side-channel (`block.imageWidth`) that got lost during any markdown round-trip (editor mode toggle, swap, zoom, replaceBlocks). Now encodes width as `{width=N%}` in the markdown fragment itself using Pandoc attribute syntax, surviving all round-trip paths.
- **Image dedup regression** — deduplication compared by exact markdown fragment, so same-src images with different `{width=N%}` suffixes bypassed dedup. Switched both `deduplicateAdjacentImageBlocks` and within-batch INSERT dedup to compare by `imageSrc`.
- **Width nullification on edit** — removing `{width=N%}` in source mode now clears the stale DB value (UPDATE path unconditionally assigns `imageWidth`).
- **Resize drag stale container width** — resize drag now computes percentage on each move instead of converting pixels at end, avoiding stale container width if sidebar opens mid-drag.
- **Width preservation with `||` vs `??`** — `api-content.ts` width fallback used `||` which treated `width=0` as falsy; switched to `??`.

### Changed

- **Shared width parser** — extracted `BlockParser.parseImageWidthPercent(from:)` to replace 3 inline copies of the width-parsing regex.
- **Image stripping regex** — `utils.ts` now consumes `{width=N%}` suffix when stripping image markup.

### Added

- **ImageWidthRoundtripTests** — 17 new tests covering parser extraction, roundtrip, helper methods, replaceBlocks, caption+width, editor sync paths, export format, and dedup regression cases.

## [0.2.85] - 2026-03-17

### Added

- **Tier 2 integration test suite** (79 tests) — SectionMetadataTests, ImageImportServiceTests, FindBarStateTests, AnnotationFilterTests, FocusModeTests, SectionOperationsTests, ProjectLifecycleTests, FormattingBridgeTests, EditorModeSwitchTests
- **Phase 6 risk-based tests** (16 Swift + 4 Vitest) — ExportIntegrityTests, BibliographyDropGuardTests, find-replace annotation safety
- **Vitest web test suite** (52 tests) — citation parsing, annotation parsing, footnote parsing, find-replace regex; set up Vitest 2.x in web/ monorepo

### Changed

- **TestFixtureFactory extraction** — moved `createTestDatabase`, `fetchBlocks`, `getProjectId`, `headingBlocks` from 11 test files into shared static methods (~170 lines dedup)
- **Source refactors for testability** — exported `annotationRegex`/`taskCheckboxRegex` from annotation-plugin.ts, `footnoteRefRegex` from footnote-plugin.ts, extracted `buildSearchRegex()` from find-replace.ts

### Fixed

- **testEditorModeToggle** — query buttons instead of staticTexts; scoped to verifiable state (toggle depends on WebView async chain unavailable in XCUITest)

## [0.2.84] - 2026-03-17

### Added

- **Tier 1 unit test suite** — SectionReconcilerTests, ContentStateMachineTests, ZoomDataIntegrityTests, BlockReorderIntegrityTests, BlockRoundtripTests
- **Test infrastructure** — TestFixtureFactory, rich test fixture with parsed blocks, FixtureGeneratorTests
- **Pre-commit merge-check script** and install-hooks script for CI/CD gating

### Changed

- **Replaced Xcode MCP with XcodeBuildMCP** across documentation, settings, and hooks
- **Updated test documentation** (running-tests.md, testing-architecture.md)

### Fixed

- **Test fixture block population** — fixture now parses markdown into blocks (was only storing raw markdown)
- **Test signing for CLI execution** — CODE_SIGN_IDENTITY override for xcodebuild without Xcode GUI

## [0.2.83] - 2026-03-17

### Added

- **MarkdownContentView** — new shared SwiftUI component for rendering markdown previews with fenced code block support (monospace font, background), inline formatting, and heading styles
- **Version history comparison mode improvements** — sidebar deltas now respond to "vs Current / vs Previous" picker; per-section word deltas shown in backup column; new sections show full count as positive delta

### Changed

- **Version history redesign** — redesigned version history window and sheet with improved layout: matched header button heights (.bordered/.small), increased header breathing room, tightened section row spacing (VStack 8→4, vertical padding 8→6), hidden redundant Filter label
- **Build process** — updated build process so Chrome always loads; added build phases in project.yml
- **Documentation reorganized** — split monolithic lesson files into focused sub-files with INDEX.md navigation; cleaned up old plans; restructured editor communication docs

### Fixed

- **Unstable SwiftUI IDs** — `MarkdownElement.lineBreak` now carries a stable index instead of generating a new UUID on every access, which defeated SwiftUI diffing
- **O(n²) snapshot list performance** — `SnapshotRowView` now receives precomputed `snapshotIndex` via lookup map, eliminating O(n) `firstIndex(where:)` per row
- **Duplicated backup analysis** — extracted `computeBackupAnalysis()` shared helper, eliminating duplication between Window and Sheet views

## [0.2.82] - 2026-03-15

### Fixed

- **Editor mode toggle (Cmd+/) dropping keystrokes** — the 1.5s `.editorTransition` contentState window (which suppresses Milkdown polls during initialization) was also blocking toggle requests, silently dropping ~2/3 of Cmd+/ keystrokes. Decoupled toggle protection from polling suppression; added 0.5s timestamp-based debounce; routed all toggle entry points through `requestEditorModeToggle()`

## [0.2.80] - 2026-03-15

### Changed

- **Lowered deployment target from macOS 26.0 to 15.0 (Sequoia)** — no macOS 26-specific APIs were in use; this makes the app available to far more users

## [0.2.79] - 2026-03-14

### Added

- **Finder file-open** — double-clicking a `.ff` file in Finder now opens it in the app. Handles both cold launch (stashes URL for `determineInitialState()`) and hot open (flushes current project first). Includes duplicate Apple Event detection and integrity error UI.

### Fixed

- **Data loss on quit, close, and zoom** — replaced `withCheckedContinuation` with native async `evaluateJavaScript` in BlockSyncService (5 call sites); added 5s poll timeout to prevent permanent hangs; `applicationShouldTerminate` now fetches fresh JS content (2s timeout) before flushing blocks, sections, and annotations synchronously
- **Annotation data loss during zoom** — guarded annotation sync in `flushAllSync()` and `flushAllPendingContent()` to prevent deleting annotations outside the zoomed section's range
- **Redundant flush on quit** — `didFlushForQuit` flag prevents `applicationWillTerminate` from re-flushing after `applicationShouldTerminate` already saved
- **Project open validates before closing** — `openProject()` and `forceOpenProject()` now validate the new project's database integrity before closing the current one, preserving the user's work if the new file is corrupt
- **Re-entrant open guard** — `hasCompletedInitialOpen` prevents macOS state restoration and SwiftUI `.task` re-fires from triggering duplicate project opens during launch

## [0.2.78] - 2026-03-13

### Changed
- **Getting Started is now a full .ff package** — replaced plain markdown template with a bundled .ff package containing a SQLite database, 27 screenshots, and embedded CSL-JSON citations. Getting Started now copies the bundled package on each open; images render via `projectmedia://` and citations resolve without Zotero.

### Fixed
- **Citekey extraction skips code blocks** — citation scanning now ignores citekeys inside code blocks and inline code

## [0.2.77] - 2026-03-12

### Fixed
- **Dragged images creating ghost sidebar sections** — WebKit's `performDragOperation` race condition inserts `<img src="blob:...">` before JS events fire, causing ProseMirror to incorporate ghost inline image nodes that serialize as spurious headings. Fix: `insertImage()` now removes ghost nodes and inserts figure node in a single ProseMirror transaction; three Swift parsers (SectionSyncService, OutlineParser, Database+Blocks) reject headings whose title is a blob/data image reference.

### Changed
- Extracted duplicated ghost image detection into `MarkdownUtils.isGhostImageMarkdown()` (was repeated across three Swift parsers)

## [0.2.76] - 2026-03-12

### Fixed
- Image block duplication regression (reverted debounce, shared timer, dedup guards)

### Changed
- Lazy markdown serialization in block-sync-plugin
- Focus mode cached DecorationSet
- Batch word counts DB method
- Code simplification (insertTrimmed reuse, BlockType enum, sumWords helper)

## [0.2.75] - 2026-03-12

### Fixed

- **Bibliography corruption from block ID proximity theft** — `assignBlockIds()` used greedy proximity matching in document order, so new paragraphs near the bibliography boundary could steal a bibliography entry's ID before the real entry claimed it. Refactored to two-phase matching: Phase 1 claims exact-position matches, Phase 2 collects all proximity candidates globally and assigns closest-first. Added `isBibliography` guard in `applyBlockChangesFromEditor` to reject editor-sync updates to machine-generated bibliography blocks. Supporting fixes: split bibliography into per-entry blocks, filter empty fragments in `assembleMarkdown`, reorder inserts before updates, cursor clamping at bibliography boundary, force-flush JS changes before DB reads, queue bibliography/notes notifications when contentState is non-idle.

### Changed

- **DebugLog category system replaces ~336 print() calls** — added `DebugLog.swift` with 14 toggleable categories (sync, editor, scheme, lifecycle, zotero, etc.). Only `.lifecycle` and `.zotero` enabled by default. Migrated all `#if DEBUG`/`print()`/`#endif` blocks to `DebugLog.log(.category, ...)` one-liners across 59 files. JS `errorHandler` bridge now routes by message type (`sync-diag` → `.sync`, others → `.editor`). Mass-delete safety guards use `DebugLog.always()` (prints in all builds). 11 previously unguarded error-path prints are now debug-only. Net reduction: ~460 lines removed.
- **Minor cleanup** — replaced `pendingIdRemap = new Map()` with `.clear()` at 4 sites; removed wasteful full-row `fetchOutlineBlocks` query in DEBUG block (only needed `.count`)

### Added

- **BlockParser alignment tests** — test coverage for `idsForProseMirrorAlignment()` list-item collapsing

## [0.2.74] - 2026-03-10

### Fixed

- **Version history empty after block migration** — `sectionSyncService.contentChanged()` was removed during the block-based architecture migration, leaving the section table empty. Re-added the call in the content change handler. Also added `syncNow()` on project load and before snapshot creation to ensure sections are always fresh.
- **Snapshots using stale content** — `SnapshotService` now assembles fresh markdown from blocks (the source of truth) instead of reading the potentially stale `content.markdown` field, for both manual and auto snapshots
- **Version history showing all sections as New** — `parseAndGetSections()` created random UUIDs for current sections, so they never matched snapshot section IDs. Replaced with `syncNow()` + `loadSections()` which fetches real DB sections with stable IDs. Also added title+headerLevel fallback matching for old snapshots that lack `snapshotSection` rows.
- **Old snapshots showing no sections** — added `fetchOrParseSnapshotSections()` fallback that parses sections from `previewMarkdown` when the `snapshotSection` table has no rows for a given snapshot
- **Version history contrast in High Contrast Day theme** — toolbar uses dark `sidebarBackground` instead of `.preferredColorScheme`; explicit `.listRowBackground` for sidebar selection highlight; column headers use full `sidebarBackground` + `sidebarText`; section hover uses universal `editorText.opacity(0.08)`
- **Coordinator stale project after window close** — `VersionHistoryCoordinator.close()` now clears `projectId` to prevent stale state on reopen

## [0.2.73] - 2026-03-08

### Fixed

- **Image sizing regression in CodeMirror** — non-resized images now display at the same size as Milkdown (fixed CSS `max-height` override that removed inline style instead of overriding the stylesheet rule); resized image widths are now preserved when switching editors (Cmd+/) and when reopening documents (fixed initialization ordering so image metadata is pushed before content)

## [0.2.72] - 2026-03-08

### Changed

- **Keyboard shortcuts cleaned up** — removed conflicting and redundant keyboard shortcuts: spelling/grammar toggles (Cmd+;), insert shortcuts (section break, highlight, footnote, task, comment, reference, image), export shortcuts (Cmd+Option+E, Cmd+Option+P), version history (Cmd+Option+V), import (Cmd+Shift+I), refresh citations (Cmd+Shift+R), and per-theme shortcuts. Fixed Find and Replace shortcut from Cmd+H to Cmd+Option+F.
- **Build script stale DerivedData cleanup** — replaced `pluginkit -r` with direct removal of stale `DerivedData/final_final-*` directories to fix duplicate QuickLook extension registrations caused by xcodegen project hash changes

### Added

- **Pre-build script for stale DerivedData cleanup** — added xcodegen pre-build phase to remove old DerivedData directories, preventing duplicate QuickLook extension registrations during Xcode builds
- **Developer ID signing and notarization** — added `CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM`, and hardened runtime to both targets in `project.yml`; build script now uses Developer ID signing with timestamp, notarization via `notarytool`, and stapling before zip creation; README updated to remove Gatekeeper workaround instructions

## [0.2.71] - 2026-03-07

### Fixed

- **Portrait images rendering smaller in CodeMirror than Milkdown** — removed orientation-based max-height logic that capped portrait images at 400px; images without explicit width now render at full container width in both editors. Added image metadata bridge from Swift to CodeMirror for width/height awareness.

## [0.2.70] - 2026-03-07

### Added

- **Document-level annotations** — annotations not anchored to markdown text (charOffset = -1), stored in the database only. Includes CRUD operations, menu commands (Edit > Add Document Note), and a collapsible "Document Notes" section in the annotation panel.
- **Annotation panel section headers** — centered headers for "Document Notes" and "Inline Notes" sections
- **Version history comparison mode** — picker to compare snapshots against current version or previous snapshot, with section-level change highlighting
- **Snapshot deduplication** — auto-backups use SHA256 content hash to skip duplicate snapshots

### Fixed

- **Version history window restoration** — fixed window not restoring on launch using `defaultLaunchBehavior` and AppDelegate cleanup; use `dismissWindow(id:)` instead of `dismiss()` for standalone Window scene
- **Version history loading flash** — prioritize loading state in view body to avoid flash of wrong content
- **Version history stale data** — fetch sections from database instead of potentially stale editorState

## [0.2.68] - 2026-03-07

### Added

- **Heading level filter** — `###` filter button in outline sidebar to toggle visibility of sub-subsection cards
- **Section highlight on hover** — hovering a sidebar card highlights the corresponding section in the editor; optimized with `highlightSection()`/`clearHighlight()` API to avoid repeated `evaluateJavaScript` overhead
- **Hover tooltip on card titles** — instant tooltip showing full section title when text is truncated, using NSFont measurement for truncation detection

### Fixed

- **#Notes scroll failure in Milkdown** — Swift's BlockParser creates separate blocks per list item, but ProseMirror merges consecutive same-type list items into single nodes, causing block ID count mismatch. Added `idsForProseMirrorAlignment()` to collapse consecutive same-type list block IDs before sending to JS.
- **Scroll to zoomed section on exit zoom** — saved `zoomedSectionId` before async `zoomOut` clears it, then scrolls after zoom-out completes; wired `onContentAcknowledged` through CodeMirrorEditor
- **CodeMirror horizontal overflow** — fixed width issues causing horizontal scrollbar in source editor
- **Tooltip z-index rendering behind next card** — moved tooltip from per-card overlay to ScrollView-level overlay to fix NSViewRepresentable z-order issue where cards drew on top of previous cards' SwiftUI overlays

## [0.2.67] - 2026-03-04

### Fixed

- **Annotation click-to-scroll drift in CodeMirror** — CodeMirror used `charOffset` from raw markdown, but `sourceContent` has section anchors (~40-46 bytes each) injected before headings, causing cumulative position drift. Switched both editors to ordinal index matching: annotation's zero-based index is looked up via each editor's own `getAnnotations()` function.
- **More/less button in annotation cards** — separate hover zone from card highlight, full-width clickable hit target instead of small centered pill, keep "less" button visible when expanded, correct SwiftUI gesture ordering (double-tap priority over single-tap), reset expansion state when annotation text changes.

### Changed

- **Annotation sidebar simplified** — rewritten `AnnotationCardView` and `AnnotationPanel` with reduced complexity (~70 lines net reduction); removed `AnnotationViewModel`.
- **Image caption prompt hidden when not hovering** — Milkdown caption prompt only appears on mouse hover, reducing visual noise.
- **Zoom into section** — section zoom now correctly loads in the editor (1-line fix enabling the feature).

## [0.2.66] - 2026-03-03

### Added

- **Scroll sync between editors** — anchor-map interpolation system (`scroll-map.ts`) walks PM nodes and markdown lines in parallel with type-dispatch matching, replacing text-matching approach that drifted on duplicate text. Uses linear interpolation for sub-line precision with floating-point `topLine`. Cached by PM doc identity.
- **Shared popup positioning utility** (`web/shared/position-popup.ts`) — viewport-aware positioning (flip above/below, horizontal clamping) extracted from annotation, citation, and link popups
- **`updateHeadingLevels()` API** — new `window.FinalFinal` method for surgical heading-level changes without full-document DB round-trips

### Fixed

- **Image width/caption lost on heading change** — hierarchy enforcement did a full-document DB round-trip that discarded figure attributes (width, blockId); replaced with surgical ProseMirror `setNodeMarkup()` for WYSIWYG, string replacement for source mode
- **Image width regression during `setContent()`** — figure attributes (width, blockId) now captured before markdown re-parse and restored after via positional matching with src verification

### Changed

- **Annotation panel font size increased** for readability
- **CursorPosition.topLine** changed from `Int` to `Double` for fractional scroll positions
- **Popup positioning consolidated** — annotation-edit, citation-edit, link-tooltip, and image-caption popups now use shared `positionPopup()` utility
- **Diagnostic logging reduced** — ~71→~20 focused logs; added `sync-debug` module for conditional JS logging

## [0.2.64] - 2026-03-02

### Added

- **CodeMirror image paste/drop handlers** — images can now be pasted or dropped into CodeMirror editor
- **Image metadata preservation** — `replaceBlocks`/`replaceBlocksInRange` now preserve image metadata through block operations
- **Sheet-modal alerts for image import errors**

### Fixed

- **5 race conditions** — continuation guard (nil-before-resume for CheckedContinuation), atomic flush (remove redundant metadata pre-read), generation counters for debounce tasks, stale poll detection via contentGeneration counter, consolidation of 6 suppression flags into centralized contentState checks
- **Image width/caption lost on editor switch** — `batchInitialize()` and `setContentWithBlockIds()` raced on the JS thread when switching CM→Milkdown; fix skips content in `performBatchInitialize()` when `isResettingContent` is true
- **Image placement: sizing, drag-and-drop, and scrolling** — remembering image size, drag-and-drop, and scroll position for images
- **`evaluateJavaScript` threading violation** — `TaskGroup.addTask` doesn't inherit `@MainActor` isolation, causing WKWebView call on cooperative pool; wrapped in `DispatchQueue.main.async`
- **WAL checkpoint self-contention** — Save As used `write {}` which opened `BEGIN IMMEDIATE`, causing SQLite error 6; switched to `writeWithoutTransaction` + passive checkpoint
- **Main Thread Checker violation** — same root cause as threading fix above

### Changed

- **Debug logging cleanup** — wrapped ~189 `print()` statements in `#if DEBUG` guards across 40 Swift files; removed verbose loop/iteration prints; cleaned up `console.log` in find-replace.ts
- **Removed color header log spam**

## [0.2.63] - 2026-03-01

### Added

- **Save As** — File > Save As... copies the current `.ff` project to a new location; uses PASSIVE WAL checkpoint to avoid database lock errors; updates the project title in the copied database to match the new filename

## [0.2.62] - 2026-03-01

### Added

- **Markdown with Images export** — exports `.md` file + `<name>_images/` folder with copied images
- **TextBundle export** — exports `.textbundle` package (`text.md` + `assets/` + `info.json`) with standard markdown (no Pandoc attributes)
- **DOCX/ODT heading numbering** — `native_numbering` Pandoc extension for Word/LibreOffice exports

### Fixed

- **Export Preferences menu** — replaced private `showSettingsWindow:` selector with `@Environment(\.openSettings)`; added `NSApp.activate()` for fullscreen focus; PreferencesView now switches to Export tab on notification
- **PDF image handling** — unsupported formats (WebP, HEIC, GIF, TIFF, SVG) are now auto-converted to PNG for xelatex; Pandoc receives `--resource-path` for correct `media/` image resolution
- **PDF image alt text** — uses `fig-alt` attribute instead of caption comments

### Changed

- Registered `org.textbundle.package` UTType

## [0.2.61] - 2026-03-01

### Added

- **Image support with paste/drop import** — paste or drag images into either editor; copies to `media/` directory inside `.ff` project package; inserts standard markdown image syntax. Includes `/image` slash command and toolbar button.
- **Inline image previews** — both Milkdown and CodeMirror render previews below image markdown lines using `projectmedia://` custom URL scheme (MediaSchemeHandler)
- **Image caption editing popup** — click-to-edit caption popup in CodeMirror for image captions

### Fixed

- **CodeMirror caption lookup** — captions were never found because `buildDecorations()` only checked the immediately preceding line (always blank). Added backward scan (up to 3 lines, skipping blanks) to find caption comments.
- **Image caption contrast** — changed captions from `--editor-muted` to `--editor-text` in both editors; captions are user content, not UI chrome
- **CodeMirror inline styles** — moved static inline styles from `image-preview-plugin.ts` to CSS classes in `styles.css`
- **Caption duplication on roundtrips** — BlockParser now keeps `<!-- caption: -->` comments attached to following image lines in `splitIntoRawBlocks`, preventing remark-stringify blank-line insertion from splitting them into separate blocks
- **CodeMirror blank display** — block decorations (image previews) use StateField instead of ViewPlugin; CM6 throws RangeError otherwise

### Changed

- Removed diagnostic logging from image-preview-plugin

## [0.2.60] - 2026-02-28

### Fixed

- **Content loss on project switch/close/quit** — editor content polled every 2s by BlockSyncService was silently discarded when `stopPolling()` was called during project transitions. Added `flushAllPendingContent()` that fetches fresh content from the WebView, writes blocks to the database, and flushes section/annotation metadata before any lifecycle transition (project switch, close, and app quit).

## [0.2.59] - 2026-02-27

### Added

- **PDF export with citation support** — uses Pandoc `--citeproc` with bibliography fetched from Zotero/BBT in CSL-JSON format; bundles Chicago Author-Date citation style (`chicago-author-date.csl`)
- **Multilingual PDF font support** — automatic script detection (CJK, Devanagari, Thai, Bengali, Tamil) with appropriate font mapping; NLLanguageRecognizer disambiguates Simplified vs Traditional Chinese

### Fixed

- **Typing latency** — replaced polling-based editor↔database sync with push-based sync, switched to DatabasePool, improved spellcheck position mapping
- **Citations in PDF export** — PDF format now uses `--citeproc` pipeline instead of Lua filter, resolving broken citation rendering
- **Drag-and-drop reordering** — removed lower limit on heading levels, allowing sections of any depth to be reordered

### Changed

- **ExportService refactored** — extracted helpers (`pdfEngineArguments`, `citationArguments`, `zoteroWarnings`, `fontArguments`) to reduce cyclomatic complexity

## [0.2.58] - 2026-02-27

### Fixed

- **QuickLook extension not loading** — added `QLSupportsSecureCoding` to Info.plist, security-scoped resource access, `pluginkit` registration in build script, and fallback plain-text rendering if AppKit conversion fails
- **Build script signing** — replaced `codesign --deep` with inside-out signing (extension first with sandbox entitlements, then main app), added signature verification step

### Changed

- **Dark theme colors** — Night Owl: golden amber accents, darker orange body text (#BD6B15), white headers. Frost: bright cyan accents (#00C8FF), light cyan body text, medium blue headers (#4C98CA)
- **Separate header color** — added `editorHeaderText` property to theme system, with corresponding `--editor-heading-text` CSS variable

### Added

- **Zotero connectivity alert** — shows an alert (with 60-second cooldown) when Zotero isn't running, both during citation search and lazy citekey resolution

## [0.2.55] - 2026-02-27

### Added

- **Quick Look extension** — preview .ff files directly in Finder without opening the app. Renders the project title and markdown content with styled headers, code blocks, block quotes, and lists. Reads the SQLite database in read-only immutable mode. Strips annotations and footnotes from preview.
- **Update checker** — Help → Check for Updates queries the GitHub Releases API and shows an alert if a newer version is available, with a direct download link
- **Annotation edit popup** — click an annotation in WYSIWYG mode to open a popup with a textarea for editing. Supports multi-line text (Shift+Enter), Enter to save, Escape to cancel. Task annotations have a clickable icon to toggle completion state.
- **Report an Issue** menu item in Help menu linking to GitHub Issues

### Changed

- Annotations are now atomic ProseMirror nodes (text stored as attribute, no longer editable inline). Editing happens through the new popup.

## [0.2.54] - 2026-02-26

### Added

- **Configurable Focus Mode** — new Preferences → Focus tab with 5 toggles (hide outline sidebar, hide annotation panel, hide toolbar, hide status bar, paragraph highlighting). Settings persist in UserDefaults and are snapshot-at-entry, so focus mode only affects the elements you choose.

### Improved

- Footnote definitions (`[^N]:`) render as styled pills in WYSIWYG mode with click-to-navigate-back and tooltip fade transitions
- Status bar shows the current section name; clicking it opens a section navigation popup
- Slash menu filtering in both editors now matches label prefixes only, preventing false matches

### Fixed

- CodeMirror slash menu positioning uses `requestMeasure` instead of direct `coordsAtPos`, preventing layout glitches
- Status bar section popup display corrected
- Caret now renders properly after scrolling to a footnote definition

## [0.2.52] - 2026-02-24

### Added

- GitHub Releases publishing workflow with versioned zip downloads
- CHANGELOG.md in Keep a Changelog format
- AGPL-3.0 license

### Changed

- Renamed KARMA.md to KUDOS.md
- README.md updated for GitHub (installation links to Releases, roadmap cleaned up)
- Build script refactored: removes iCloud distribution, outputs versioned zip to build/
- Getting-started guide decoupled from README (now maintained independently)

### Fixed

- Removed hardcoded local paths from test files and build scripts

## [0.2.49]

### Fixed

- Fullscreen launch bug fixed

## [0.2.48]

### Changed

- Cleaned up menus

## [0.2.47]

### Added

- Toolbars, status bars, pop-up menus, and other UI niceties

## [0.2.43]

### Added

- Footnotes

## [0.2.42]

### Fixed

- Improved grammar and spell check, skipping annotations, citations, and non-latin script
