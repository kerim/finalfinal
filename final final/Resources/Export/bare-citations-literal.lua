-- Render bare (unbracketed) `@citekey` citations as literal text instead of citations.
--
-- Pandoc's citation extension builds a Cite node for ANY bare `@word`, with mode
-- "AuthorInText". With --citeproc active, a Cite whose key isn't in the bibliography
-- renders as a visibly broken marker (e.g. \textbf{key?}), so simply not fetching the
-- key is not enough -- the node has to be flattened back to its own literal content.
--
-- This makes PDF match what DOCX/ODT already do: zotero.lua (lines ~1855 and ~1924)
-- explicitly leaves AuthorInText Cite nodes untouched unless a config flag this app
-- does not set is enabled, so bare @key has always exported as literal text there.
--
-- Ordering is load-bearing: this filter must appear BEFORE --citeproc on the pandoc
-- command line, which is why it is added in buildBaseArguments (alongside
-- figure-placement.lua) rather than in citationArguments, which appends --citeproc.
--
-- Known narrow exception: a mixed citation like `@doe [see @smith]` is a SINGLE Cite
-- node whose first citation is AuthorInText, so the whole node -- including the
-- bracketed part -- is flattened to literal text. There is no clean way to split a
-- single Cite node's citations by mode; this errs toward the product rule ("bare @
-- never resolves") rather than the alternative of letting the bare part resolve too.
function Cite(el)
  if el.citations[1] and el.citations[1].mode == "AuthorInText" then
    return el.content
  end
  return el
end
