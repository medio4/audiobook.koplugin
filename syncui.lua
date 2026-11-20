--[[--
Read-along sync: showing and changing how far the highlight is shifted
against the narration.

- Words, not signs: "Highlight 0.8 s later" / "0.8 s earlier" / "in time".
- A small scale (centre mark, dot left = earlier, right = later).
- One control (from the menu, or the full-screen player's sync label) with
  earlier / later, Tap to sync and reset.
- Tap to sync: tap the word you hear; the offset is worked out from where
  that word sits in its sentence.
- After any change: a tag on the highlighted line, the highlight drawn as an
  outline while it re-times, and the spoken word lit for a few seconds.

The offset itself is per book (Audiobook:getSyncOffsetMs / setSyncOffsetMs).

@module koplugin.audiobook.syncui
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("audiobook_gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local SyncUI = {}

SyncUI.STEP_MS = 100
SyncUI.SCALE_RANGE_MS = 3000 -- the scale's ends
SyncUI.FEEDBACK_S = 3        -- tag / outline / word lighting after a change

--- "Highlight 0.8 s later" etc. Positive offsets delay the highlight.
function SyncUI.words(ms)
    ms = tonumber(ms) or 0
    local s = math.abs(ms) / 1000
    if math.abs(ms) < 50 then return _("Highlight in time with the narration") end
    if ms > 0 then return T(_("Highlight %1 s later"), string.format("%.1f", s)) end
    return T(_("Highlight %1 s earlier"), string.format("%.1f", s))
end

--- Short form for tight spots (bar overlay, tag).
function SyncUI.short(ms)
    ms = tonumber(ms) or 0
    if math.abs(ms) < 50 then return _("in time") end
    local s = string.format("%.1f s", math.abs(ms) / 1000)
    return ms > 0 and T(_("%1 later"), s) or T(_("%1 earlier"), s)
end

--- A text scale: earlier on the left, later on the right, ┼ = in time.
function SyncUI.scale(ms)
    local half = 10
    local pos = math.floor((tonumber(ms) or 0) / SyncUI.SCALE_RANGE_MS * half + 0.5)
    pos = math.max(-half, math.min(half, pos))
    local cells = {}
    for i = -half, half do
        if i == pos then
            cells[#cells + 1] = "●"
        elseif i == 0 then
            cells[#cells + 1] = "┼"
        else
            cells[#cells + 1] = "─"
        end
    end
    return _("earlier") .. "  " .. table.concat(cells) .. "  " .. _("later")
end

-- ── Feedback after a change ──────────────────────────────────────────

-- The tag: "⏸ holding 0.3 s" after a nudge later (the highlight stays on
-- its line that much longer), "⏩ 0.3 s ahead" after a nudge earlier (it
-- jumps forward now). Taps in a row add up in one tag. It is drawn once,
-- a moment after the last tap, so the highlight has already moved and the
-- tag lands on the right line; one small "fast" refresh to show it, one
-- to clear it. No repaint while it is up.

SyncUI.TAG_DELAY_S = 0.4 -- after the last tap: debounce + let the highlight move

--- The tag's text for a net change of delta_ms.
function SyncUI.tagText(delta_ms)
    delta_ms = tonumber(delta_ms) or 0
    local s = string.format("%.1f s", math.abs(delta_ms) / 1000)
    if delta_ms > 0 then return "⏸ " .. T(_("holding %1"), s) end
    if delta_ms < 0 then return "⏩ " .. T(_("%1 ahead"), s) end
    return _("no change")
end

--- Where the tag goes: just after the end of the highlighted line; when
--- that runs off the screen, just above the line's start; with no
--- highlight on screen, above the bar.
function SyncUI.tagPosition(boxes, w, h, screen_w, gap, fallback_y)
    local last = boxes and boxes[#boxes]
    if last then
        local x = last.x + last.w + gap
        local y = last.y + math.floor((last.h - h) / 2)
        if x + w > screen_w then
            local first = boxes[1]
            x = math.max(0, math.min(screen_w - w, first.x))
            y = first.y - h - gap
            if y < 0 then y = last.y + last.h + gap end -- top line: below it
        end
        return x, math.max(0, y)
    end
    return math.floor((screen_w - w) / 2), math.max(0, fallback_y - h - gap)
end

local function closeTag(plugin)
    local t = plugin._sync_tag
    if not t then return end
    plugin._sync_tag = nil
    UIManager:unschedule(t.show)
    UIManager:unschedule(t.close)
    if t.widget then
        local rect = t.rect
        pcall(function()
            UIManager:close(t.widget, "ui", rect)
        end)
    end
end

local function drawTag(plugin, tag)
    if plugin._sync_tag ~= tag then return end
    local ms = plugin.media_sync
    local hm = ms and ms.highlight_manager
    local boxes
    if hm and hm._pending_boxes and hm._boxesMatchCurrentView
            and hm:_boxesMatchCurrentView() then
        boxes = hm._pending_boxes
    end
    local frame = FrameContainer:new{
        toast = true,
        _plugin_chrome = true,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        padding = Size.padding.small,
        TextWidget:new{ text = SyncUI.tagText(tag.delta), face = Font:getFace("cfont", 14), bold = true },
    }
    local size = frame:getSize()
    local bar = ms and ms.playback_bar
    local bar_y = Screen:getHeight()
    if bar and bar._miniBarY then
        local ok, y = pcall(bar._miniBarY, bar)
        if ok and type(y) == "number" then bar_y = y end
    end
    local x, y = SyncUI.tagPosition(boxes, size.w, size.h, Screen:getWidth(),
        Screen:scaleBySize(6), bar_y)
    if tag.widget then
        -- Already up (a tap while it showed): swap in place.
        pcall(function() UIManager:close(tag.widget, "fast", tag.rect) end)
    end
    tag.widget = frame
    tag.rect = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    UIManager:show(frame, "fast", tag.rect, x, y)
    UIManager:unschedule(tag.close)
    UIManager:scheduleIn(SyncUI.FEEDBACK_S, tag.close)
end

--- Show (or add to) the tag after a change of delta_ms.
local function showTag(plugin, delta_ms)
    local tag = plugin._sync_tag
    if not tag then
        tag = { delta = 0 }
        tag.show = function() drawTag(plugin, tag) end
        tag.close = function() if plugin._sync_tag == tag then closeTag(plugin) end end
        plugin._sync_tag = tag
    end
    tag.delta = tag.delta + delta_ms
    UIManager:unschedule(tag.show)
    UIManager:scheduleIn(SyncUI.TAG_DELAY_S, tag.show)
end

SyncUI._closeTag = closeTag

--- Outline style for a few seconds, then back.
local function startAdjustLook(plugin)
    local ms = plugin.media_sync
    local hm = ms and ms.highlight_manager
    if not hm then return end
    if not plugin._sync_adjust then
        plugin._sync_adjust = { style = hm.current_style }
    end
    local st = plugin._sync_adjust
    hm.current_style = hm.STYLES and hm.STYLES.BOX or "box"
    if st.timer then UIManager:unschedule(st.timer) end
    st.timer = function()
        if plugin._sync_adjust ~= st then return end
        plugin._sync_adjust = nil
        hm.current_style = st.style
        -- Repaint the sentence in its own style.
        if ms and ms._highlighted_sentence_idx then ms._highlighted_sentence_idx = nil end
    end
    UIManager:scheduleIn(SyncUI.FEEDBACK_S, st.timer)
    -- Repaint the current sentence in the outline style now.
    if ms then ms._highlighted_sentence_idx = nil end
end

--- Light the spoken word inside the highlight for a few seconds, so the
--- reader can hear and see whether they now line up. Books without word
--- timings get estimated ones (MediaSync:_estimatedWords). Only the word's
--- own box is refreshed as it moves, so this stays cheap on e-ink.
local function startWordLight(plugin)
    local ms = plugin.media_sync
    local hm = ms and ms.highlight_manager
    if not hm then return end
    local st = plugin._sync_words
    if st and st.timer then UIManager:unschedule(st.timer) end
    st = {}
    plugin._sync_words = st
    hm.force_words_until = os.time() + SyncUI.FEEDBACK_S
    -- Light the current word on the next sync tick instead of waiting for
    -- the next word to start, and match it from the line's start again
    -- (an earlier shift moves back in the line).
    ms._current_word_idx = 0
    hm._word_scan = nil
    st.timer = function()
        if plugin._sync_words ~= st then return end
        plugin._sync_words = nil
        -- Cleared before the box, so no sync tick can light it again.
        hm.force_words_until = nil
        -- With word highlighting on anyway, the box stays.
        local always = plugin.getSetting and plugin:getSetting("highlight_words", false) == true
        if not always then
            pcall(function() hm:clearWordHighlight() end)
        end
    end
    UIManager:scheduleIn(SyncUI.FEEDBACK_S, st.timer)
end

--- Called after the offset changed by delta_ms (now total_ms).
function SyncUI.afterChange(plugin, delta_ms, total_ms)
    pcall(startAdjustLook, plugin)
    local okw, errw = pcall(startWordLight, plugin)
    if not okw then logger.warn("SyncUI: word light failed:", errw) end
    local ok, err = pcall(showTag, plugin, delta_ms)
    if not ok then logger.warn("SyncUI: tag failed:", err) end
end

-- ── The control ──────────────────────────────────────────────────────

function SyncUI.showControl(plugin, on_change)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local function reopen()
        if dlg then UIManager:close(dlg) end
        SyncUI.showControl(plugin, on_change)
    end
    local function nudge(delta)
        plugin:nudgeSyncOffset(delta)
        if on_change then pcall(on_change) end
        reopen()
    end
    local cur = plugin:getSyncOffsetMs()
    dlg = ButtonDialog:new{
        title = SyncUI.words(cur) .. "\n" .. SyncUI.scale(cur)
            .. "\n\n" .. _("Later: the highlight waits longer on each line. Earlier: it moves on sooner. This book keeps its own setting."),
        title_align = "center",
        buttons = {
            {
                { text = "◀◀ 0.5 s", callback = function() nudge(-500) end },
                { text = "◀ " .. _("Earlier"), callback = function() nudge(-SyncUI.STEP_MS) end },
                { text = _("Later") .. " ▶", callback = function() nudge(SyncUI.STEP_MS) end },
                { text = "0.5 s ▶▶", callback = function() nudge(500) end },
            },
            {
                { text = _("Tap to sync"), callback = function()
                    UIManager:close(dlg)
                    SyncUI.startTapToSync(plugin, on_change)
                end },
                { text = _("Reset"), callback = function()
                    plugin:nudgeSyncOffset(-plugin:getSyncOffsetMs())
                    if on_change then pcall(on_change) end
                    reopen()
                end },
                { text = _("Close"), callback = function() UIManager:close(dlg) end },
            },
        },
    }
    UIManager:show(dlg)
end

-- ── Tap to sync ──────────────────────────────────────────────────────

local TapCatcher = InputContainer:extend{
    name = "AudiobookTapToSync",
    -- Not a toast: UIManager gives toasts no input. The bar stays above it.
}

function TapCatcher:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapSync = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function TapCatcher:onTapSync(_arg, ges)
    UIManager:close(self)
    if self.on_tap then self.on_tap(ges) end
    return true
end

function TapCatcher:paintTo() end

--- Ask for a tap on the word being heard; set the offset from it.
function SyncUI.startTapToSync(plugin, on_change)
    local ms = plugin.media_sync
    if not (ms and ms.state == ms.STATE.PLAYING) then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = _("Start the audiobook first, then use Tap to sync."),
            timeout = 3,
        })
        return
    end
    local bar = ms.playback_bar
    if bar and bar._showHint then
        pcall(bar._showHint, bar, _("Tap the word you hear now"))
    end
    local catcher = TapCatcher:new{}
    catcher.on_tap = function(ges)
        if bar and bar._closeHint then pcall(bar._closeHint, bar) end
        local ok, res = pcall(SyncUI._syncFromTap, plugin, ges)
        if not ok then
            logger.warn("SyncUI: tap to sync failed:", res)
        elseif res then
            if on_change then pcall(on_change) end
        else
            if bar and bar._showHint then
                pcall(bar._showHint, bar, _("Couldn't tell which line that was. Try again."))
            end
        end
    end
    UIManager:show(catcher)
    -- Give up quietly after a while.
    UIManager:scheduleIn(15, function()
        pcall(function() UIManager:close(catcher) end)
    end)
end

--- The heard time of the tapped word against the narration clock.
-- @treturn bool true when the offset was set
function SyncUI._syncFromTap(plugin, ges)
    local ms = plugin.media_sync
    local doc = plugin.ui and plugin.ui.document
    local view = plugin.ui and plugin.ui.view
    if not (ms and doc and view and ges and ges.pos) then return false end
    -- Clock now, minus audio still in flight to the headset.
    local pos = ms.media_engine and ms.media_engine:getPosition() or 0
    local lat = ms.media_engine and ms.media_engine.position_latency_s or 0
    local heard = pos - lat
    local page_pos = view:screenToPageTransform(ges.pos)
    local word = page_pos and doc:getWordFromPosition(page_pos)
    if not (word and word.word and word.word ~= "") then return false end
    local sel = { text = word.word, pos0 = word.pos0, pos1 = word.pos1 }
    local entry = plugin:_matchSmilEntryFromSelection(sel, ms.timing_data, plugin._smil_parser)
    if not (entry and entry.start_time) then return false end
    -- Where the word sits in its line, by characters: that share of the
    -- line's time after its start.
    local t_word = entry.start_time
    local stext = entry.text or ""
    local e_end = entry.end_time or entry.start_time
    if stext ~= "" and e_end > entry.start_time then
        local at = stext:find(word.word, 1, true)
        if at then
            t_word = entry.start_time + (e_end - entry.start_time) * ((at - 1) / #stext)
        end
    end
    local new_ms = math.floor((heard - t_word) * 1000 + 0.5)
    -- Sanity: a tap far off (another paragraph) is not a timing error.
    if math.abs(new_ms) > 30000 then return false end
    local delta = new_ms - plugin:getSyncOffsetMs()
    logger.warn("SyncUI: tap to sync on", word.word, "heard", heard, "word at", t_word,
        "-> offset", new_ms, "ms")
    plugin:nudgeSyncOffset(delta)
    return true
end

return SyncUI
