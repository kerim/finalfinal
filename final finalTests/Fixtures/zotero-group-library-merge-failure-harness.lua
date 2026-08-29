-- Negative-path companion to zotero-group-library-merge-harness.lua: proves that a total
-- phase-2 failure (every group library lookup fails -- e.g. every cached library name is
-- stale) never clobbers what phase 1 already resolved. Run via `pandoc lua
-- zotero-group-library-merge-failure-harness.lua <path-to-zotero.lua>`.
--
-- This drives the REAL, patched zotero.lua file exactly like the companion harness: `dofile`s
-- it, monkey-patches `pandoc.mediabag.fetch`, and exercises the module's own public
-- `get(citekey)` entry point.
--
-- Scenario: phase 1 (personal library, unscoped) resolves `leonard2015` but reports
-- `dubois2015` as not found (errors.dubois2015 = 0), exactly as in the success-path harness.
-- Phase 2's BATCHED call then fails with a JSON-RPC error object (simulating BBT rejecting the
-- whole array over one stale library name). Per the "LOCAL PATCH (zotero-group-libraries)"
-- retry-name-by-name fallback in zotero.lua, the batch failure triggers one retry per name in
-- `module.groupLibraryNames` (here, exactly one name) -- and that retry ALSO fails, simulating
-- a library that genuinely can't be searched right now.
--
-- Expected outcome: `leonard2015` (resolved in phase 1) must STILL resolve via get() afterward
-- -- the merge logic must never wholesale-reassign `state.fetched` from phase 2's failed
-- result, only merge key-by-key on success. `dubois2015` correctly remains unresolved, since
-- nothing ever actually resolved it.
--
-- Swift caller: ExportGroupLibraryScopeLuaMergeTests.testPhase2FailureDoesNotClobberPhase1
-- (final finalTests/Tier1/ExportGroupLibraryScopeTests.swift) shells out to `pandoc lua` with
-- this script, and asserts exit code 0 and stdout containing "PASS".

local zoteroLuaPath = arg[1]
if not zoteroLuaPath then
  print('FAIL: no zotero.lua path given as arg[1]')
  os.exit(1)
end

local phaseOneResponse = {
  jsonrpc = '2.0',
  result = {
    errors = { dubois2015 = 0 },
    items = { leonard2015 = { id = 'leonard2015', type = 'book', title = 'Leonard Item' } },
  },
}
-- A JSON-RPC error object -- fetch() sees `response.error ~= nil`, prints a message, and
-- returns nil (no Lua error thrown), so the batched pcall in zotero.lua succeeds with a nil
-- result. This is the "response itself is an error" failure mode called out in the review
-- fix, as opposed to a thrown Lua error / decode failure.
local errorResponse = {
  jsonrpc = '2.0',
  error = { code = -32000, message = 'simulated: stale group library name' },
}

local fetchCallCount = 0
pandoc.mediabag.fetch = function(url, dir)
  -- The file's own top-of-file version-check pcall fetches this URL first; answer harmlessly
  -- so it never reaches the real network and never counts as one of the RPC calls below.
  if string.find(url, 'retorque.re', 1, true) then
    return nil, ''
  end

  fetchCallCount = fetchCallCount + 1
  if fetchCallCount == 1 then
    return 'application/json', pandoc.json.encode(phaseOneResponse)
  else
    -- Both the batched phase-2 call (fetchCallCount 2) and every per-name retry call
    -- (fetchCallCount 3+) fail the same way, simulating every group library being
    -- stale/unsearchable this session.
    return 'application/json', pandoc.json.encode(errorResponse)
  end
end

dofile(zoteroLuaPath)
local zotero = require('zotero')

-- Bypass Meta() (which needs a full pandoc filter run with a real FORMAT) and set up exactly
-- what it would have configured for a DOCX export with a group-library scope in play.
zotero.url = 'http://127.0.0.1:23119/better-bibtex/json-rpc?'
zotero.request = {
  jsonrpc = '2.0',
  method = 'item.pandoc_filter',
  params = { style = 'apa', asCSL = true },
}
zotero.groupLibraryNames = { 'Some Stale Group Library' }
zotero.citekeys = { leonard2015 = true, dubois2015 = true }

local leonard = zotero.get('leonard2015')
local dubois = zotero.get('dubois2015')

local failures = {}
if leonard == nil then
  table.insert(failures,
    'leonard2015 (resolved in phase 1) should STILL resolve via get() after a total phase-2 ' ..
    'failure -- this is the load-bearing assertion: it fails if the merge logic ever ' ..
    'wholesale-reassigns state.fetched from a failed phase-2 result instead of merging ' ..
    'key-by-key')
end
if dubois ~= nil then
  table.insert(failures,
    'dubois2015 should remain unresolved -- nothing in this scenario ever actually resolved it')
end
-- 1 (phase 1) + 1 (batched phase-2 attempt) + 1 (per-name retry for the single configured
-- group library name) = 3.
if fetchCallCount ~= 3 then
  table.insert(failures,
    'expected exactly 3 fetch calls (phase 1 + failed batch + failed per-name retry), got ' ..
    fetchCallCount)
end

if #failures > 0 then
  for _, f in ipairs(failures) do
    print('FAIL: ' .. f)
  end
  os.exit(1)
end

print('PASS')
os.exit(0)
