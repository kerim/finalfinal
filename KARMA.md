# KARMA.md

Attribution for code, libraries, and inspiration used in final final.

**Last updated:** 2026-01-29 (Phase 1.8 Zotero Citations)

---

## Bundled Dependencies

### Swift (via Swift Package Manager)

| Package | Version | License | Author | URL |
|---------|---------|---------|--------|-----|
| GRDB.swift | 7.0.0 | MIT | Gwendal Roué | https://github.com/groue/GRDB.swift |

### TypeScript/JavaScript (via pnpm, bundled in app)

#### Milkdown Editor

| Package | Version | License | Author | URL |
|---------|---------|---------|--------|-----|
| @milkdown/kit | ^7.8.0 | MIT | Mirone | https://github.com/Milkdown/milkdown |
| @milkdown/components | ^7.8.0 | MIT | Mirone | https://github.com/Milkdown/milkdown |
| @milkdown/plugin-slash | ^7.8.0 | MIT | Mirone | https://github.com/Milkdown/milkdown |
| citeproc | ^2.4.63 | CPAL/AGPLv3 | Frank Bennett | https://github.com/Juris-M/citeproc-js |
| fuse.js | ^7.0.0 | Apache 2.0 | Kiro Risk | https://github.com/krisk/Fuse |
| unist-util-visit | ^5.0.0 | MIT | Titus Wormer | https://github.com/syntax-tree/unist-util-visit |

#### CodeMirror Editor

| Package | Version | License | Author | URL |
|---------|---------|---------|--------|-----|
| codemirror | ^6.0.1 | MIT | Marijn Haverbeke | https://codemirror.net/ |
| @codemirror/commands | ^6.5.0 | MIT | Marijn Haverbeke | https://codemirror.net/ |
| @codemirror/lang-markdown | ^6.2.0 | MIT | Marijn Haverbeke | https://codemirror.net/ |
| @codemirror/language | ^6.10.0 | MIT | Marijn Haverbeke | https://codemirror.net/ |
| @codemirror/language-data | ^6.4.0 | MIT | Marijn Haverbeke | https://codemirror.net/ |
| @codemirror/state | ^6.4.0 | MIT | Marijn Haverbeke | https://codemirror.net/ |
| @codemirror/view | ^6.25.0 | MIT | Marijn Haverbeke | https://codemirror.net/ |
| @codemirror/autocomplete | ^6.20.0 | MIT | Marijn Haverbeke | https://codemirror.net/ |

#### Transitive Dependencies (bundled via Milkdown)

| Package | License | Author | Purpose |
|---------|---------|--------|---------|
| ProseMirror | MIT | Marijn Haverbeke | Rich text editing framework |
| remark | MIT | Titus Wormer | Markdown parsing/serialization |
| unified | MIT | Titus Wormer | Text processing pipeline |

#### CSL Resources (bundled in app)

| Resource | License | Author | URL |
|----------|---------|--------|-----|
| chicago-author-date.csl | CC BY-SA 3.0 | Andrew Dunning | https://github.com/citation-style-language/styles |
| locales-en-US.xml | CC BY-SA 3.0 | CSL Team | https://github.com/citation-style-language/locales |

---

## Build Tools (Development Only, Not Bundled)

| Tool | Version | License | URL |
|------|---------|---------|-----|
| Vite | ^5.0.0 | MIT | https://vitejs.dev/ |
| TypeScript | ^5.3.0 | Apache 2.0 | https://www.typescriptlang.org/ |
| XcodeGen | - | MIT | https://github.com/yonaskolb/XcodeGen |
| pnpm | - | MIT | https://pnpm.io/ |

---

## Inspiration & Design References

### Applications

| Application | Influence |
|-------------|-----------|
| **Obsidian** | Markdown-first philosophy, plugin architecture concepts |
| **Zettlr** | Academic writing focus, Pandoc integration approach |
| **Logseq** | Outline-based document structure, block-level organization |

### Obsidian Plugins

| Plugin | Author | Influence | URL |
|--------|--------|-----------|-----|
| obsidian-pandoc-reference-list | Matthew Meyers | Reference list UI patterns | https://github.com/mgmeyers/obsidian-pandoc-reference-list |
| obsidian-enhanced-annotations | ycnmhd | Annotation system design (inline/collapsed modes, annotation panel) | https://github.com/ycnmhd/obsidian-enhanced-annotations |

---

## License Texts

### MIT License (GRDB, Milkdown, CodeMirror, ProseMirror, Vite)

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Apache License 2.0 (TypeScript)

TypeScript is licensed under the Apache License, Version 2.0.
See: http://www.apache.org/licenses/LICENSE-2.0

---

## Changelog

| Date | Phase | Changes |
|------|-------|---------|
| 2026-01-29 | 1.8 | Added citeproc-js, fuse.js, CSL style/locale files for Zotero citation integration |
| 2026-01-29 | 1.7 | Initial KARMA.md created; documented all bundled dependencies and inspiration sources |
