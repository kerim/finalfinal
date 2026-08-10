-- Escapes the TeX-special characters `&`, `#`, and `%` inside math spans (both
-- inline `$...$` and display `$$...$$`), unless the math body contains `\begin{`,
-- `\def`, `\newcommand`, or `\renewcommand` -- see "Known limitation" below.
--
-- Why this exists: pandoc's markdown reader treats the content of a math span as
-- opaque LaTeX and copies it through to the LaTeX writer verbatim -- by design, since
-- pandoc has no way to know what any macro inside math actually expands to. `&`, `#`,
-- and `%` are TeX-special characters (alignment tab, macro-parameter marker, and
-- comment-start respectively). Confirmed by direct reproduction against this app's
-- real bundled pandoc + xelatex:
--   * An unescaped `&` in ordinary math (e.g. `$x & y$`) crashes pandoc outright --
--     exit 43, xelatex reporting "Misplaced alignment tab character &".
--   * An unescaped `#` crashes the same way -- "You can't use `macro parameter
--     character #' in math mode."
--   * An unescaped `%` does NOT crash: pandoc's own LaTeX writer already inserts a
--     newline immediately after `%` in its output, which stops it from commenting out
--     the rest of the compiled .tex file -- but everything between the `%` and that
--     inserted newline (i.e. the rest of the math span's source line) is silently
--     dropped from the rendered PDF instead. Silent data loss rather than a visible
--     crash, but still worth fixing the same way.
-- `$$\begin{aligned} a &= b \end{aligned}$$`-style alignment environments legitimately
-- rely on unescaped `&`, so those must be left alone -- see the exemption below.
--
-- Known limitation: the \begin{/\def/\newcommand/\renewcommand exemption is a plain
-- substring check against the WHOLE math node's text, not a real parse of its LaTeX.
-- It exists only so a legitimate alignment environment keeps its unescaped `&`
-- working. It is not exhaustive or safe in every case: escaping is skipped for the
-- ENTIRE node once any exemption keyword matches anywhere in it -- not just within the
-- construct that actually needs the exemption -- so a stray, unrelated character
-- elsewhere in that same exempted node is not protected either. The consequence
-- depends on which character it is: a stray `&` or `#` reproduces the EXACT SAME crash
-- this whole filter exists to prevent (confirmed by direct reproduction: e.g.
-- `$$\begin{gathered} x & y \end{gathered}$$` is exempted because it contains
-- `\begin{`, but the `gathered` environment doesn't actually take alignment tabs, so
-- it still crashes -- exit 43, "Extra alignment tab has been changed to \cr" in this
-- particular environment (the exact xelatex error text varies by which environment
-- rejects the tab; the failure category -- a hard crash -- does not) -- exactly as an
-- unexempted node would fail. Only a stray `%` degrades to the quieter silent-
-- truncation failure described above, since that is what an unescaped `%` does
-- everywhere, exempt node or not.
local EXEMPT_PATTERNS = { "\\begin{", "\\def", "\\newcommand", "\\renewcommand" }

local function isExempt(text)
  for _, pattern in ipairs(EXEMPT_PATTERNS) do
    if text:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

-- True if the character at byte offset `pos` in `text` is already escaped -- i.e.
-- preceded by an ODD number of consecutive backslashes. `\&` is escaped; `\\&` is not
-- (the doubled backslash is itself an escaped backslash, so `&` stands alone as a
-- plain alignment tab -- relevant since `\\` is also LaTeX's line-break command, and a
-- naive single-character lookbehind would misread the character right after it as
-- already escaped).
local function isAlreadyEscaped(text, pos)
  local backslashes = 0
  local i = pos - 1
  while i >= 1 and text:sub(i, i) == "\\" do
    backslashes = backslashes + 1
    i = i - 1
  end
  return backslashes % 2 == 1
end

local function escapeSpecialChars(text)
  local result = {}
  local changed = false
  for i = 1, #text do
    local ch = text:sub(i, i)
    if (ch == "&" or ch == "#" or ch == "%") and not isAlreadyEscaped(text, i) then
      result[#result + 1] = "\\" .. ch
      changed = true
    else
      result[#result + 1] = ch
    end
  end
  if not changed then
    return nil
  end
  return table.concat(result)
end

function Math(el)
  if isExempt(el.text) then
    return nil
  end
  local escaped = escapeSpecialChars(el.text)
  if escaped == nil then
    return nil
  end
  el.text = escaped
  return el
end
