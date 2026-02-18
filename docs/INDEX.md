# Documentation Index

Hub-and-spoke documentation for Final Final. Each linked file is a focused document under ~300 lines. Start here, drill into the spoke you need.

---

## Architecture

How the app is built. Read these before modifying core systems.

- [overview.md](architecture/overview.md) -- Technology stack, component diagram, data flow, UI layout
- [block-system.md](architecture/block-system.md) -- Block model, sync service, editor-to-database pipeline, zoom via blocks
- [data-model.md](architecture/data-model.md) -- GRDB schema, project package structure, content model
- [editor-communication.md](architecture/editor-communication.md) -- WebView bridge API, source mode, SectionSyncService, find bar, bibliography
- [state-machine.md](architecture/state-machine.md) -- Content state enum, zoom in/out, hierarchy constraints, ValueObservation, drag-drop reordering
- [word-count.md](architecture/word-count.md) -- Per-section calculation, document totals, goal colors, zoom-mode updates

## Roadmap

- [roadmap.md](roadmap.md) -- Phase 1 verification checklist, Phase 0.2 stabilization plan, future phases, design decisions

## Guides

How-to documents for development tasks.

- [running-tests.md](guides/running-tests.md) -- Unit and UI test commands, prerequisites, practical workflow
- [testing-architecture.md](guides/testing-architecture.md) -- Test targets, fixture system, test mode detection, known issues
- [hooks.md](guides/hooks.md) -- Git hooks and Claude Code hooks configuration

## Lessons Learned

Patterns and pitfalls discovered during development. Consult before writing related code.

- [prosemirror-milkdown.md](lessons/prosemirror-milkdown.md) -- Decoration system, wrapper elements, HTML filtering, slash menu, empty content
- [codemirror.md](lessons/codemirror.md) -- ATX heading column-0 requirement, keymap vs DOM handler precedence
- [swiftui-webkit.md](lessons/swiftui-webkit.md) -- AppDelegate pattern, event handling, print() performance, data flow IDs, compositor caching
- [grdb-database.md](lessons/grdb-database.md) -- ValueObservation races, dual content properties, eraseDatabaseOnSchemaChange danger
- [zoom-patterns.md](lessons/zoom-patterns.md) -- Async coordination, state protection, database-as-truth, bibliography sync, dual editor mode
- [block-sync-patterns.md](lessons/block-sync-patterns.md) -- Pseudo-section document-order ownership, sidebar zoom ID sharing
- [misc-patterns.md](lessons/misc-patterns.md) -- JavaScript shift-key, cursor offset mapping, Vite emptyOutDir, XeTeX path spaces

## Findings

Bug investigation reports with root cause analysis and solutions.

- [bibliography-block-migration.md](findings/bibliography-block-migration.md) -- Bibliography rendering + zoom word count bugs after block migration
- [project-switch-css-layout.md](findings/project-switch-css-layout.md) -- CSS layout breaks on project switch (compositor caching)
- [project-switch-source-mode.md](findings/project-switch-source-mode.md) -- CodeMirror stale content and blank screen on project switch
- [sidebar-cm-zoom.md](findings/sidebar-cm-zoom.md) -- Sidebar disappears when zooming in CodeMirror mode
- [cursor-mapping-postmortem.md](findings/cursor-mapping-postmortem.md) -- Precise table cursor mapping (abandoned) + escaped asterisks (deferred)
- [zoom-cm-section-creation-corruption.md](findings/zoom-cm-section-creation-corruption.md) -- Zoom + CodeMirror heading creation causes content duplication (feedback loop, range shrinkage, sourceContent desync)
- [delete-all-content-reappears.md](findings/delete-all-content-reappears.md) -- Cmd+A Delete content reappears due to empty-content guard and mass delete safety net
- [sidebar-stale-after-content-state-transition.md](findings/sidebar-stale-after-content-state-transition.md) -- Sidebar not updating after bibliography/mode-switch changes (ValueObservation dropped during non-idle contentState)
- [stale-package-on-replace.md](findings/stale-package-on-replace.md) -- NSSavePanel "Replace" leaves old .ff package data intact (directory-based packages not deleted)
- [cm-scroll-height-contamination.md](findings/cm-scroll-height-contamination.md) -- CodeMirror measureTextSize() returns heading-contaminated lineHeight and charWidth, causing massive off-screen height overestimation
- [cm-scroll-stabilizer.md](findings/cm-scroll-stabilizer.md) -- Persistent blank gaps after rapid scrolling due to height map drift; fixed with adaptive post-scroll requestMeasure() cycles

## Deferred

Features and fixes tracked for future work.

- [block-sync-robustness.md](deferred/block-sync-robustness.md) -- Float precision, mass delete safety, sync timing issues
- [contentstate-guard-rework.md](deferred/contentstate-guard-rework.md) -- Alternative approaches to the contentState guard pattern
- [per-citation-author-suppression.md](deferred/per-citation-author-suppression.md) -- Per-citation author suppression bug fix plan
- [section-break-cleanup-after-delete-all.md](deferred/section-break-cleanup-after-delete-all.md) -- § placeholder appears after delete-all (ProseMirror default block type)
- [tagging-keyboard-nav.md](deferred/tagging-keyboard-nav.md) -- Tag input enhancement and sidebar keyboard navigation

## Plans

Immutable plan files (versioned with -v02, -v03 suffixes). See CLAUDE.md for plan file conventions.
