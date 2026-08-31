-- Standalone harness for zotero.lua's group-library phase-2 merge logic, specifically the
-- duplicate-group-library-name fix itself (the id-scoped half of the "LOCAL PATCH
-- (zotero-group-libraries)" block). Run via `pandoc lua
-- zotero-group-library-duplicate-name-harness.lua <path-to-zotero.lua>` -- see
-- zotero-group-library-merge-harness.lua's header comment for why `pandoc lua` and `dofile` are
-- used instead of a hand-duplicated reimplementation.
--
-- Scenario: the user has 3 group libraries -- id 19 "Sifo-Futing" (unique), and ids 20 and 21
-- BOTH named "Shared". Per ZoteroService.groupLibraryScopes (the Swift-side source of this
-- partition), "Sifo-Futing" batches into module.groupLibraryNames while the two colliding
-- "Shared" libraries each get their own numeric-id scope in module.groupLibraryIDs -- exactly
-- what ExportService+PandocArguments.swift/Meta() would have configured for a real export
-- against this library set. Citekeys `leonard2015` and `dubois2015` are the real citekeys from
-- the user's own Sifo-Futing library, per task t-f7b81faa's original report -- using real
-- examples is intentional, not a placeholder.
--
-- Phase 1 (personal library, unscoped) resolves `leonard2015` but misses `dubois2015`
-- (errors.dubois2015 = 0). Phase 2 then runs, in this order:
--   call 2: the batched name-scoped call (`Sifo-Futing`) -- a well-formed MISS
--           ({errors={dubois2015=0}, items={}}), not an RPC error, so the name-by-name fallback
--           must NOT fire (a fallback firing here would insert an extra call and shift every
--           later index this harness asserts on).
--   call 3: id 20 -- a MISS.
--   call 4: id 21 -- a HIT for dubois2015.
-- Expected outcome: BOTH citekeys resolve via get(). This is the load-bearing assertion of the
-- whole fix -- id 21 must actually get its own call and its hit must not be shadowed by id 20's
-- miss (the old groupLibraryNames(from:) dedupe would have sent only ONE of "Shared" 20/21 as a
-- name, silently losing whichever library BBT's name lookup didn't happen to match).
--
-- Also asserts (after urldecoding each captured URL, since fetch() percent-encodes the whole
-- JSON body via utils.urlencode) that: call 2's URL carries the "Sifo-Futing" name, call 3's
-- carries `"libraryID":20`, and call 4's carries `"libraryID":21` -- proving each call actually
-- targeted the scope this harness claims it did, not just that four calls happened.
--
-- Swift caller: ExportGroupLibraryScopeLuaMergeTests.testDuplicateGroupLibraryNameResolvesViaIDScope
-- (final finalTests/Tier1/ExportGroupLibraryScopeTests.swift).

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
-- A well-formed MISS, not an RPC error -- this must NOT trigger the name-by-name retry fallback.
local nameScopeMissResponse = {
  jsonrpc = '2.0',
  result = {
    errors = { dubois2015 = 0 },
    items = {},
  },
}
local id20MissResponse = {
  jsonrpc = '2.0',
  result = {
    errors = { dubois2015 = 0 },
    items = {},
  },
}
local id21HitResponse = {
  jsonrpc = '2.0',
  result = {
    errors = {},
    items = { dubois2015 = { id = 'dubois2015', type = 'book', title = 'Dubois Item (library 21)' } },
  },
}

-- Reverses `module.urlencode`'s `%XX` percent-encoding so captured request URLs can be searched
-- for plain-text library names / ids below.
local function urldecode(s)
  return (s:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end))
end

local fetchCallCount = 0
local capturedUrls = {}
pandoc.mediabag.fetch = function(url, dir)
  -- The file's own top-of-file version-check pcall fetches this URL first; answer harmlessly
  -- so it never reaches the real network and never counts as one of the four RPC calls below.
  if string.find(url, 'retorque.re', 1, true) then
    return nil, ''
  end

  fetchCallCount = fetchCallCount + 1
  capturedUrls[fetchCallCount] = url
  if fetchCallCount == 1 then
    return 'application/json', pandoc.json.encode(phaseOneResponse)
  elseif fetchCallCount == 2 then
    return 'application/json', pandoc.json.encode(nameScopeMissResponse)
  elseif fetchCallCount == 3 then
    return 'application/json', pandoc.json.encode(id20MissResponse)
  elseif fetchCallCount == 4 then
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
zotero.groupLibraryNames = { 'Sifo-Futing' }
zotero.groupLibraryIDs = { 20, 21 }
zotero.citekeys = { leonard2015 = true, dubois2015 = true }

local leonard = zotero.get('leonard2015')
local dubois = zotero.get('dubois2015')

local failures = {}
if leonard == nil then
  table.insert(failures, 'leonard2015 (resolved in phase 1) should still resolve via get()')
end
if dubois == nil then
  table.insert(failures,
    'dubois2015 (only resolvable via id-scoped call 21) should resolve via get() -- this is the ' ..
    'load-bearing assertion for the duplicate-group-library-name fix: id 21 must get its own ' ..
    'call and must not be shadowed by id 20 or by the name-scoped miss')
end
if fetchCallCount ~= 4 then
  table.insert(failures, 'expected exactly 4 fetch calls (phase 1 + name scope + id 20 + id 21), got ' .. fetchCallCount)
end

local nameUrl = capturedUrls[2]
if nameUrl == nil or not string.find(urldecode(nameUrl), 'Sifo%-Futing', 1, false) then
  table.insert(failures, 'call 2 (name-scoped) should carry "Sifo-Futing". Decoded URL: ' .. tostring(nameUrl and urldecode(nameUrl)))
end

local id20Url = capturedUrls[3]
if id20Url == nil or not string.find(urldecode(id20Url), '"libraryID":20', 1, true) then
  table.insert(failures, 'call 3 (id 20) should carry "libraryID":20. Decoded URL: ' .. tostring(id20Url and urldecode(id20Url)))
end

local id21Url = capturedUrls[4]
if id21Url == nil or not string.find(urldecode(id21Url), '"libraryID":21', 1, true) then
  table.insert(failures, 'call 4 (id 21) should carry "libraryID":21. Decoded URL: ' .. tostring(id21Url and urldecode(id21Url)))
end

if #failures > 0 then
  for _, f in ipairs(failures) do
    print('FAIL: ' .. f)
  end
  os.exit(1)
end

print('PASS')
os.exit(0)
