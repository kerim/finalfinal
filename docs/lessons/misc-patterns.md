# Miscellaneous Patterns

Patterns for JavaScript, cursor mapping, build system, and PDF export. Consult before working in these areas.

---

## JavaScript

### Keyboard Shortcuts with Shift

`e.key` returns uppercase when Shift held. Always normalize:

```typescript
if (e.key.toLowerCase() === 'e') { ... }
```

---

## Cursor Position Mapping (Milkdown <-> CodeMirror)

### ProseMirror textBetween() Returns Plain Text

`doc.textBetween()` strips all markdown syntax (`**`, `*`, `` ` ``, etc.). Searching for this plain text in markdown source will fail because the markdown contains the syntax characters.

**Wrong approach (text anchor):**
```typescript
const textBefore = doc.textBetween(start, head, '\n');
markdown.indexOf(textBefore); // Fails - textBefore has no syntax
```

**Right approach (line matching + offset mapping):**
1. Match paragraph text content to markdown lines (strip syntax from both sides)
2. Use bidirectional offset mapping that accounts for inline syntax length

### Bidirectional Offset Mapping Required

Converting cursor positions between WYSIWYG and source requires accounting for inline syntax:

| Markdown | Text Length | Markdown Length |
|----------|-------------|-----------------|
| `**bold**` | 4 ("bold") | 8 |
| `*italic*` | 6 ("italic") | 8 |
| `` `code` `` | 4 ("code") | 6 |
| `[link](url)` | 4 ("link") | 12 |

Functions needed:
- `textToMdOffset(mdLine, textOffset)` -- ProseMirror -> CodeMirror
- `mdToTextOffset(mdLine, mdOffset)` -- CodeMirror -> ProseMirror

### Line-Start Syntax Must Be Handled Separately

Headers, lists, and blockquotes have line-start syntax that affects column calculation:

```typescript
const syntaxMatch = line.match(/^(#+\s*|\s*[-*+]\s*|\s*\d+\.\s*|\s*>\s*)/);
const syntaxLength = syntaxMatch ? syntaxMatch[0].length : 0;
const contentAfterSyntax = line.slice(syntaxLength);
```

Apply offset mapping only to content after syntax, then add syntax length back.

---

## Build

### Vite emptyOutDir: false

Changes to source `index.html` won't sync to output. Either manually sync or set `emptyOutDir: true`.

---

## XeTeX / PDF Export

### Use -output-driver for Paths with Spaces

**Problem:** When the app bundle path contains spaces (e.g., "final final.app"), xelatex fails with error 32512 when calling xdvipdfmx:

```
sh: /Users/.../Build/Products/Debug/final: No such file or directory
```

**Root Cause:** XeTeX internally calls xdvipdfmx via shell without quoting the path. The shell interprets the space as an argument separator:

```
# What xelatex runs internally:
/path/to/final final.app/.../xdvipdfmx args

# Shell interprets as:
Command: /path/to/final
Arg 1: final.app/.../xdvipdfmx
Arg 2: args
```

**What doesn't work:**
- Setting `XDVIPDFMX` environment variable (xelatex ignores it)
- Setting `SELFAUTOLOC` and other kpathsea variables (only affects package resolution)
- Putting wrapper scripts in PATH (xelatex uses absolute path, not PATH lookup)
- Copying binaries to temp directory (breaks TeX package resolution)

**Solution:** Use XeTeX's documented `-output-driver` command-line option to specify the XDV-to-PDF driver command:

```swift
// 1. Create symlink to TinyTeX at space-free path (for package resolution)
let symlinkURL = tempDir.appendingPathComponent("TinyTeX")
try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: bundledTinyTeXURL)

// 2. Create xdvipdfmx wrapper script at space-free path
let wrapperScript = """
    #!/bin/bash
    exec "\(tinyTeXBin)/xdvipdfmx" "$@"
    """
try wrapperScript.write(to: wrapperURL, atomically: true, encoding: .utf8)

// 3. Pass to xelatex via -output-driver option (through Pandoc)
arguments.append(contentsOf: ["--pdf-engine", xelatexPath])
arguments.append(contentsOf: ["--pdf-engine-opt", "-output-driver=\(wrapperURL.path)"])
```

**Reference:** [XeTeX Reference Guide](https://mirrors.mit.edu/CTAN/info/xetexref/xetex-reference.pdf) -- the `-output-driver=CMD` option "use CMD as the XDV-to-PDF driver instead of xdvipdfmx"

**General principle:** When bundling TeX in macOS apps, avoid spaces in the app name. If unavoidable, use `-output-driver` to redirect xdvipdfmx calls through a wrapper script at a space-free path.
