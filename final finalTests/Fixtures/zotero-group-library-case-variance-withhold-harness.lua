-- Standalone harness for zotero.lua's group-library phase-2 merge logic, specifically the
-- CASE-VARIANCE withhold rule: two separately id-scoped calls each genuinely resolve the SAME
-- citekey IDENTITY to a genuinely DIFFERENT item, but under DIFFERENT casings of that identity
-- (mirroring BBT's own "case-insensitive citekeys" preference, which can return an item whose
-- own citation-key differs in case from what was actually requested). Run via `pandoc lua
-- zotero-group-library-case-variance-withhold-harness.lua <path-to-zotero.lua>` -- see
-- zotero-group-library-merge-harness.lua's header comment for why `pandoc lua` and `dofile` are
-- used instead of a hand-duplicated reimplementation.
--
-- This is distinct from zotero-group-library-cross-scope-duplicate-harness.lua, which covers the
-- SAME-casing cross-scope duplicate. Here the whole point is that NEITHER response uses the
-- exact requested spelling at all -- proving withhold/resolve reconciliation must be anchored to
-- the REQUESTED citekey (`unresolved`), not to whichever spellings a response happens to use.
--
-- Scenario: the user has 2 group libraries, BOTH nameless/colliding (ids 20 and 21) -- so
-- module.groupLibraryNames stays nil and module.groupLibraryIDs = {20, 21} carries both.
-- Citekey requested by the document is `Roy2022`.
--
-- Phase 1 (personal library, unscoped) reports `Roy2022` as not found (errors.Roy2022 = 0).
-- Phase 2 then runs:
--   call 2: id 20 -- HITS, but keyed `items.roy2022` (all-lowercase), title "copy in library 20".
--   call 3: id 21 -- HITS, but keyed `items.ROY2022` (all-uppercase), title "copy in library 21"
--           -- a genuinely DIFFERENT item, under yet another casing of the same identity.
-- Expected outcome, mirroring the Swift-side mergeGroupOutcomes contract exactly:
--   - `zotero.get('Roy2022')` -- the EXACT spelling the document actually cites -- must return
--     nil. A test that only checked this would still pass under the bug (where the requested
--     spelling's stale phase-1 "not found" entry is simply left untouched), so this alone is not
--     the load-bearing assertion.
--   - Captured print() output must contain "duplicates found" for `Roy2022` -- NOT "not found".
--     This is the load-bearing assertion: under the bug, neither response spelling
--     (`roy2022`/`ROY2022`) matches the requested spelling `Roy2022` exactly, so the withhold
--     logic (keyed off spellings actually seen in responses) never touches `Roy2022`'s entry,
--     and get() falls through to reporting phase 1's stale "not found" instead.
--
-- Swift caller: ExportGroupLibraryScopeLuaMergeTests.testCaseVarianceAcrossScopesIsWithheldAndReportedAsDuplicate
-- (final finalTests/Tier1/ExportGroupLibraryScopeTests.swift).

local zoteroLuaPath = arg[1]
if not zoteroLuaPath then
  print('FAIL: no zotero.lua path given as arg[1]')
  os.exit(1)
end

local phaseOneResponse = {
  jsonrpc = '2.0',
  result = {
    errors = { Roy2022 = 0 },
    items = {},
  },
}
local id20HitResponse = {
  jsonrpc = '2.0',
  result = {
    errors = {},
    items = { roy2022 = { id = 'roy2022', type = 'book', title = 'Roy, copy in library 20' } },
  },
}
local id21HitResponse = {
  jsonrpc = '2.0',
  result = {
    errors = {},
    items = { ROY2022 = { id = 'ROY2022', type = 'book', title = 'Roy, copy in library 21' } },
  },
}

local fetchCallCount = 0
pandoc.mediabag.fetch = function(url, dir)
  -- The file's own top-of-file version-check pcall fetches this URL first; answer harmlessly
  -- so it never reaches the real network and never counts as one of the three RPC calls below.
  if string.find(url, 'retorque.re', 1, true) then
    return nil, ''
  end

  fetchCallCount = fetchCallCount + 1
  if fetchCallCount == 1 then
    return 'application/json', pandoc.json.encode(phaseOneResponse)
  elseif fetchCallCount == 2 then
    return 'application/json', pandoc.json.encode(id20HitResponse)
  elseif fetchCallCount == 3 then
    return 'application/json', pandoc.json.encode(id21HitResponse)
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
-- No uniquely-named library at all -- groupLibraryNames is left at its default nil.
zotero.groupLibraryIDs = { 20, 21 }
zotero.citekeys = { Roy2022 = true }

-- Capture print() output for the "duplicates found" assertion below, while still letting the
-- captured lines reach real stdout for debuggability if this harness is ever run manually.
local capturedPrintLines = {}
local realPrint = print
print = function(...)
  local parts = {}
  for i = 1, select('#', ...) do
    parts[i] = tostring(select(i, ...))
  end
  table.insert(capturedPrintLines, table.concat(parts, '\t'))
  realPrint(...)
end

local roy = zotero.get('Roy2022')

print = realPrint

local failures = {}
if roy ~= nil then
  table.insert(failures,
    'Roy2022 (a genuine cross-scope duplicate under case-varying response spellings roy2022/' ..
    'ROY2022) must resolve to nil via get(), never an arbitrary winner')
end
if fetchCallCount ~= 3 then
  table.insert(failures, 'expected exactly 3 fetch calls (phase 1 + id 20 + id 21), got ' .. fetchCallCount)
end

local sawDuplicatesMessage = false
local sawNotFoundMessage = false
for _, line in ipairs(capturedPrintLines) do
  if string.find(line, 'duplicates found', 1, true) then
    sawDuplicatesMessage = true
  end
  if string.find(line, 'Roy2022: not found', 1, true) then
    sawNotFoundMessage = true
  end
end
if not sawDuplicatesMessage then
  table.insert(failures,
    'expected some captured print() output to contain "duplicates found" for Roy2022 -- this is ' ..
    'the load-bearing assertion: the bug leaves the REQUESTED spelling\'s stale phase-1 entry ' ..
    'untouched because neither response used that exact casing')
end
if sawNotFoundMessage then
  table.insert(failures,
    'captured print() output should NOT contain "Roy2022: not found" -- that is exactly the ' ..
    'stale phase-1 value the fix must overwrite with the duplicate outcome')
end

if #failures > 0 then
  for _, f in ipairs(failures) do
    realPrint('FAIL: ' .. f)
  end
  os.exit(1)
end

realPrint('PASS')
os.exit(0)
