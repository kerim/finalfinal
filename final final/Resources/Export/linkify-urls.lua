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
-- Second known limitation: TRAILING_PUNCTUATION has no balanced-paren
-- accounting, so a URL that legitimately ends in ")" or "]" (e.g. a
-- Wikipedia disambiguation link) gets that trailing character stripped from
-- the link TARGET -- it's re-appended right after as plain text, so the
-- rendered PDF text stays complete, but the click target is truncated/wrong
-- for that narrow case. Follow-up, not fixed here.
local TRAILING_PUNCTUATION = "[%.,;:!%?%)%]]*$"

local function Link(el)
  return el, false  -- already a real link -- don't re-descend/re-wrap its text
end

local function Str(el)
  if not el.text:match("^https?://") then return nil end
  local trail = el.text:match(TRAILING_PUNCTUATION)
  local url = el.text:sub(1, #el.text - #trail)
  if url == "" then return nil end
  local link = pandoc.Link(pandoc.Str(url), url)
  if trail == "" then return link, false end
  return { link, pandoc.Str(trail) }, false
end

return { { traverse = 'topdown', Link = Link, Str = Str } }
