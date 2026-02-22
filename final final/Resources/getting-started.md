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

# Alpha Software

Although most of the core features (listed above) are already implemented, [FINAL|FINAL](https://finalfinalapp.cc/) is still alpha software and should be used with caution.

Also, a lot of things you would expect from a word processor aren't there yet: toolbars, keyboard shortcuts, spell checking, find-and-replace, etc. The idea was to focus on the things that make FINAL|FINAL unique first, and make sure that the underlying architecture is sound, before adding such nicities. 

# What's New

## Version 0.2.43

- New feature: Footnotes!

## Version 0.2.42

- Improved grammar and spell check, skipping annotations, citations, and non-latin script.

## Version 0.2.41

- Fixed pasting markdown
- Fixed /cite remaining after cancelled citation lookup
- Added warning when Zotero isn't running
- Added support for pasting and editing URLs
- Fixed Zooming in for sections
- NEW FEATURE: Spelling and grammar check (grammar check uses Language Tool, free or premium)

## Version 0.2.40

- Fixed option-zoom bug and drag-and-drop bug

## Version 0.2.39

- Fixed situations where markdown scrolling could still break.

# Roadmap

## Planned Features

- Editing Toolbar
- Footnotes

## Known bugs

- PDF export doesn't format in-text citations

# Set-up

[FINAL|FINAL](https://finalfinalapp.cc/) works fine out-of-the-box, but there are a couple of features that require external tools, and they require some setup. 

## Zotero

The citation management plugin works with [Zotero](https://www.zotero.org/), a free open-source project used by thousands of people. You need to have this installed ***and running***, for citation functions to work with [FINAL|FINAL](https://finalfinalapp.cc/).

## Better BibTeX

[Better BibTeX](https://retorque.re/zotero-better-bibtex/) is a Zotero plugin that allows [FINAL|FINAL](https://finalfinalapp.cc/) to talk with Zotero and also for [FINAL|FINAL](https://finalfinalapp.cc/) documents to talk with the engine that lets you export to Word or PDF. 

Better BibTeX requires some setup to work right:

* In the Main Zotero settings, under `Advanced`, check `Allow other applications on this computer to communicate with Zotero`.

* In the Better Bibtex section of your Zotero settings, ensure that `Automatically pin citation key after X seconds` is set to `1`. 

* Note: Citation keys need to be **both** set up and pinned in Zotero 8.

* UPDATE: I think pinning citations keys is no longer necessary in Zotero 8! Need to double-check.

* Restart Zotero.

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

Each heading becomes a section in the sidebar. Use # for H1, ## for H2, and so on. Or use the `/` command while typing to change a header, or drag-and-drop the sections in the sidebar to reorganize your document.

You can double-click a section to zoom in, or click once to jump to that section.

&#x20;Right-click sections to:

* Set a **status** (Next, Writing, Waiting, Review, Final)

* Add **word goals** with progress tracking. Can set minimum, maximum, or approximate (+/- %5) goals. 

### Source View

Press **⌘/** to toggle between WYSIWYG and source view. Source mode shows raw markdown for precise editing.

### Ciations

Use `/cite` to enter a citation from Zotero. A bibliography section will be created automatically. 

### Annotations

Use `/task`, `/comment`, or `/reference` to add annotations. Tasks have check boxes that can be checked-off. To avoid surprises everything shows inline to begin with, but I recommend setting comments and referencees to “collapsed” via the “eye” menu in the top right corner of the annotations panel. This wll still show them with a pop-up tool tip.

### Focus Mode

Press **⌘⇧F** to dim everything except the paragraph you're editing. This helps maintain flow during longer writing sessions.

### Version History

Press **⌘⇧S** to save a named version. Access all versions with **⌘⌥V** (or the “Version History” menu option, to compare or restore previous drafts. 

### Styling

Open the preferences to change the fonts, colors, and paragraph spacing. You can save your favorite configuration for re-use.

## Keyboard Shortcuts

| Action             | Shortcut |
| ------------------ | -------- |
| New Project        | ⌘N       |
| Open Project       | ⌘O       |
| Save               | ⌘S       |
| Save Version       | ⌘⇧S      |
| Version History    | ⌘⌥V      |
| Toggle Source View | ⌘/       |
| Toggle Focus Mode  | ⌘⇧F      |
| Export Markdown    | ⌘⇧E      |
| Import Markdown    | ⌘⇧I      |

## Slash Commands

Type `/` in the editor to access quick commands:

* `/h1` through `/h3 `— Insert headings

* `/break` — Insert a section break (this feature needs work - designed to break up long sections without affecting the outline).

* `/cite` — Insert or edit citations (requires Zotero + BBT)

* Use `/task`, `/comment`, or `/reference` to add annotations.

## Giving Feedback

We'd love to hear from you! 

Feedback or bug reports can be submitted to the project's [github issues page](https://github.com/kerim/finalfinal/issues). 

## Project Homepage

https://finalfinalapp.cc/

## Credits

[FINAL|FINAL](https://finalfinalapp.cc/) was built by [P. Kerim Friedman](https://kerim.one/) with the help of [Claude Code](https://claude.ai/), and inspiration from a number of open source projects.

***

*This is the Getting Started guide. Your changes won't be saved here — create a new project to start your own work.*
