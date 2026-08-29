-- Standalone harness for zotero.lua's group-library phase-2 merge logic (the LOCAL PATCH
-- block in final final/Resources/Export/zotero.lua). Run via `pandoc lua
-- zotero-group-library-merge-harness.lua <path-to-zotero.lua>` -- pandoc bundles a full Lua
-- 5.4 interpreter (including lpeg, pandoc.mediabag, pandoc.json) that can run a standalone
-- script this way, with no `lua`/`luajit` binary needed.
--
-- This drives the REAL, patched zotero.lua file (not a hand-duplicated reimplementation of
-- its merge logic): it loads the file with `dofile`, monkey-patches `pandoc.mediabag.fetch`
-- to return two canned JSON-RPC responses instead of making a real network call, then
-- exercises the module's own public `get(citekey)` entry point exactly the way Cite_replace
-- does in production.
--
-- Scenario: phase 1 (personal library, unscoped) resolves `leonard2015` but reports
-- `dubois2015` as not found (errors.dubois2015 = 0). Phase 2 (group libraries) then resolves
-- `dubois2015`. Expected outcome per the patch's contract: BOTH citekeys resolve via get(),
-- because dubois2015's stale phase-1 error entry must be cleared when phase 2 resolves it --
-- get() checks `errors` BEFORE `items`, so a leftover error entry would keep reporting
-- "not found" even after `items` has the resolved entry.
--
-- This also asserts that the phase-2 HTTP request actually carries the group-library scope:
-- it captures the URL passed to the second `pandoc.mediabag.fetch` call and checks it contains
-- the configured library name. `fetch()` builds this URL from `module.url ..
-- utils.urlencode(json.encode(request))`, so the JSON body (including
-- `request.params.libraryID`) is percent-encoded into it -- decoding it back is the only way
-- to search for the plain-text library name. Without this, deleting the line that sets
-- `request.params.libraryID = libraryID` in `fetch()` would leave every other assertion in
-- this harness green (the canned responses don't depend on what was actually requested) while
-- the feature itself is silently dead.
--
-- Swift caller: ExportGroupLibraryScopeLuaMergeTests (final finalTests/Tier1/
-- ExportGroupLibraryScopeTests.swift) shells out to `pandoc lua` with this script, and asserts
-- exit code 0 and stdout containing "PASS".

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
local phaseTwoResponse = {
  jsonrpc = '2.0',
  result = {
    errors = {},
    items = { dubois2015 = { id = 'dubois2015', type = 'book', title = 'Dubois Item' } },
  },
}

-- Reverses `module.urlencode`'s `%XX` percent-encoding so the captured request URL can be
-- searched for the plain-text library name below.
local function urldecode(s)
  return (s:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end))
end

local fetchCallCount = 0
local capturedUrls = {}
pandoc.mediabag.fetch = function(url, dir)
  -- The file's own top-of-file version-check pcall fetches this URL first; answer harmlessly
  -- so it never reaches the real network and never counts as one of the two RPC calls below.
  if string.find(url, 'retorque.re', 1, true) then
    return nil, ''
  end

  fetchCallCount = fetchCallCount + 1
  capturedUrls[fetchCallCount] = url
  if fetchCallCount == 1 then
    return 'application/json', pandoc.json.encode(phaseOneResponse)
  elseif fetchCallCount == 2 then
    return 'application/json', pandoc.json.encode(phaseTwoResponse)
  else
    error('unexpected pandoc.mediabag.fetch call #' .. fetchCallCount .. ' for url: ' .. url)
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
zotero.groupLibraryNames = { 'Some Group Library' }
zotero.citekeys = { leonard2015 = true, dubois2015 = true }

local leonard = zotero.get('leonard2015')
local dubois = zotero.get('dubois2015')

local failures = {}
if leonard == nil then
  table.insert(failures, 'leonard2015 (resolved in phase 1) should still resolve via get()')
end
if dubois == nil then
  table.insert(failures,
    'dubois2015 (unresolved in phase 1, resolved in phase 2) should resolve via get() -- this ' ..
    'is the load-bearing assertion: it fails if the stale phase-1 error entry is not cleared')
end
if fetchCallCount ~= 2 then
  table.insert(failures, 'expected exactly 2 fetch calls (phase 1 + phase 2), got ' .. fetchCallCount)
end

local phaseTwoUrl = capturedUrls[2]
if phaseTwoUrl == nil then
  table.insert(failures, 'no URL captured for the phase-2 fetch call')
elseif not string.find(urldecode(phaseTwoUrl), 'Some Group Library', 1, true) then
  table.insert(failures,
    'phase-2 request URL should carry the configured group library name ("Some Group ' ..
    'Library") -- this fails if `request.params.libraryID = libraryID` is ever removed from ' ..
    'fetch() in zotero.lua. Decoded URL was: ' .. urldecode(phaseTwoUrl))
end

if #failures > 0 then
  for _, f in ipairs(failures) do
    print('FAIL: ' .. f)
  end
  os.exit(1)
end

print('PASS')
os.exit(0)
