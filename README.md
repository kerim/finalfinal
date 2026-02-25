# Welcome to FINAL|FINAL!

I built [FINAL|FINAL](https://finalfinalapp.cc/) out of years of frustration with existing writing tools for academics. Some tools out there had one or more of these features, but no app had all of them:

1. An clear **outline** of the document which allows you to re-organize sections or zoom in on them.
2. Built-in support for **citations** and **bibliographies** with Zotero, including the ability to export to Word with “live” Zotero markers so you can continue to prepare the final manuscript for publication there.
3. **Versioning** that has both automatic updates and the ability to save named versions of the document at any time, and which allows you to easily restore all or part of the ducument from any backup.
4. **WYSIWYG editing** without the surprises that you get when working in Word. In FINAL|FINAL you can switch seemlessly between formatted text or **raw markdown** without loosing your place, or giving up any features.
5. **Tasks** and **annotations** that can appear inline, as pop-ups, or completely hidden from the main document, and which can always be accessed from a dedicated sidebar.
6. **Status markers**, **word counts**, and **writing goals** to easily track what still needs to be done.
7. A **focus mode** that let’s you hide all distractions other than the paragraph you are working on.
8. Easy **theming** so you can customize every aspect of how it looks to suit your personal preferences.

FINAL|FINAL was built for academics, but it should be just as useful for longform fiction projects, screenplays, or technical documentation, any project where you need to keep track of your context while you focus on what you write.

# Installation

1. Download the latest zip from [GitHub Releases](https://github.com/kerim/finalfinal/releases/latest)
2. Unzip to extract `final final.app`
3. Move the app to `/Applications` (optional)
4. **First launch:** Right-click → Open (not double-click) to bypass Gatekeeper, or run:
   ```bash
   xattr -cr "final final.app"
   ```

The app isn't notarized, so macOS will warn about an unidentified developer.

# Alpha Software

Although most of the core features (listed above) are already implemented, [FINAL|FINAL](https://finalfinalapp.cc/) is still alpha software and should be used with caution.


# Roadmap

## Known bugs

- PDF export doesn't format in-text citations

# Set-up

[FINAL|FINAL](https://finalfinalapp.cc/) works fine out-of-the-box, but there are a couple of features that require external tools, and they require some setup. 

## Zotero

The citation management plugin works with [Zotero](https://www.zotero.org/), a free open-source project used by thousands of people. You need to have this installed ***and running***, for citation functions to work with [FINAL|FINAL](https://finalfinalapp.cc/).

## Better BibTeX

[Better BibTeX](https://retorque.re/zotero-better-bibtex/) is a Zotero plugin that allows [FINAL|FINAL](https://finalfinalapp.cc/) to talk with Zotero and also for [FINAL|FINAL](https://finalfinalapp.cc/) documents to talk with the engine that lets you export to Word or PDF. 

Better BibTeX requires some setup:

* In the main Zotero settings, under `Advanced`, check `Allow other applications on this computer to communicate with Zotero`.

* **Zotero 7 only:** In the Better BibTeX section of your Zotero settings, ensure that `Automatically pin citation key after X seconds` is set to `1`. This is not needed in Zotero 8, where citation keys are pinned automatically.

* Restart Zotero after installing Better BibTeX.

## Pandoc

[Pandoc](https://pandoc.org/), another popular free, open source project, is required for the advanced export functions. (Plain markdown exort works just fine without it.) 

There is a package installer at pandoc’s [download page](https://github.com/jgm/pandoc/releases/latest). If you later want to uninstall the package, you can do so by downloading [this script](https://raw.githubusercontent.com/jgm/pandoc/main/macos/uninstall-pandoc.pl) and running it with `perl uninstall-pandoc.pl`.

Alternatively, you can install pandoc using [Homebrew](https://brew.sh/):

```
 brew install pandoc
```

## Language Tool Premium

Grammar checking can use the free version of Language Tool out-of-the box, but if you want enhanced grammar checking you need to sign up for [the premium version](https://languagetool.org/premium) and get an API key.

# Using FINAL|FINAL

1. **Create a project** — Use File → New Project to start writing
2. **Start typing** — Your work saves automatically to the project
3. **Organize with headings** — Use # for H1, ## for H2, and so on
4. **Navigate** — Click sections in the sidebar to jump to them

## Key Features

### Outline view

Each heading becomes a section in the sidebar. Use # for H1, ## for H2, and so on. Or use the `/` command while typing to change a header, or drag-and-drop the sections in the sidebar to reorganize your document.

You can double-click a section to zoom in, or click once to jump to that section.

Right-click sections to:

* Set a **status** (Next, Writing, Waiting, Review, Final)

* Add **word goals** with progress tracking. Can set minimum, maximum, or approximate (+/- %5) goals. 

### Source View

Press **⌘/** to toggle between WYSIWYG and source view. Source mode shows raw markdown for precise editing.

### Citations

Use `/cite` to enter a citation from Zotero. A bibliography section will be created automatically. 

### Annotations

Use `/task`, `/comment`, or `/reference` to add annotations. Tasks have check boxes that can be checked-off. To avoid surprises everything shows inline to begin with, but I recommend setting comments and references to “collapsed” via the “eye” menu in the top right corner of the annotations panel. This will still show them with a pop-up tool tip.

### Focus Mode

Press **⌘⇧F** to dim everything except the paragraph you're editing. This helps maintain flow during longer writing sessions.

### Version History

Press **⌘⇧S** to save a named version. Access all versions with **⌘⌥V** (or the “Version History” menu option, to compare or restore previous drafts. 

### Styling

Open the preferences to change the fonts, colors, and paragraph spacing. You can save your favorite configuration for re-use.

### Footnotes

Use `/footnote` to insert a footnote. Footnotes appear at the end of the document and are numbered automatically.

### Grammar & Spell Check

Built-in spell check works out of the box. For enhanced grammar and style checking, connect to [LanguageTool](https://languagetool.org/) (free or premium) in the preferences.

### Toolbars

A selection toolbar appears when you highlight text, and the Format menu provides quick access to formatting options. The status bar at the bottom shows word count and document statistics.

### Export

Export your work to Markdown, Word (.docx), or PDF. Word export preserves Zotero citation markers for further editing. Advanced export requires [Pandoc](https://pandoc.org/).

## Giving Feedback

We'd love to hear from you! 

Feedback or bug reports can be submitted to the project's [github issues page](https://github.com/kerim/finalfinal/issues). 

## Project Homepage

https://finalfinalapp.cc/

## Credits

[FINAL|FINAL](https://finalfinalapp.cc/) was built by [P. Kerim Friedman](https://kerim.one/) with the help of [Claude Code](https://claude.ai/), and inspiration from a number of open source projects.

