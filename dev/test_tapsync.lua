#!/usr/bin/env luajit
-- Tap to sync: word placement, offset maths and the tap flow, with stubs.
-- Run from the repo root: luajit dev/test_tapsync.lua

local here = (arg and arg[0] or "dev/test_tapsync.lua"):gsub("[^/]+$", "")

local scheduled, shown = {}, {}
package.preload["device"] = function()
    return { screen = { getWidth = function() return 1072 end, getHeight = function() return 1448 end } }
end
package.preload["ui/geometry"] = function() return { new = function(_, t) return t end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, t) return t end } end
package.preload["ui/widget/container/inputcontainer"] = function()
    local C = {}
    function C:extend(t) t.__index = t; return setmetatable(t, { __index = self }) end
    function C:new(t) t = t or {}; setmetatable(t, self); if t.init then t:init() end; return t end
    return C
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, w) shown[#shown + 1] = w end,
        close = function(_, w) for i, x in ipairs(shown) do if x == w then table.remove(shown, i) end end end,
        scheduleIn = function(_, s, f) scheduled[f] = s end,
        unschedule = function(_, f) scheduled[f] = nil end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, t) t.info = true; return t end }
end
package.preload["ui/time"] = function()
    return { since = function(t) return t end, to_s = function(t) return t end }
end
package.preload["logger"] = function()
    return setmetatable({}, { __index = function() return function() end end })
end
package.preload["audiobook_gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return { template = function(s, a) return (s:gsub("%%1", tostring(a))) end }
end

local TapSync = dofile(here .. "../tapsync.lua")

local failures, checks = {}, 0
local function ok(cond, label)
    checks = checks + 1
    if not cond then failures[#failures + 1] = label end
end
local function near(a, b, eps) return a and b and math.abs(a - b) <= (eps or 1e-9) end

-- wordShare
local line = "The cat sat on the mat, and the cat slept."
ok(near(TapSync.wordShare(line, "The"), 0), "first word at 0")
local s1 = TapSync.wordShare(line, "cat")
local s2 = TapSync.wordShare(line, "cat", "the mat, and the")
ok(s1 and s2 and s2 > s1, "context picks the second 'cat'")
ok(near(s2, (#"the cat sat on the mat and the " ) / #"the cat sat on the mat and the cat slept"),
    "second 'cat' share by normalised characters")
ok(TapSync.wordShare(line, "dog") == nil, "missing word -> nil")
ok(near(TapSync.wordShare(line, "cat", "nothing like this"), s1), "bad context falls back to first")
ok(near(TapSync.wordShare(line, "Mat,"), TapSync.wordShare(line, "mat")), "punctuation/case ignored")
ok(TapSync.wordShare("", "x") == nil and TapSync.wordShare(line, "") == nil, "empty inputs")

-- offsetFor: highlight shows clock - lat - offset, so offset = heard - word time
local e = { start_time = 10, end_time = 14 }
ok(TapSync.offsetFor(10.8, e, 0) == 800, "heard 0.8 s after the line start -> 800")
ok(TapSync.offsetFor(11.5, e, 0.5) == -500, "word at 12 s heard at 11.5 -> -500")
ok(TapSync.offsetFor(12, e, nil) == 2000, "no share -> line start")
ok(TapSync.offsetFor(12, { start_time = 10 }, 0.5) == 2000, "no end time -> line start")
ok(TapSync.offsetFor(100, e, 0) == nil, "far off -> nil")
ok(TapSync.offsetFor(nil, e, 0) == nil, "no clock -> nil")

-- describe
ok(TapSync.describe(800) == "Highlight now 0.8 s later", "describe later")
ok(TapSync.describe(-1250) == "Highlight now 1.3 s earlier" or TapSync.describe(-1250) == "Highlight now 1.2 s earlier", "describe earlier")
ok(TapSync.describe(20) == "Highlight now in time", "describe in time")

-- Flow: stubbed plugin, bar and document.
local function makePlugin(state)
    local hints = {}
    local nudged = {}
    local bar = {
        on_sync_nudge = true,
        _minimized = true,
        _showHint = function(_, t) hints[#hints + 1] = t end,
        _closeHint = function() end,
        _nudgeSync = function(_, d) nudged[#nudged + 1] = d end,
    }
    local ms = {
        STATE = { STOPPED = "stopped", PLAYING = "playing", PAUSED = "paused" },
        state = state,
        timing_data = { { start_time = 10, end_time = 14, text = line } },
        playback_bar = bar,
        media_engine = { getPosition = function() return 13.0 end, position_latency_s = 2.0 },
    }
    local settings = { smil_sync_offset_ms = 300 }
    local plugin = {
        media_sync = ms,
        getSetting = function(_, k, d) local v = settings[k]; if v == nil then return d end; return v end,
        setSetting = function(_, k, v) settings[k] = v end,
        _matchSmilEntryFromSelection = function() return ms.timing_data[1] end,
        ui = {
            view = { screenToPageTransform = function(_, p) return p end },
            document = {
                getWordFromPosition = function() return { word = "on", pos0 = "x0", pos1 = "x1" } end,
                getPrevVisibleWordStart = function() return nil end,
            },
        },
    }
    return plugin, hints, nudged
end

-- Playing: heard = 13.0 - 2.0 - 0.1 (finger-to-callback) = 10.9; "on" sits at
-- share 12/40 of 10..14 -> 11.2 s; offset = -300 ms; was 300 -> delta -600.
shown = {}
local plugin, hints, nudged = makePlugin("playing")
local done_ms
TapSync.start(plugin, function(v) done_ms = v end)
ok(#shown == 1 and shown[1].on_tap, "catcher shown")
ok(hints[1] == "Tap the word you hear now", "asks for the tap")
shown[1]:onTapSync(nil, { pos = { x = 1, y = 1 }, time = 0.1 })
ok(#shown == 0, "catcher closed after the tap")
local share = (#"the cat sat ") / #"the cat sat on the mat and the cat slept"
local want = math.floor((10.9 - (10 + 4 * share)) * 1000 + 0.5)
ok(done_ms == want, "offset from the tap: got " .. tostring(done_ms) .. " want " .. want)
ok(nudged[1] == want - 300, "bar nudged by the difference")

-- Not playing at start: refused.
shown = {}
plugin = makePlugin("stopped")
TapSync.start(plugin)
ok(#shown == 1 and shown[1].info, "stopped -> message, no catcher")

-- Paused at the tap: no change.
shown = {}
plugin, hints, nudged = makePlugin("paused")
TapSync.start(plugin)
local c = shown[1]
c:onTapSync(nil, { pos = { x = 1, y = 1 } })
ok(#nudged == 0 and hints[#hints]:find("paused"), "paused tap -> hint, no change")

-- Swipe cancels.
shown = {}
plugin, hints, nudged = makePlugin("playing")
TapSync.start(plugin)
shown[1]:onCancelSwipe()
ok(#shown == 0 and #nudged == 0 and hints[#hints] == "Tap to sync stopped.", "swipe cancels")

-- No bar: per-book setter used if present, else the global setting.
shown = {}
plugin = makePlugin("playing")
plugin.media_sync.playback_bar = nil
TapSync.start(plugin)
shown[#shown]:onTapSync(nil, { pos = { x = 1, y = 1 }, time = 0.1 })
ok(plugin:getSetting("smil_sync_offset_ms") == want, "global setting written without a bar")

if #failures > 0 then
    for _, f in ipairs(failures) do print("FAIL: " .. f) end
    print(("%d of %d checks failed"):format(#failures, checks))
    os.exit(1)
end
print(("tapsync: all %d checks passed"):format(checks))
