--[[--
Tap to sync: set the read-along highlight offset from one tap.

While the audiobook plays, the user taps the word they hear at that moment.
The tapped word's place in its line (by characters) gives the time the
narration should reach it; the gap between that and what is heard now is
the offset. Positive = highlight later (same sign as smil_sync_offset_ms).

Kept apart from the rest of the sync UI so any control can start it:
    Audiobook:startTapToSync()

The offset is read and written through the plugin's per-book accessors
(getSyncOffsetMs / setSyncOffsetMs) when they exist, else the global
smil_sync_offset_ms setting. Through the bar when it can, so its label and
the "Sync" overlay above the minimized bar update the same way −/+ do.

@module koplugin.audiobook.tapsync
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("audiobook_gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local TapSync = {}

TapSync.WAIT_S = 15          -- give up if nothing is tapped
TapSync.MAX_OFFSET_MS = 30000 -- a tap further off is another line, not timing

-- ── Pure helpers (tested in dev/test_tapsync.lua) ────────────────────

local function norm(s)
    -- Lower case, punctuation and runs of space as one space.
    s = (s or ""):lower():gsub("[%p%c]", " "):gsub("%s+", " ")
    return (s:gsub("^ ", ""):gsub(" $", ""))
end

--- Where the word starts in its line, as a share 0..1 of the line's
--- characters. `before` is a little of the text just before the word on the
--- page (may be nil); it picks the right one when the word repeats.
-- @treturn number|nil nil when the word is not in the line
function TapSync.wordShare(line, word, before)
    local nline, nword = norm(line), norm(word)
    if nline == "" or nword == "" then return nil end
    local at
    local nbefore = norm(before)
    -- Try the longest bit of context that still matches, then less.
    while nbefore ~= "" and not at do
        local probe = nbefore .. " " .. nword
        local s = nline:find(probe, 1, true)
        if s then
            at = s + #nbefore + 1
        else
            nbefore = nbefore:gsub("^%S+ ?", "")
        end
    end
    at = at or nline:find(nword, 1, true)
    if not at then return nil end
    return (at - 1) / #nline
end

--- Offset (ms) that makes the highlight reach the tapped word when heard.
-- The sync loop highlights at clock - latency - offset, so
-- offset = heard - word_time.
-- @tparam number heard narration time the listener heard at the tap (s)
-- @tparam table entry timing entry with start_time / end_time (s)
-- @tparam number|nil share where the word sits in the line (0..1)
-- @treturn number|nil new offset in ms, nil when out of range
function TapSync.offsetFor(heard, entry, share)
    if not (heard and entry and entry.start_time) then return nil end
    local t = entry.start_time
    local e = entry.end_time
    if share and e and e > t then
        t = t + (e - t) * math.max(0, math.min(1, share))
    end
    local ms = math.floor((heard - t) * 1000 + 0.5)
    if math.abs(ms) > TapSync.MAX_OFFSET_MS then return nil end
    return ms
end

-- ── Offset storage ───────────────────────────────────────────────────

function TapSync.getOffset(plugin)
    if plugin.getSyncOffsetMs then return plugin:getSyncOffsetMs() end
    return tonumber(plugin:getSetting("smil_sync_offset_ms", 0)) or 0
end

--- Set the offset to new_ms, updating the bar like a −/+ press does.
function TapSync.setOffset(plugin, new_ms)
    local delta = new_ms - TapSync.getOffset(plugin)
    local bar = plugin.media_sync and plugin.media_sync.playback_bar
    if bar and bar.on_sync_nudge and bar._nudgeSync then
        bar:_nudgeSync(delta)
    elseif plugin.nudgeSyncOffset then
        plugin:nudgeSyncOffset(delta)
    elseif plugin.setSyncOffsetMs then
        plugin:setSyncOffsetMs(new_ms)
    else
        -- No flush: a full settings write per change stalls e-ink.
        plugin:setSetting("smil_sync_offset_ms", new_ms, true)
    end
end

--- "Highlight now 0.8 s later" etc.
function TapSync.describe(ms)
    if math.abs(ms) < 50 then return _("Highlight now in time") end
    local s = string.format("%.1f", math.abs(ms) / 1000)
    if ms > 0 then return T(_("Highlight now %1 s later"), s) end
    return T(_("Highlight now %1 s earlier"), s)
end

-- ── The tap ──────────────────────────────────────────────────────────

local TapCatcher = InputContainer:extend{
    name = "AudiobookTapToSync",
    -- Invisible and full screen; nothing is drawn, so no e-ink refresh.
}

function TapCatcher:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapSync = { GestureRange:new{ ges = "tap", range = self.dimen } },
        -- A swipe or hold cancels instead of turning the page under us.
        CancelSwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        CancelHold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function TapCatcher:paintTo() end

function TapCatcher:onTapSync(_arg, ges)
    if self.on_tap then self.on_tap(ges) end
    return true
end

function TapCatcher:onCancelSwipe()
    if self.on_cancel then self.on_cancel() end
    return true
end
TapCatcher.onCancelHold = TapCatcher.onCancelSwipe

--- Narration time heard at the moment of the tap (s).
local function heardAt(ms, ges)
    local eng = ms.media_engine
    local pos = eng and eng:getPosition() or 0
    local lat = eng and eng.position_latency_s or 0
    -- Take back the time between the finger and this callback.
    local ok, since = pcall(function()
        local time = require("ui/time")
        return ges.time and time.to_s(time.since(ges.time)) or 0
    end)
    if ok and since and since > 0 and since < 2 then pos = pos - since end
    return pos - lat
end

--- Resolve the tap to an offset. Returns new_ms, or nil and a reason.
function TapSync.fromTap(plugin, ges, heard)
    local ms = plugin.media_sync
    local doc = plugin.ui and plugin.ui.document
    local view = plugin.ui and plugin.ui.view
    if not (ms and doc and view and ges and ges.pos) then return nil end
    local page_pos = view:screenToPageTransform(ges.pos)
    local word = page_pos and doc:getWordFromPosition(page_pos)
    if not (word and word.word and word.word ~= "") then return nil end
    local sel = { text = word.word, pos0 = word.pos0, pos1 = word.pos1 }
    local entry = plugin:_matchSmilEntryFromSelection(sel, ms.timing_data, plugin._smil_parser)
    if not entry then return nil end
    -- A few words before the tapped one, to tell repeats apart.
    local before
    pcall(function()
        local xp = word.pos0
        for _i = 1, 4 do
            local prev = doc:getPrevVisibleWordStart(xp)
            if not prev or prev == xp then break end
            xp = prev
        end
        if xp ~= word.pos0 then before = doc:getTextFromXPointers(xp, word.pos0) end
    end)
    local share = TapSync.wordShare(entry.text, word.word, before)
    local new_ms = TapSync.offsetFor(heard, entry, share)
    logger.info("TapSync:", word.word, "heard", heard, "line", entry.start_time,
        entry.end_time, "share", share, "->", new_ms)
    return new_ms
end

--- Ask for a tap on the word being heard, then set the offset from it.
-- @tparam table plugin the Audiobook plugin
-- @tparam[opt] function on_done called with the new offset (ms) once set
function TapSync.start(plugin, on_done)
    local ms = plugin.media_sync
    local function info(text)
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
    end
    -- Paused is fine here (a menu may have paused it); the tap needs play.
    if not (ms and ms.timing_data and ms.state ~= ms.STATE.STOPPED) then
        info(_("Play the audiobook first, then Tap to sync."))
        return
    end
    local bar = ms.playback_bar
    -- The tap is on the page: get the full-screen player out of the way.
    if bar and not bar._minimized and bar.onMinimize then
        local ok, err = pcall(bar.onMinimize, bar)
        if not ok then logger.warn("TapSync: minimize failed:", err) end
    end
    local function hint(text, keep)
        if bar and bar._showHint then
            pcall(bar._showHint, bar, text)
            -- Stays up while waiting for the tap.
            if keep and bar._hint_timer then
                UIManager:unschedule(bar._hint_timer)
                bar._hint_timer = nil
            end
        else
            info(text)
        end
    end
    local function closeHint()
        if bar and bar._closeHint then pcall(bar._closeHint, bar) end
    end

    local catcher = TapCatcher:new{}
    local done = false
    local function finish()
        if done then return false end
        done = true
        UIManager:unschedule(catcher.timeout)
        UIManager:close(catcher)
        closeHint()
        return true
    end
    catcher.timeout = function()
        if finish() then hint(_("Tap to sync stopped.")) end
    end
    catcher.on_cancel = catcher.timeout
    catcher.on_tap = function(ges)
        -- The clock first, before anything slow.
        local heard = heardAt(ms, ges)
        if not finish() then return end
        if ms.state ~= ms.STATE.PLAYING then
            hint(_("The audiobook is paused. Play it, then Tap to sync."))
            return
        end
        local ok, new_ms = pcall(TapSync.fromTap, plugin, ges, heard)
        if not ok then
            logger.warn("TapSync: failed:", new_ms)
            new_ms = nil
        end
        if not new_ms then
            hint(_("That word isn't near the narration. Try Tap to sync again."))
            return
        end
        TapSync.setOffset(plugin, new_ms)
        -- The minimized bar already shows the new value above itself.
        if not (bar and bar._minimized and bar.on_sync_nudge) then
            hint(TapSync.describe(new_ms))
        end
        if on_done then pcall(on_done, new_ms) end
    end

    hint(_("Tap the word you hear now"), true)
    UIManager:show(catcher)
    UIManager:scheduleIn(TapSync.WAIT_S, catcher.timeout)
end

return TapSync
