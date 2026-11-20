#!/usr/bin/env luajit
-- Tap to sync: word placement, offset maths and choosing the word to wait for.
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
-- The dialog's widgets: only loaded here, never built by these checks.
for _i, mod in ipairs({ "ffi/blitbuffer", "ui/widget/button", "ui/widget/container/centercontainer",
        "ui/font", "ui/widget/container/framecontainer", "ui/size", "ui/widget/textboxwidget",
        "ui/widget/textwidget", "ui/widget/verticalgroup", "ui/widget/verticalspan" }) do
    package.preload[mod] = package.preload[mod] or function() return {} end
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

-- firstWord: the word the dialog asks the listener to wait for.
ok(TapSync.firstWord("\226\128\156Hello,\226\128\157 said Carl.") == "Hello", "curly quotes dropped")
ok(TapSync.firstWord("Donut's back") == "Donut's", "apostrophe kept inside")
ok(TapSync.firstWord("... \226\128\148 Run!") == "Run", "leading punctuation and dash skipped")
ok(TapSync.firstWord("...") == nil and TapSync.firstWord(nil) == nil, "no word -> nil")

-- pickTarget: the next line far enough ahead to get ready, with a word.
local td = {
    { start_time = 10, text = "One" },
    { start_time = 11, text = "Two" },
    { start_time = 14, text = "\226\128\148" },
    { start_time = 15, text = "Four" },
    { start_time = 200, text = "Far" },
}
ok(TapSync.pickTarget(td, 1, 10.5, 3) == 4, "skips lines too soon and lines with no word")
ok(TapSync.pickTarget(td, 4, 16, 3) == nil, "over a minute ahead -> nil")
ok(TapSync.pickTarget(td, 0, 0, 3) == 1, "from the start")
ok(TapSync.pickTarget(nil, 0, 0, 3) == nil, "no timing -> nil")

if #failures > 0 then
    for _, f in ipairs(failures) do print("FAIL: " .. f) end
    print(("%d of %d checks failed"):format(#failures, checks))
    os.exit(1)
end
print(("tapsync: all %d checks passed"):format(checks))
