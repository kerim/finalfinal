-- Standalone harness for zotero.lua's group-library phase-2 merge logic, specifically the
-- CROSS-scope duplicate withhold rule: two separately-scoped calls each genuinely resolve the
-- SAME citekey to a genuinely DIFFERENT item. Run via `pandoc lua
-- zotero-group-library-cross-scope-duplicate-harness.lua <path-to-zotero.lua>` -- see
-- zotero-group-library-merge-harness.lua's header comment for why `pandoc lua` and `dofile` are
-- used instead of a hand-duplicated reimplementation.
--
-- Scenario: the user has 2 group libraries, BOTH named "Shared" (ids 20 and 21) -- no
-- uniquely-named group library at all, so module.groupLibraryNames stays nil (nothing to batch)
-- and module.groupLibraryIDs = {20, 21} carries both colliding libraries. Citekeys
-- `leonard2015` and `roy2022`.
--
-- Phase 1 (personal library, unscoped) resolves `leonard2015` but misses `roy2022`
-- (errors.roy2022 = 0). Phase 2 then runs:
--   call 2: id 20 -- HITS roy2022, title "Roy, copy in library 20".
--   call 3: id 21 -- HITS roy2022, title "Roy, copy in library 21" -- a genuinely DIFFERENT
--           item under the same citekey (two group libraries can each legitimately hold their
--           own copy of a reference under the same BibTeX key).
-- Expected outcome, mirroring the Swift-side mergeGroupOutcomes contract exactly:
--   - `leonard2015` still resolves via get() (phase 1's result must survive untouched).
--   - `roy2022` must NOT resolve to either copy -- picking either one arbitrarily would be
--     exactly the silent-wrong-citation failure mode this whole fix exists to avoid. It must
--     come back nil from get(), and get() must print "...: duplicates found" for it (the same
--     message zotero.lua already prints for a single-scope errors[k] >= 2 ambiguity).
--
-- Captures Lua's global `print` (temporarily) to assert on its output, since that's the only
-- observable signal get() gives for "found, but ambiguous" versus "not found at all".
--
-- Swift caller: ExportGroupLibraryScopeLuaMergeTests.testCrossScopeDuplicateIsWithheldAndReportedAsDuplicate
-- (final finalTests/Tier1/ExportGroupLibraryScopeTests.swift).

local zoteroLuaPath = arg[1]
if not zoteroLuaPath then
  print('FAIL: no zotero.lua path given as arg[1]')
  os.exit(1)
end

local phaseOneResponse = {
  jsonrpc = '2.0',
  result = {
    errors = { roy2022 = 0 },
    items = { leonard2015 = { id = 'leonard2015', type = 'book', title = 'Leonard Item' } },
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
    items = { roy2022 = { id = 'roy2022', type = 'book', title = 'Roy, copy in library 21' } },
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
zotero.citekeys = { leonard2015 = true, roy2022 = true }

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

local leonard = zotero.get('leonard2015')
local roy = zotero.get('roy2022')

print = realPrint

local failures = {}
if leonard == nil then
  table.insert(failures, 'leonard2015 (resolved in phase 1) should still resolve via get()')
end
if roy ~= nil then
  table.insert(failures,
    'roy2022 (a genuine cross-scope duplicate -- two DIFFERENT items in libraries 20 and 21) ' ..
    'must resolve to nil via get(), never an arbitrary winner')
end
if fetchCallCount ~= 3 then
  table.insert(failures, 'expected exactly 3 fetch calls (phase 1 + id 20 + id 21), got ' .. fetchCallCount)
end

local sawDuplicatesMessage = false
for _, line in ipairs(capturedPrintLines) do
  if string.find(line, 'duplicates found', 1, true) then
    sawDuplicatesMessage = true
    break
  end
end
if not sawDuplicatesMessage then
  table.insert(failures, 'expected some captured print() output to contain "duplicates found"')
end

if #failures > 0 then
  for _, f in ipairs(failures) do
    realPrint('FAIL: ' .. f)
  end
  os.exit(1)
end

realPrint('PASS')
os.exit(0)
