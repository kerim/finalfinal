-- Standalone harness for zotero.lua's group-library phase-2 merge logic, specifically the
-- SINGLE-scope self-ambiguous withhold rule -- the OTHER withhold trigger, distinct from the
-- cross-scope duplicate covered by zotero-group-library-cross-scope-duplicate-harness.lua. Run
-- via `pandoc lua zotero-group-library-self-ambiguous-scope-harness.lua <path-to-zotero.lua>` --
-- see zotero-group-library-merge-harness.lua's header comment for why `pandoc lua` and `dofile`
-- are used instead of a hand-duplicated reimplementation.
--
-- Scenario: ONE group library, nameless, id 20 (module.groupLibraryNames stays nil,
-- module.groupLibraryIDs = {20}). Citekey `ambig2019` is only ever queried in this one
-- id-scoped call -- there is no second scope, no cross-scope collision possible here at all.
-- Phase 1 misses it (errors.ambig2019 = 0). The id-20 call then reports
-- `errors = { ambig2019 = 2 }, items = {}` -- BBT ITSELF found 2+ matches inside that single
-- library and returned no item, exactly the `errors[k] >= 2` shape `parsePandocFilterResponseRaw`
-- classifies as ambiguous on the Swift side.
--
-- Expected outcome: `get('ambig2019')` returns nil (never an arbitrary pick -- there is nothing
-- to pick from anyway, since BBT returned zero items for it), exactly 2 real fetch calls happen,
-- and print() output contains "duplicates found" -- the self-ambiguous case must produce the
-- same withhold-and-report behavior as a cross-scope duplicate, not a plain "not found".
--
-- Swift caller: ExportGroupLibraryScopeLuaMergeTests.testSelfAmbiguousWithinOneScopeIsWithheld
-- (final finalTests/Tier1/ExportGroupLibraryScopeTests.swift).

local zoteroLuaPath = arg[1]
if not zoteroLuaPath then
  print('FAIL: no zotero.lua path given as arg[1]')
  os.exit(1)
end

local phaseOneResponse = {
  jsonrpc = '2.0',
  result = {
    errors = { ambig2019 = 0 },
    items = {},
  },
}
-- BBT itself reporting 2+ matches inside this one library, with no resolvable item.
local id20AmbiguousResponse = {
  jsonrpc = '2.0',
  result = {
    errors = { ambig2019 = 2 },
    items = {},
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
    return 'application/json', pandoc.json.encode(id20AmbiguousResponse)
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
-- A single nameless group library -- groupLibraryNames is left at its default nil.
zotero.groupLibraryIDs = { 20 }
zotero.citekeys = { ambig2019 = true }

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

local ambig = zotero.get('ambig2019')

print = realPrint

local failures = {}
if ambig ~= nil then
  table.insert(failures,
    'ambig2019 (BBT itself reported 2+ matches inside this one library) must resolve to nil via ' ..
    'get(), never an arbitrary pick')
end
if fetchCallCount ~= 2 then
  table.insert(failures, 'expected exactly 2 fetch calls (phase 1 + id 20), got ' .. fetchCallCount)
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
