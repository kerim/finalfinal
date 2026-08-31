-- Standalone harness for zotero.lua's group-library phase-2 merge logic, specifically the
-- CASE-VARIANCE resolve rule: a single group-scoped call resolves a requested citekey to an
-- item keyed under a DIFFERENT casing than what was actually requested -- exactly what BBT's own
-- "case-insensitive citekeys" preference can produce, and the entire reason lowercased-identity
-- matching exists in this patch at all. Run via `pandoc lua
-- zotero-group-library-case-variance-resolve-harness.lua <path-to-zotero.lua>` -- see
-- zotero-group-library-merge-harness.lua's header comment for why `pandoc lua` and `dofile` are
-- used instead of a hand-duplicated reimplementation.
--
-- Scenario: ONE nameless/colliding group library, id 20 (module.groupLibraryNames stays nil,
-- module.groupLibraryIDs = {20}). The document cites `Roy2022`. Phase 1 (personal library,
-- unscoped) reports it as not found (errors.Roy2022 = 0). The id-20 call then HITS, but keyed
-- `items.roy2022` (all-lowercase) -- a single match, no duplicate anywhere.
--
-- Expected outcome: `zotero.get('Roy2022')` -- the EXACT spelling the document actually cites --
-- must return that item, not nil. This is the load-bearing assertion: under the bug, the
-- withhold/resolve logic only ever clears/sets whichever spelling APPEARED IN THE RESPONSE
-- (`roy2022`), never the requested spelling (`Roy2022`) itself, so `Roy2022`'s stale phase-1
-- "not found" entry survives untouched and get('Roy2022') incorrectly returns nil even though
-- phase 2 genuinely resolved it.
--
-- Swift caller: ExportGroupLibraryScopeLuaMergeTests.testCaseVarianceSingleMatchResolvesUnderRequestedSpelling
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
    items = { roy2022 = { id = 'roy2022', type = 'book', title = 'Roy Item, lowercase spelling' } },
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
zotero.citekeys = { Roy2022 = true }

local roy = zotero.get('Roy2022')

local failures = {}
if roy == nil then
  table.insert(failures,
    'Roy2022 (unresolved in phase 1, resolved in phase 2 under the DIFFERENT casing ' ..
    '"roy2022") should resolve via get(\'Roy2022\') -- the exact spelling the document cites')
elseif roy.title ~= 'Roy Item, lowercase spelling' then
  table.insert(failures, 'get(\'Roy2022\') returned an unexpected item: ' .. tostring(roy.title))
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
