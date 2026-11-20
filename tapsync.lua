--[[--
Tap to sync: set the read-along highlight offset from one tap.

A large dialog names one word coming up in the narration (the first word
of a line) and the user taps anywhere the moment they hear it.
Its time is the start of its line, and the gap between that and what is
heard at the tap is the offset. Positive = highlight later (same sign as
smil_sync_offset_ms).

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

-- ── Choosing the word to listen for ──────────────────────────────────

TapSync.LEAD_S = 3     -- the word comes at least this far ahead, to get ready
TapSync.MISS_S = 4     -- this long after the word with no tap: pick another

--- The first word of a line, as printed (punctuation around it dropped).
local QUOTES = { "“", "”", "‘", "’", "«", "»", "—", "–", "…" }

function TapSync.firstWord(text)
    for token in (text or ""):gmatch("%S+") do
        -- Typographic quotes and dashes are letters to %w's eyes (bytes
        -- over 127): take them off the ends like ASCII punctuation.
        local changed = true
        while changed do
            changed = false
            local before = token
            token = token:gsub("^%p+", ""):gsub("%p+$", "")
            for _i, q in ipairs(QUOTES) do
                if token:sub(1, #q) == q then token = token:sub(#q + 1) end
                if #token >= #q and token:sub(-#q) == q then token = token:sub(1, -#q - 1) end
            end
            changed = token ~= before
        end
        if token:find("[%w\128-\255]") then return token end
    end
    return nil
end

--- The line to listen for: the first one after `from_idx` that starts at
--- least lead_s after `now` and has a word to show.
-- @treturn number|nil index into timing_data
function TapSync.pickTarget(timing_data, from_idx, now, lead_s)
    if not timing_data then return nil end
    now = now or 0
    for i = math.max(1, (from_idx or 0) + 1), #timing_data do
        local e = timing_data[i]
        if e.start_time and e.start_time >= now + (lead_s or TapSync.LEAD_S)
                and TapSync.firstWord(e.text) then
            -- Further than a minute ahead is another chapter, not a cue.
            if e.start_time > now + 60 then return nil end
            return i
        end
    end
    return nil
end

-- ── The dialog ───────────────────────────────────────────────────────

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local TapDialog = InputContainer:extend{
    name = "AudiobookTapToSync",
    modal = true,
}

function TapDialog:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    local w = math.floor(sw * 0.9)
    local pad = Size.padding.large * 2
    local inner = w - 2 * pad
    self.word_widget = TextWidget:new{
        text = " ", face = Font:getFace("cfont", 40), bold = true, max_width = inner,
    }
    self.line_widget = TextBoxWidget:new{
        text = " ", face = Font:getFace("cfont", 20), width = inner,
        alignment = "center", height = Screen:scaleBySize(80),
        height_overflow_show_ellipsis = true,
    }
    self.status_widget = TextWidget:new{
        text = _("Get ready…"), face = Font:getFace("cfont", 22), max_width = inner,
    }
    self.cancel = Button:new{
        text = _("Cancel"), width = math.floor(inner / 2),
        text_font_size = 22,
        callback = function() if self.on_cancel then self.on_cancel() end end,
        show_parent = self,
    }
    local function span(n) return VerticalSpan:new{ width = n or pad } end
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = pad,
        width = w,
        VerticalGroup:new{
            align = "center",
            TextWidget:new{ text = _("Tap to sync"), face = Font:getFace("cfont", 26), bold = true },
            span(),
            TextWidget:new{ text = _("Listen for"), face = Font:getFace("cfont", 22) },
            self.word_widget,
            span(Size.padding.large),
            self.line_widget,
            span(),
            TextBoxWidget:new{
                text = _("Tap anywhere the moment you hear it."),
                face = Font:getFace("cfont", 24), bold = true, width = inner,
                alignment = "center",
            },
            span(Size.padding.large),
            self.status_widget,
            span(),
            self.cancel,
        },
    }
    self[1] = CenterContainer:new{ dimen = Geom:new{ w = sw, h = sh }, self.frame }
    self.ges_events = {
        TapSync = { GestureRange:new{ ges = "tap", range = self.dimen } },
        -- A swipe or hold does nothing: the page must not turn under us.
        Swallow = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        SwallowHold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

--- Show the line to listen for: its first word large, the line under it.
function TapDialog:setTarget(word, line)
    self.word_widget:setText("“" .. word .. "”")
    self.line_widget:setText(line or "")
    self.status_widget:setText(_("Get ready…"))
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

function TapDialog:setStatus(text)
    self.status_widget:setText(text)
    UIManager:setDirty(self, function() return "fast", self.frame.dimen end)
end

function TapDialog:onTapSync(_arg, ges)
    local c = self.cancel.dimen
    if c and ges and ges.pos and ges.pos:intersectWith(c) then
        if self.on_cancel then self.on_cancel() end
        return true
    end
    if self.on_tap then self.on_tap(ges) end
    return true
end

function TapDialog:onSwallow() return true end
TapDialog.onSwallowHold = TapDialog.onSwallow

function TapDialog:onCloseWidget()
    local d = self.frame and self.frame.dimen
    UIManager:setDirty(nil, function() return "ui", d end)
end

--- Narration time heard at the moment of the tap (s).
local function heardAt(ms, ges)
    local eng = ms.media_engine
    local pos = eng and eng:getPosition() or 0
    local lat = eng and eng.position_latency_s or 0
    -- Take back the time between the finger and this callback.
    local ok, since = pcall(function()
        local time = require("ui/time")
        return ges and ges.time and time.to_s(time.since(ges.time)) or 0
    end)
    if ok and since and since > 0 and since < 2 then pos = pos - since end
    return pos - lat
end

--- A large dialog shows one word coming up in the narration, and the user
--- taps anywhere when they hear it. The word is the first of its line, so
--- its time is the line's start, and the gap to the tap is the offset.
-- @tparam table plugin the Audiobook plugin
-- @tparam[opt] function on_done called with the new offset (ms) once set
function TapSync.start(plugin, on_done)
    local ms = plugin.media_sync
    local function info(text)
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
    end
    if not (ms and ms.timing_data and ms.state == ms.STATE.PLAYING) then
        info(_("Play the audiobook first, then Tap to sync."))
        return
    end
    local bar = ms.playback_bar
    -- Back to the page: the full-screen player would sit under the dialog.
    if bar and not bar._minimized and bar.onMinimize then
        local ok, err = pcall(bar.onMinimize, bar)
        if not ok then logger.warn("TapSync: minimize failed:", err) end
    end

    local dlg = TapDialog:new{}
    local target, done = nil, false
    local watch
    local function finish()
        if done then return false end
        done = true
        UIManager:unschedule(watch)
        UIManager:close(dlg)
        return true
    end
    local function now() return heardAt(ms, nil) end
    local function choose()
        local from = math.max(ms._current_sentence_idx or 0, target or 0)
        target = TapSync.pickTarget(ms.timing_data, from, now(), TapSync.LEAD_S)
        if not target then return false end
        local e = ms.timing_data[target]
        dlg:setTarget(TapSync.firstWord(e.text), e.text)
        return true
    end
    -- Every half second: "any moment now" once the word is close, another
    -- word if it went by with no tap, stop if playback stopped.
    local tries, said_now = 0, false
    watch = function()
        if done then return end
        if ms.state ~= ms.STATE.PLAYING then
            if finish() then info(_("Tap to sync stopped: the audiobook is not playing.")) end
            return
        end
        local e = target and ms.timing_data[target]
        local t = now()
        if e and t > e.start_time + TapSync.MISS_S then
            tries = tries + 1
            if tries >= 3 or not choose() then
                if finish() then info(_("Tap to sync stopped.")) end
                return
            end
            said_now = false
        elseif e and not said_now and t >= e.start_time - 1.5 then
            said_now = true
            dlg:setStatus(_("Any moment now…"))
        end
        UIManager:scheduleIn(0.5, watch)
    end
    dlg.on_cancel = function() finish() end
    dlg.on_tap = function(ges)
        -- The clock first, before anything slow.
        local heard = heardAt(ms, ges)
        local e = target and ms.timing_data[target]
        if not e then return end
        if heard < e.start_time - 5 then
            dlg:setStatus(_("Not yet: tap when you hear the word."))
            return
        end
        local new_ms = TapSync.offsetFor(heard, e, 0)
        logger.info("TapSync:", TapSync.firstWord(e.text), "heard", heard,
            "line", e.start_time, "->", new_ms)
        if not new_ms then
            dlg:setStatus(_("That was far from the word. Listen for it again."))
            return
        end
        finish()
        TapSync.setOffset(plugin, new_ms)
        if not (bar and bar._minimized and bar.on_sync_nudge) then
            info(TapSync.describe(new_ms))
        end
        if on_done then pcall(on_done, new_ms) end
    end

    if not choose() then
        info(_("No line coming up to listen for. Try again in a moment."))
        return
    end
    UIManager:show(dlg)
    UIManager:scheduleIn(0.5, watch)
end

return TapSync
