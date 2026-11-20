--[[--
Read-along sync: how far the highlight is shifted against the narration,
shown in words and on a small scale, and the one control that changes it.

- Words, not signs: "Highlight 0.8 s later" / "Highlight 0.8 s earlier" /
  "Highlight in time with the voice".
- A small scale: a centre mark for "in time", a dot left for earlier and
  right for later.
- One control (Settings menu, or tap the sync label in the full-screen
  player): Earlier / Later, Set exact value, Reset.

Positive offsets delay the highlight (it runs behind the audio clock).

@module koplugin.audiobook.syncui
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("audiobook_gettext")
local T = require("ffi/util").template
local logger = require("logger")

local Screen = Device.screen

local SyncUI = {}

SyncUI.STEP_MS = 100        -- tap Earlier / Later
SyncUI.HOLD_STEP_MS = 1000  -- hold Earlier / Later
SyncUI.SCALE_RANGE_MS = 3000 -- the scale's ends; past them the dot waits at the end

-- ── The value ────────────────────────────────────────────────────────

--- The current offset in ms (positive = highlight later).
function SyncUI.get(plugin)
    if not plugin then return 0 end
    if plugin.getSyncOffsetMs then return tonumber(plugin:getSyncOffsetMs()) or 0 end
    return tonumber(plugin.getSetting and plugin:getSetting("smil_sync_offset_ms", 0)) or 0
end

--- Set the offset to ms; returns the new value.
function SyncUI.set(plugin, ms)
    ms = math.floor((tonumber(ms) or 0) + 0.5)
    if plugin.setSyncOffsetMs then return plugin:setSyncOffsetMs(ms) or ms end
    -- No flush: writing the whole settings file on every tap froze the UI
    -- for seconds on e-ink devices.
    plugin:setSetting("smil_sync_offset_ms", ms, true)
    return ms
end

-- ── Words ────────────────────────────────────────────────────────────

local function seconds(ms)
    return string.format("%.1f s", math.abs(ms) / 1000)
end

--- "Highlight 0.8 s later" etc.
function SyncUI.words(ms)
    ms = tonumber(ms) or 0
    if math.abs(ms) < 50 then return _("Highlight in time with the voice") end
    if ms > 0 then return T(_("Highlight %1 later"), seconds(ms)) end
    return T(_("Highlight %1 earlier"), seconds(ms))
end

--- Short form for tight spots: "0.8 s later" / "in time".
function SyncUI.short(ms)
    ms = tonumber(ms) or 0
    if math.abs(ms) < 50 then return _("In time") end
    if ms > 0 then return T(_("%1 later"), seconds(ms)) end
    return T(_("%1 earlier"), seconds(ms))
end

--- Width of the longest text words() gives in practice (up to ±99.9 s),
--- for boxes of fixed width.
function SyncUI.wordsWidth(face, bold)
    local w = 0
    for _i, v in ipairs{ 99900, -99900, 0 } do
        local p = TextWidget:new{ text = SyncUI.words(v), face = face, bold = bold }
        w = math.max(w, p:getSize().w)
        p:free()
    end
    return w
end

-- ── The scale ────────────────────────────────────────────────────────

--- A thin line with a centre mark; a dot sits left (earlier) or right
--- (later) of it. Painted, not drawn with text glyphs, so it looks the same
--- with any font.
local SyncScale = Widget:extend{
    width = nil,
    height = nil,
    offset_ms = 0,
}
SyncUI.Scale = SyncScale

function SyncScale:init()
    self.height = self.height or Screen:scaleBySize(14)
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function SyncScale:getSize()
    return self.dimen
end

function SyncScale:setOffset(ms)
    self.offset_ms = tonumber(ms) or 0
end

function SyncScale:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.width, self.height
    local d = h                  -- dot diameter
    local r = math.floor(d / 2)
    local mid_y = y + r
    local line_h = math.max(1, Size.line.medium or 1)
    local cx = x + math.floor(w / 2)
    -- Track.
    bb:paintRect(x + r, mid_y - math.floor(line_h / 2), w - d, line_h, Blitbuffer.COLOR_DARK_GRAY)
    -- End ticks (short) and the centre mark (full height).
    local tick_w = math.max(1, Size.line.thick or 2)
    local end_h = math.floor(h / 2)
    bb:paintRect(x + r, mid_y - math.floor(end_h / 2), tick_w, end_h, Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(x + w - r - tick_w, mid_y - math.floor(end_h / 2), tick_w, end_h, Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(cx - math.floor(tick_w / 2), y, tick_w, h, Blitbuffer.COLOR_BLACK)
    -- The dot.
    local frac = self.offset_ms / SyncUI.SCALE_RANGE_MS
    frac = math.max(-1, math.min(1, frac))
    local dot_cx = cx + math.floor(frac * (w / 2 - r) + 0.5)
    bb:paintRoundedRect(dot_cx - r, y, d, d, Blitbuffer.COLOR_BLACK, r)
end

-- ── The label in the full-screen player ──────────────────────────────

--- Words over a scale, in a fixed box (w × h) so updates repaint in place.
--- The words step down to the short form when the long one doesn't fit.
local SyncLabel = WidgetContainer:extend{
    width = nil,
    height = nil,
    offset_ms = 0,
    font_size = 16,
}
SyncUI.Label = SyncLabel

function SyncLabel:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self._face = Font:getFace("cfont", self.font_size)
    self._text = TextWidget:new{ text = "", face = self._face, max_width = self.width }
    self._scale = SyncScale:new{
        width = math.floor(self.width * 0.8),
        height = Screen:scaleBySize(10),
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        VerticalGroup:new{
            align = "center",
            self._text,
            VerticalSpan:new{ width = Size.padding.small },
            self._scale,
        },
    }
    self:setOffset(self.offset_ms)
end

function SyncLabel:setOffset(ms)
    self.offset_ms = tonumber(ms) or 0
    local text = SyncUI.words(self.offset_ms)
    local probe = TextWidget:new{ text = text, face = self._face }
    if probe:getSize().w > self.width then text = SyncUI.short(self.offset_ms) end
    probe:free()
    self._text:setText(text)
    self._scale:setOffset(self.offset_ms)
end

function SyncLabel:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self[1]:paintTo(bb, x, y)
end

-- ── The control ──────────────────────────────────────────────────────

local SyncControl = InputContainer:extend{
    name = "AudiobookSyncControl",
    plugin = nil,
    modal = true,
}

function SyncControl:init()
    local plugin = self.plugin
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local w = math.floor(math.min(sw, sh) * 0.9)
    local inner_w = w - 2 * (Size.padding.large + Size.border.window)
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end

    -- Words in a box of fixed width, so changes repaint in place.
    local face = Font:getFace("cfont", 22)
    self._words = TextWidget:new{
        text = SyncUI.words(SyncUI.get(plugin)),
        face = face, bold = true, max_width = inner_w,
    }
    self._scale = SyncScale:new{
        width = math.floor(inner_w * 0.85),
        height = Screen:scaleBySize(16),
        offset_ms = SyncUI.get(plugin),
    }
    -- "earlier" under the left end, "later" under the right end.
    local ends_face = Font:getFace("cfont", 14)
    local left = TextWidget:new{ text = _("earlier"), face = ends_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
    local right = TextWidget:new{ text = _("later"), face = ends_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
    local gap = math.max(0, self._scale.width - left:getSize().w - right:getSize().w)
    local scale_ends = HorizontalGroup:new{ left, HorizontalSpan:new{ width = gap }, right }
    local help = TextBoxWidget:new{
        text = _("Highlight ahead of the voice: Later. Behind it: Earlier.\nTap moves 0.1 s, hold moves 1 s. Changes apply at once."),
        face = Font:getFace("cfont", 15),
        width = inner_w,
        alignment = "center",
    }

    local function nudge(delta)
        return function() self:change(SyncUI.get(plugin) + delta) end
    end
    local buttons = {
        {
            { text = _("Earlier"), callback = nudge(-SyncUI.STEP_MS),
              hold_callback = nudge(-SyncUI.HOLD_STEP_MS) },
            { text = _("Later"), callback = nudge(SyncUI.STEP_MS),
              hold_callback = nudge(SyncUI.HOLD_STEP_MS) },
        },
        {
            { text = _("Exact…"), callback = function() self:askExact() end },
            { text = _("Reset"), callback = function() self:change(0) end },
            { text = _("Close"), callback = function() self:onClose() end },
        },
    }
    -- Tap to sync goes first in the second row when that feature is there.
    if plugin.startTapToSync then
        table.insert(buttons[2], 1, { text = _("Tap to sync"), callback = function()
            self:onClose()
            plugin:startTapToSync(function()
                SyncUI.refreshPlayer(plugin)
                if self.on_change then pcall(self.on_change, SyncUI.get(plugin)) end
            end)
        end })
    end
    self.button_table = ButtonTable:new{
        width = inner_w,
        buttons = buttons,
        zero_sep = true,
        show_parent = self,
    }

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.large,
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = self._words:getSize().h },
                self._words,
            },
            VerticalSpan:new{ width = Size.padding.default },
            self._scale,
            scale_ends,
            VerticalSpan:new{ width = Size.padding.default },
            help,
            VerticalSpan:new{ width = Size.padding.large },
            self.button_table,
        },
    }
    self[1] = CenterContainer:new{ dimen = Geom:new{ w = sw, h = sh }, self.frame }
end

--- Set a new offset, then repaint just the dialog and the player's label.
function SyncControl:change(ms)
    local v = SyncUI.set(self.plugin, ms)
    self._words:setText(SyncUI.words(v))
    self._scale:setOffset(v)
    UIManager:setDirty(self, function() return "fast", self.frame.dimen end)
    SyncUI.refreshPlayer(self.plugin)
    if self.on_change then pcall(self.on_change, v) end
end

function SyncControl:askExact()
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("Highlight timing"),
        info_text = _("Seconds later. A minus sign means earlier."),
        value = SyncUI.get(self.plugin) / 1000,
        value_min = -60,
        value_max = 60,
        value_step = 0.1,
        value_hold_step = 1,
        precision = "%.1f",
        ok_text = _("Set"),
        callback = function(spin) self:change(spin.value * 1000) end,
    })
end

function SyncControl:onTapOutside(_arg, ges)
    if ges and ges.pos and self.frame.dimen and ges.pos:notIntersectWith(self.frame.dimen) then
        self:onClose()
    end
    return true
end

function SyncControl:onClose()
    UIManager:close(self, "ui", self.frame.dimen)
    return true
end

function SyncControl:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
    return true
end

--- The full-screen player's label after a change made here.
function SyncUI.refreshPlayer(plugin)
    local ms = plugin and plugin.media_sync
    local bar = ms and ms.playback_bar
    if bar and bar.refreshSyncLabel then pcall(bar.refreshSyncLabel, bar) end
end

--- Open the control. opts.on_change(ms) is called after each change.
function SyncUI.showControl(plugin, opts)
    if not plugin then return end
    local ctl = SyncControl:new{ plugin = plugin, on_change = opts and opts.on_change }
    UIManager:show(ctl)
    return ctl
end


-- ── After a change: tag, outline, spoken word ────────────────────────

SyncUI.FEEDBACK_S = 3        -- tag / outline / word lighting after a change
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

return SyncUI
