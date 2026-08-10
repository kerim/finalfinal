-- Converts any bare URL-shaped Str inline anywhere in the document into a
-- real Link, so it gets the \UrlBreaks wrap protection from
-- xurl-workaround.tex (which only applies to real \url{}/\href{} content,
-- never to plain text). Two known sources of unlinked URL text this fixes:
-- CSL fields citeproc doesn't auto-link (e.g. "archive", populated from
-- Zotero's Extra field), and bare URLs typed directly in document body text
-- (pandoc's markdown reader does not autolink these without angle brackets
-- or explicit markdown link syntax).
--
-- Known, accepted limitation: a URL preceded by punctuation on the same Str
-- run (e.g. "(https://example.com/page)") is not linkified, since the
-- leading "(" makes the Str fail the ^https?:// anchor. Narrower than the
-- reported bug; not fixed here to avoid new mis-parses from loosening the
-- anchor.
--
-- TRAILING_PUNCTUATION strips common prose punctuation that follows a bare
-- URL (e.g. "see https://example.com." or "(see https://example.com)"),
-- since that punctuation belongs to the surrounding sentence, not the link
-- target. ")" and "]" get extra treatment below: a URL that legitimately
-- ends in one of them (e.g. a Wikipedia disambiguation link such as
-- ".../wiki/Example_(disambiguation)") must keep it in the target, while a
-- URL merely followed by prose's closing paren/bracket must not.
local TRAILING_PUNCTUATION = "[%.,;:!%?%)%]]*$"

-- NOTE: this filter only ever sees a bare URL as a pandoc `Str` node -- i.e. one still typed
-- as plain text when export runs. web/milkdown/src/autolink-plugin.ts's
-- autolinkInputRuleHandler auto-links a bare URL the moment the user types a trailing space
-- after it, which happens well before export and pre-empts this filter ever seeing that URL
-- as a `Str`. That handler duplicates this filter's closesUnmatchedBracket logic exactly (in
-- TypeScript) so a URL like a Wikipedia disambiguation link doesn't lose its closing paren
-- earlier in the pipeline, before this filter ever runs. If closesUnmatchedBracket changes
-- here, change it there too. The two files' TRAILING_PUNCTUATION character sets are NOT kept
-- in sync, though, and currently differ: this filter strips only ". , ; : ! ? ) ]", while
-- TRAILING_PUNCT in the TypeScript handler also strips "} > ' \"".

-- True if appending `char` (")" or "]") to `text` would close a "("/"["
-- that's unmatched within `text` -- i.e. the bracket is part of the URL's
-- own content, not surrounding prose punctuation.
local function closesUnmatchedBracket(text, char)
  local openPattern, closePattern
  if char == ")" then
    openPattern, closePattern = "%(", "%)"
  else
    openPattern, closePattern = "%[", "%]"
  end
  local opens, closes = 0, 0
  for c in text:gmatch(".") do
    if c:match(openPattern) then
      opens = opens + 1
    elseif c:match(closePattern) then
      closes = closes + 1
    end
  end
  return opens > closes
end

local function Link(el)
  return el, false  -- already a real link -- don't re-descend/re-wrap its text
end

local function Str(el)
  if not el.text:match("^https?://") then return nil end
  local trail = el.text:match(TRAILING_PUNCTUATION)
  local url = el.text:sub(1, #el.text - #trail)
  -- Re-absorb leading trail characters that are ")"/"]" closing an earlier
  -- unmatched "("/"[" within the URL itself, so they stay in the link
  -- target instead of being stripped as surrounding prose punctuation.
  while #trail > 0 do
    local firstChar = trail:sub(1, 1)
    if (firstChar == ")" or firstChar == "]") and closesUnmatchedBracket(url, firstChar) then
      url = url .. firstChar
      trail = trail:sub(2)
    else
      break
    end
  end
  if url == "" then return nil end
  local link = pandoc.Link(pandoc.Str(url), url)
  if trail == "" then return link, false end
  return { link, pandoc.Str(trail) }, false
end

return { { traverse = 'topdown', Link = Link, Str = Str } }
