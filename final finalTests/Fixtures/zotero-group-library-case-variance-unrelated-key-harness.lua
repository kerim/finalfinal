-- Standalone harness for zotero.lua's group-library phase-2 merge logic, guarding the SECOND
-- case-variance failure mode: a response spelling that differs in case from an ALREADY-RESOLVED,
-- out-of-scope citekey must never clobber that citekey's entry, even though the two share the
-- same lowercased identity. Run via `pandoc lua
-- zotero-group-library-case-variance-unrelated-key-harness.lua <path-to-zotero.lua>` -- see
-- zotero-group-library-merge-harness.lua's header comment for why `pandoc lua` and `dofile` are
-- used instead of a hand-duplicated reimplementation.
--
-- Scenario: the document cites TWO genuinely DIFFERENT citekeys that happen to share a
-- lowercased identity: `Roy2022` (resolved in phase 1, from the PERSONAL library) and `ROY2022`
-- (a separate citekey, unresolved after phase 1). One nameless/colliding group library, id 20
-- (module.groupLibraryNames stays nil, module.groupLibraryIDs = {20}).
--
-- Phase 1 resolves `Roy2022` from the personal library and reports `ROY2022` as not found
-- (errors.ROY2022 = 0) -- so `unresolved` for phase 2 contains ONLY `ROY2022`, never `Roy2022`.
-- Phase 2's id-20 call, answering the `ROY2022` lookup, HITS but keys its result `items.Roy2022`
-- (BBT's own spelling choice for the item it found) -- the exact same string as the ALREADY-
-- RESOLVED personal-library citekey, but referring to a completely different item.
--
-- Expected outcome: `zotero.get('Roy2022')` must still return the ORIGINAL phase-1
-- personal-library item, completely untouched. This is the load-bearing assertion: under the
-- bug, `Roy2022` (the response spelling, never a member of `unresolved`) gets projected onto
-- `state.fetched.items['Roy2022']`, silently overwriting the original personal-library item.
--
-- Swift caller: ExportGroupLibraryScopeLuaMergeTests.testCaseVarianceResponseSpellingNeverClobbersUnrelatedResolvedKey
-- (final finalTests/Tier1/ExportGroupLibraryScopeTests.swift).

local zoteroLuaPath = arg[1]
if not zoteroLuaPath then
  print('FAIL: no zotero.lua path given as arg[1]')
  os.exit(1)
end

local phaseOneResponse = {
  jsonrpc = '2.0',
  result = {
    errors = { ROY2022 = 0 },
    items = { Roy2022 = { id = 'Roy2022', type = 'book', title = 'Original personal-library Roy item' } },
  },
}
local id20HitResponse = {
  jsonrpc = '2.0',
  result = {
    errors = {},
    -- BBT's own spelling choice for the ROY2022 lookup happens to collide with the ALREADY-
    -- RESOLVED personal-library citekey's exact spelling -- a completely different item.
    items = { Roy2022 = { id = 'Roy2022', type = 'book', title = 'WRONG: group-library item for ROY2022' } },
  },
}

local fetchCallCount = 0
pandoc.mediabag.fetch = function(url, dir)
  -- The file's own top-of-file version-check pcall fetches this URL first; answer harmlessly
  -- so it never reaches the real network and never counts as one of the two RPC calls below.
  if string.find(url, 'retorque.re', 1, true) then
    return nil, ''
  end

  fetchCallCount = fetchCallCount + 1
  if fetchCallCount == 1 then
    return 'application/json', pandoc.json.encode(phaseOneResponse)
  elseif fetchCallCount == 2 then
    return 'application/json', pandoc.json.encode(id20HitResponse)
  else
    error('unexpected pandoc.mediabag.fetch call #' .. fetchCallCount .. ' for url: ' .. url)
  end
end

dofile(zoteroLuaPath)
local zotero = require('zotero')

-- Bypass Meta() (which needs a full pandoc filter run with a real FORMAT) and set up exactly
-- what it would have configured for a DOCX export against this library set.
zotero.url = 'http://127.0.0.1:23119/better-bibtex/json-rpc?'
zotero.request = {
  jsonrpc = '2.0',
  method = 'item.pandoc_filter',
  params = { style = 'apa', asCSL = true },
}
-- A single nameless/colliding group library -- groupLibraryNames is left at its default nil.
zotero.groupLibraryIDs = { 20 }
zotero.citekeys = { Roy2022 = true, ROY2022 = true }

local roy = zotero.get('Roy2022')
local royUpper = zotero.get('ROY2022')

local failures = {}
if roy == nil then
  table.insert(failures,
    'Roy2022 (resolved in phase 1 from the personal library) should still resolve via get() -- ' ..
    'phase 2 never even requested this exact spelling (it was not in `unresolved`)')
elseif roy.title ~= 'Original personal-library Roy item' then
  table.insert(failures,
    'get(\'Roy2022\') returned the WRONG item -- it must be the untouched phase-1 personal-' ..
    'library item, not the group-library response for the unrelated ROY2022 lookup. Got: ' ..
    tostring(roy.title))
end
-- Not the load-bearing assertion (see header), but confirms ROY2022 itself still resolved
-- correctly under its own exact spelling as a side effect of the fix.
if royUpper == nil then
  table.insert(failures, 'ROY2022 (the citekey phase 2 actually requested) should resolve via get()')
end
if fetchCallCount ~= 2 then
  table.insert(failures, 'expected exactly 2 fetch calls (phase 1 + id 20), got ' .. fetchCallCount)
end

if #failures > 0 then
  for _, f in ipairs(failures) do
    print('FAIL: ' .. f)
  end
  os.exit(1)
end

print('PASS')
os.exit(0)
