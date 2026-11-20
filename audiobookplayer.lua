--[[--
AudiobookPlayer -- Full-screen overlay widget for standalone audio playback.
Designed for e-ink: large tap targets, minimal refreshes, no images.

Layout:
  [☰]         Title        [spd] [▼] [✕]
  +---------------------------+
  |       Cover art           |
  +---------------------------+
        Chapter / metadata
           3:24 / 12:45
  [======== progress bar =====]
  [⏴30] [⏮] [⏸] [⏭] [30⏵]

Minimized: a small bottom bar with restore + play/pause + title

@module koplugin.audiobook.audiobookplayer
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local RenderText = require("ui/rendertext")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local logger = require("logger")
local _ = require("audiobook_gettext")
local T = require("ffi/util").template

local FocusManager = require("ui/widget/focusmanager")
-- FocusManager (an InputContainer) gives the full-screen player key and
-- D-pad navigation; the minimized bar passes keys through (handleEvent).
local AudiobookPlayer = FocusManager:extend{
    plugin = nil,
    is_playing = true,
    progress = 0,
    current_time_str = "0:00 / 0:00",
    title = "",
    chapter_title = "",
    output_name = "",
    cover_image_path = nil,
    playback_speed = 1.0,
    -- Plugin chrome: the TTS PlaybackBar:_isOverlayActive must not treat this
    -- mini bar as a menu/dialog (and vice versa).
    _plugin_chrome = true,
    -- Time display mode: "book" = position-in-book, "chapter" = position-in-chapter
    _time_display_mode = "book",
    _current_chapter_start = 0,
    _current_chapter_end = 0,
    _sleep_timer_remaining = 0,
    _sleep_timer_active = false,
    -- Callbacks
    on_play_pause = nil,
    on_skip_back = nil,
    on_skip_forward = nil,
    on_fix_audio = nil,
    show_fix_audio = false,
    -- When true, mini bar sits above KOReader's bottom status bar.
    keep_reader_status_bars = false,
    on_prev_chapter = nil,
    on_next_chapter = nil,
    on_seek = nil,
    on_close = nil,
    on_minimize = nil,
    on_chapter_list = nil,
    on_speed = nil,
    on_shuffle = nil,
    show_shuffle = false,
    shuffle_active = false,
    on_loop = nil,
    show_loop = false,
    loop_active = false,
    on_volume = nil,
    -- on_skip_line(n): move n narrated lines (read-along only).
    on_skip_line = nil,
    -- on_skip_page(dir): hold on the line buttons; -1 top of this page
    -- (or the previous one), +1 next page.
    on_skip_page = nil,
    volume_pct = 100,
    on_sleep_timer_set = nil,
    on_sleep_timer_cancel = nil,
    on_refocus = nil,
    -- TTS read-along: same chrome as aligned overlay, but speed/sleep on the
    -- mini bar instead of SMIL sync-offset nudges, plus a settings picker.
    tts_mode = false,
    on_tts_settings = nil,
    -- Optional (settings, off by default).  large_mini_bar: a taller mini
    -- bar with bigger tap targets (_buildLargeMiniBar).  lines_mode: the
    -- full-screen read-along player shows the narration line by line
    -- (previous / current / next sentence, see setLines) in place of the
    -- cover, plus a sync row.
    large_mini_bar = false,
    lines_mode = false,
    -- TTS read-along only: hide_tts_progress_bar drops the scrubber row from
    -- the full player (the widget still exists for the scrub/seek code).
    show_progress = true,
    -- Reference to the underlying ReaderUI or FileManager widget for event
    -- forwarding when minimized (since UIManager only dispatches to the top
    -- widget, we must manually forward events to the UI below).
    ui_widget = nil,
}

-- Read JPEG width/height from file headers without loading the image.
local function _jpegDimensions(path)
    local f = io.open(path, "rb")
    if not f then return nil, nil end
    local data = f:read(2)
    if data ~= "\xff\xd8" then
        f:close()
        return nil, nil
    end
    while true do
        local marker = f:read(2)
        if not marker then break end
        if marker:byte(1) ~= 0xFF then
            f:close()
            return nil, nil
        end
        local mtype = marker:byte(2)
        while mtype == 0xFF do
            local b = f:read(1)
            if not b then f:close(); return nil, nil end
            mtype = b:byte(1)
        end
        if mtype == 0xD9 then break end -- EOI
        -- markers without payload
        if mtype == 0xD8 or mtype == 0x01 then
            -- continue
        elseif mtype >= 0xD0 and mtype <= 0xD9 then
            -- continue
        else
            local len_b = f:read(2)
            if not len_b or #len_b < 2 then break end
            local len = len_b:byte(1) * 256 + len_b:byte(2)
            -- SOF0 / SOF1 / SOF2 contain dimensions
            if mtype == 0xC0 or mtype == 0xC1 or mtype == 0xC2 then
                local sof = f:read(5)
                if sof and #sof == 5 then
                    local h = sof:byte(2) * 256 + sof:byte(3)
                    local w = sof:byte(4) * 256 + sof:byte(5)
                    f:close()
                    return w, h
                end
                break
            else
                if len > 2 then
                    f:seek("cur", len - 2)
                end
            end
        end
    end
    f:close()
    return nil, nil
end

function AudiobookPlayer:_isEink()
    return Device.hasEinkScreen and Device:hasEinkScreen()
end

-- ── Icons ────────────────────────────────────────────────────────────
-- The plugin ships its own SVG icons in <plugin>/icons/ab.<name>.svg (the
-- font glyphs ⏸ ⏮ ♪ render thin and small on e-ink). KOReader's Button only
-- takes an icon *name*, looked up under resources/icons/mdlight, so ours are
-- named by a path relative to that directory. nil when the files cannot be
-- reached that way; callers then fall back to the old text label.
local _icon_prefix -- false once resolution failed
function AudiobookPlayer:_iconName(name)
    if _icon_prefix == nil then
        _icon_prefix = false
        local dir = self.plugin and self.plugin.path
        if dir and dir:sub(1, 1) == "/" then
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            local cwd = ok_lfs and lfs.currentdir and lfs.currentdir()
            if cwd and dir:sub(1, #cwd + 1) == cwd .. "/" then
                dir = dir:sub(#cwd + 2)
            else
                dir = nil
            end
        end
        if dir and dir ~= "" then
            local probe = io.open(dir .. "/icons/ab.play.svg", "r")
            if probe then
                probe:close()
                _icon_prefix = "../../../" .. dir .. "/icons/ab."
            end
        end
    end
    return _icon_prefix and (_icon_prefix .. name) or nil
end

--- A button showing one of the plugin's icons (text fallback). opts:
--- width (defaults to size), icon_ratio (icon size / button height),
--- bordersize, radius, font_size (fallback text).
function AudiobookPlayer:_iconButton(icon, fallback_text, size, callback, opts)
    opts = opts or {}
    local args = {
        width = opts.width or size,
        height = size,
        callback = callback,
        bordersize = opts.bordersize or 0,
        radius = opts.radius,
        show_parent = self,
    }
    local name = self:_iconName(icon)
    if name then
        local isz = math.floor(size * (opts.icon_ratio or 0.6))
        args.icon = name
        args.icon_width = isz
        args.icon_height = isz
    else
        args.text = fallback_text
        args.text_font_size = opts.font_size or 22
    end
    return Button:new(args)
end

--- Show play or pause on a play/pause button, icon or text.
function AudiobookPlayer:_refreshPlayButton(btn)
    if not btn then return end
    if btn.icon then
        btn:setIcon(self:_iconName(self.is_playing and "pause" or "play"), btn.width)
    else
        btn:setText(self.is_playing and "⏸" or "▶", btn.width)
    end
end

--- Sit above KOReader's footer when the user asked to keep it, or when the
--- footer is a real page chrome (Overlap status bar off). Otherwise the mini
--- player paints on top of the progress bar and e-ink ghosts a second bar.
function AudiobookPlayer:_shouldSitAboveFooter()
    if self.keep_reader_status_bars then return true end
    local ui = self.ui_widget or (self.plugin and self.plugin.ui)
    local view = ui and ui.view
    if not (view and view.footer_visible and view.footer) then return false end
    return not view.footer.reclaim_height
end

function AudiobookPlayer:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self._minimized = false
    -- Do not claim the whole screen / footer while the mini player is up —
    -- otherwise ReaderFooter may skip updates ("lost" status bar).
    self.covers_fullscreen = false
    self.covers_footer = not self:_shouldSitAboveFooter()
    self._return_hint_active = false
    self._rotation_mode = Screen:getRotationMode()
    -- Where the user dragged the bar over menus (fraction of screen height).
    if self.plugin and self.plugin.getSetting then
        self._menu_y_pct = tonumber(self.plugin:getSetting("bar_menu_y_pct", nil))
    end
    self:setupUI()
end

function AudiobookPlayer:setupUI()
    -- Sized for fingers on e-ink: the transport buttons were 56, which was
    -- easy to miss; the top row stays a little smaller to fit the title.
    local button_size = Screen:scaleBySize(68)
    local top_size = Screen:scaleBySize(60)
    local spacing = Size.padding.large

    -- ── Top row: chapter list | title | speed | minimize | close ──
    self.chapter_list_button = self:_iconButton("chapters", "☰", top_size,
        function() self:onChapterList() end)

    self.sleep_timer_button = self:_iconButton("timer", "⏲", top_size,
        function() self:onSleepTimer() end)

    -- Read-along: go back to the line being read (close the player, turn
    -- the book to that line). Lives here, not on the bar, where Back does it.
    if self.on_refocus then
        self.locate_button = self:_iconButton("locate", "◎", top_size, function()
            self:onMinimize()
            self:onRefocus()
        end)
    else
        self.locate_button = nil
    end

    self.speed_button = Button:new{
        text = self:_speedText(),
        width = top_size,
        height = top_size,
        text_font_size = 18,
        text_font_bold = true,
        callback = function() self:onSpeed() end,
        bordersize = 0,
        show_parent = self,
    }

    self.minimize_button = self:_iconButton("minimize", "▼", top_size,
        function() self:onMinimize() end)

    self.close_button = self:_iconButton("close", "✕", top_size,
        function() self:onClose() end, { icon_ratio = 0.5 })

    self.shuffle_button = Button:new{
        text = "⇄",
        width = top_size,
        height = top_size,
        text_font_size = 20,
        callback = function() self:onShuffle() end,
        bordersize = self.shuffle_active and Size.border.default or 0,
        radius = Screen:scaleBySize(4),
        show_parent = self,
    }

    self.loop_button = Button:new{
        text = "⟳",
        width = top_size,
        height = top_size,
        text_font_size = 20,
        callback = function() self:onLoop() end,
        bordersize = self.loop_active and Size.border.default or 0,
        radius = Screen:scaleBySize(4),
        show_parent = self,
    }

    -- Kindle AirPods: reconnect A2DP when the stream goes silent mid-play.
    self.fix_audio_button = Button:new{
        text = _("BT"),
        width = top_size,
        height = top_size,
        text_font_size = 14,
        callback = function() self:onFixAudio() end,
        bordersize = 0,
        show_parent = self,
    }

    -- Count visible buttons for title width calculation
    local visible_buttons = 5 -- chapter_list, sleep_timer, speed, minimize, close
    if self.show_shuffle then visible_buttons = visible_buttons + 1 end
    if self.show_loop then visible_buttons = visible_buttons + 1 end
    if self.show_fix_audio then visible_buttons = visible_buttons + 1 end
    if self.tts_mode then visible_buttons = visible_buttons + 1 end
    if self.locate_button then visible_buttons = visible_buttons + 1 end
    -- The title wraps onto a second line (ellipsis after that) instead of
    -- being cut from the left on one line.
    local title_w = self.width - top_size * visible_buttons - spacing * visible_buttons
    local title_face = Font:getFace("cfont", 18)
    self.title_widget = TextBoxWidget:new{
        text = self.title or _("Audiobook"),
        face = title_face,
        width = title_w,
        alignment = "center",
    }
    local lh = self.title_widget.line_height_px
    if lh and self.title_widget:getSize().h > lh * 2 then
        self.title_widget:free()
        self.title_widget = TextBoxWidget:new{
            text = self.title or _("Audiobook"),
            face = title_face,
            width = title_w,
            alignment = "center",
            height = lh * 2,
            height_overflow_show_ellipsis = true,
        }
    end

    -- Build top row left-to-right explicitly
    local top_row_items = {
        align = "center",
        self.chapter_list_button,
        HorizontalSpan:new{ width = spacing },
        self.sleep_timer_button,
        HorizontalSpan:new{ width = math.floor(spacing / 2) },
    }
    if self.locate_button then
        table.insert(top_row_items, self.locate_button)
        table.insert(top_row_items, HorizontalSpan:new{ width = math.floor(spacing / 2) })
    end
    if self.show_shuffle then
        table.insert(top_row_items, self.shuffle_button)
        table.insert(top_row_items, HorizontalSpan:new{ width = math.floor(spacing / 2) })
    end
    if self.show_loop then
        table.insert(top_row_items, self.loop_button)
        table.insert(top_row_items, HorizontalSpan:new{ width = math.floor(spacing / 2) })
    end
    if self.show_fix_audio then
        table.insert(top_row_items, self.fix_audio_button)
        table.insert(top_row_items, HorizontalSpan:new{ width = math.floor(spacing / 2) })
    end
    table.insert(top_row_items, CenterContainer:new{
        dimen = Geom:new{ w = self.title_widget:getSize().w,
            h = math.max(top_size, self.title_widget:getSize().h) },
        self.title_widget,
    })
    table.insert(top_row_items, HorizontalSpan:new{ width = spacing })
    table.insert(top_row_items, self.speed_button)
    table.insert(top_row_items, HorizontalSpan:new{ width = math.floor(spacing / 2) })
    if self.tts_mode then
        self.settings_button = Button:new{
            text = "⚙",
            width = top_size,
            height = top_size,
            text_font_size = 20,
            callback = function() self:onTtsSettings() end,
            bordersize = 0,
            show_parent = self,
        }
        table.insert(top_row_items, self.settings_button)
        table.insert(top_row_items, HorizontalSpan:new{ width = math.floor(spacing / 2) })
    end
    table.insert(top_row_items, self.minimize_button)
    table.insert(top_row_items, HorizontalSpan:new{ width = math.floor(spacing / 2) })
    table.insert(top_row_items, self.close_button)
    local top_row = HorizontalGroup:new(top_row_items)

    -- ── Cover art placeholder ──
    -- Compute cover frame size dynamically based on the actual image aspect ratio.
    -- The frame is sized to match the image shape, capped at 45% of screen height.
    local padding = Size.padding.small
    local max_cover_h = math.floor(math.min(self.width, self.height) * 0.45)
    local img_w, img_h = nil, nil
    if self.cover_image_path then
        img_w, img_h = _jpegDimensions(self.cover_image_path)
    end
    if img_w and img_h and img_w > 0 and img_h > 0 then
        local avail_w = self.width - padding * 2
        local scale = math.min(avail_w / img_w, max_cover_h / img_h)
        self._cover_width = math.floor(img_w * scale)
        self._cover_height = math.floor(img_h * scale)
    else
        -- Fallback: use a generous square-ish frame when no image is available
        self._cover_width = math.floor(self.width * 0.6)
        self._cover_height = math.min(self._cover_width, max_cover_h)
    end
    if self.lines_mode then
        local is_wide = self.width > self.height
        self._cover_width = self.width - spacing * 4
        -- Portrait also carries the sync row, so leave it room.
        -- (0.38 before the controls grew; they need the room now.)
        self._cover_height = is_wide and max_cover_h or math.floor(self.height * 0.33)
        self.cover_frame = self:_buildLinesFrame()
    else
        self._line_slots = nil
        self.cover_frame = self:_buildCoverFrame()
    end

    -- ── Metadata under cover ──
    self.chapter_widget = TextWidget:new{
        text = self.chapter_title or "",
        face = Font:getFace("cfont", 16),
        max_width = self.width - spacing * 4,
        truncate_left = true,
    }

    -- Multi-line filename: wrap into up to 2 lines so long filenames are readable.
    self.output_widget = self:_buildOutputWidget(self.output_name or "")

    -- ── Time display ──
    self.time_widget = TextWidget:new{
        text = self.current_time_str or "0:00 / 0:00",
        face = Font:getFace("cfont", 18),
        max_width = self.width - spacing * 4,
    }

    -- ── Progress bar ──
    local bar_height = Screen:scaleBySize(10)
    self.progress_bar = ProgressWidget:new{
        width = self.width - spacing * 4,
        height = bar_height,
        percentage = self.progress / 100,
        fillcolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
        bordersize = 0,
        margin_h = 0,
        margin_v = 0,
        radius = Screen:scaleBySize(5),
    }

    self._scrubber_touch_height = Screen:scaleBySize(40)
    self._scrubber_dragging = false
    self._scrubber_drag_pct = nil

    -- ── Playback controls ──
    -- Outlined, icon-labelled; play/pause is the widest so it is the
    -- easiest to hit.  The 30 s skips keep a text label ("−30" / "+30"):
    -- the number is the whole message.
    local outline = { bordersize = Size.border.thin, radius = Screen:scaleBySize(8) }
    local function outlined(extra)
        local o = { bordersize = outline.bordersize, radius = outline.radius }
        for k, v in pairs(extra or {}) do o[k] = v end
        return o
    end
    local function textButton(text, callback)
        return Button:new{
            text = text,
            width = button_size,
            height = button_size,
            text_font_size = 20,
            text_font_bold = true,
            callback = callback,
            bordersize = outline.bordersize,
            radius = outline.radius,
            show_parent = self,
        }
    end

    self.skip_back_button = textButton("−30", function() self:onSkipBack() end)
    self.skip_forward_button = textButton("+30", function() self:onSkipForward() end)

    self.prev_chapter_button = self:_iconButton("chapter.prev", "⏮", button_size,
        function() self:onPrevChapter() end, outlined())
    self.next_chapter_button = self:_iconButton("chapter.next", "⏭", button_size,
        function() self:onNextChapter() end, outlined())

    self.play_pause_button = self:_iconButton(self.is_playing and "pause" or "play",
        self.is_playing and "⏸" or "▶", button_size,
        function() self:onPlayPause() end,
        outlined{ width = math.floor(button_size * 1.4), icon_ratio = 0.7,
            bordersize = Size.border.thick, font_size = 30 })

    -- Line skip: one narrated sentence per tap (read-along only).
    if self.on_skip_line then
        self.line_back_button = self:_iconButton("line.back", "◂≡", button_size,
            function() self.on_skip_line(-1) end, outlined())
        self.line_forward_button = self:_iconButton("line.forward", "≡▸", button_size,
            function() self.on_skip_line(1) end, outlined())
    else
        self.line_back_button, self.line_forward_button = nil, nil
    end

    -- ── Volume controls (used in both orientations) ──
    self.volume_widget = TextWidget:new{
        text = self:_volumeText(),
        face = Font:getFace("cfont", 20),
        bold = true,
    }
    self.vol_minus_button = self:_iconButton("volume.down", "−", button_size,
        function() self:_applyVolume(-10) end, outlined())
    self.vol_plus_button = self:_iconButton("volume.up", "+", button_size,
        function() self:_applyVolume(10) end, outlined())

    local is_landscape = self.width > self.height
    -- Line-by-line view: sync adjusters, same job as the mini bar's − / +.
    local sync_row
    if self.lines_mode and self.on_sync_nudge and not is_landscape then
        -- The shift in words over a small scale; tapping it opens the sync
        -- control. Plain text if the sync UI didn't load.
        local SyncUI = self:_syncUI()
        if SyncUI then
            self.sync_widget = SyncUI.Label:new{
                width = top_size * 3,
                height = top_size,
                font_size = 15,
                offset_ms = self:_syncOffset(),
            }
        else
            self.sync_widget = TextWidget:new{
                text = self:_syncText(),
                face = Font:getFace("cfont", 16),
            }
        end
        local function syncButton(text, delta)
            return Button:new{
                text = text,
                width = top_size,
                height = top_size,
                text_font_size = 24,
                callback = function() self:_nudgeSync(delta) end,
                bordersize = Size.border.thin,
                radius = Screen:scaleBySize(6),
                show_parent = self,
            }
        end
        self.sync_minus_button = syncButton("−", -100)
        self.sync_plus_button = syncButton("+", 100)
        self._sync_label_box = CenterContainer:new{
            dimen = Geom:new{ w = top_size * 3, h = top_size },
            self.sync_widget,
        }
        sync_row = HorizontalGroup:new{
            align = "center",
            self.sync_minus_button,
            HorizontalSpan:new{ width = spacing },
            self._sync_label_box,
            HorizontalSpan:new{ width = spacing },
            self.sync_plus_button,
        }
    else
        self.sync_widget, self.sync_minus_button, self.sync_plus_button = nil, nil, nil
        self._sync_label_box = nil
    end

    local control_row, volume_row
    if is_landscape then
        -- Landscape: single row [-] [<30] [<<] [play] [>>] [30>] [+] [90%]
        -- Transport/volume buttons are centered on the full screen width;
        -- the percentage label sits at the right edge and does not shift the center.
        local inner_span = math.floor(spacing / 2)
        local button_group_w = button_size * 6 + self.play_pause_button.width
            + inner_span * 2
            + spacing * 6
        -- Read-along: the line skips take the chapter buttons' places.
        local left_nav = self.line_back_button or self.prev_chapter_button
        local right_nav = self.line_forward_button or self.next_chapter_button
        local vol_w = self.volume_widget:getSize().w
        local right_span = spacing
        local left_span = math.max(0, math.floor((self.width - button_group_w) / 2))
        local mid_span = math.max(0, self.width - left_span - button_group_w - vol_w - right_span)
        control_row = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = left_span },
            self.vol_minus_button,
            HorizontalSpan:new{ width = inner_span },
            self.skip_back_button,
            HorizontalSpan:new{ width = spacing },
            left_nav,
            HorizontalSpan:new{ width = spacing * 2 },
            self.play_pause_button,
            HorizontalSpan:new{ width = spacing * 2 },
            right_nav,
            HorizontalSpan:new{ width = spacing },
            self.skip_forward_button,
            HorizontalSpan:new{ width = inner_span },
            self.vol_plus_button,
            HorizontalSpan:new{ width = mid_span },
            self.volume_widget,
            HorizontalSpan:new{ width = right_span },
        }
    else
        -- Portrait: transport row, then a second row.
        -- With line skip:  [−30] [◂line] [ PLAY ] [line▸] [+30]
        --                  [⏮] [vol−]  40%  [vol+] [⏭]
        -- Without:         [−30] [⏮] [ PLAY ] [⏭] [+30] / [vol−] 40% [vol+]
        local gap = spacing
        local function row(items)
            local t = { align = "center" }
            for i, w in ipairs(items) do
                if i > 1 then table.insert(t, HorizontalSpan:new{ width = gap }) end
                table.insert(t, w)
            end
            return HorizontalGroup:new(t)
        end
        local vol_label = CenterContainer:new{
            dimen = Geom:new{ w = math.floor(button_size * 1.6), h = button_size },
            self.volume_widget,
        }
        if self.line_back_button then
            control_row = row{ self.skip_back_button, self.line_back_button,
                self.play_pause_button, self.line_forward_button, self.skip_forward_button }
            volume_row = row{ self.prev_chapter_button, self.vol_minus_button,
                vol_label, self.vol_plus_button, self.next_chapter_button }
        else
            control_row = row{ self.skip_back_button, self.prev_chapter_button,
                self.play_pause_button, self.next_chapter_button, self.skip_forward_button }
            volume_row = row{ self.vol_minus_button, vol_label, self.vol_plus_button }
        end
    end

    -- ── Assemble full layout ──
    local content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.padding.small },
        top_row,
        VerticalSpan:new{ width = self.height * 0.025 },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self._cover_height },
            self.cover_frame,
        },
        VerticalSpan:new{ width = self.height * 0.015 },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.chapter_widget:getSize().h },
            self.chapter_widget,
        },
        VerticalSpan:new{ width = math.floor(self.height * 0.006) },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.output_widget:getSize().h },
            self.output_widget,
        },
        VerticalSpan:new{ width = self.height * 0.015 },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.time_widget:getSize().h },
            self.time_widget,
        },
    }
    -- In TTS read-along the sentence highlight already shows position, so
    -- hide_tts_progress_bar (show_progress = false) drops the scrubber row.
    -- The widget always exists (scrub/seek code references it); it is simply
    -- not in the visible tree, same convention as PlaybackBar.
    if not (self.tts_mode and self.show_progress == false) then
        table.insert(content, VerticalSpan:new{ width = spacing })
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = bar_height + self._scrubber_touch_height },
            self.progress_bar,
        })
    end
    table.insert(content, VerticalSpan:new{ width = self.height * 0.025 })
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = button_size },
        control_row,
    })
    if not is_landscape then
        table.insert(content,
            VerticalSpan:new{ width = self.height * 0.02 })
        table.insert(content,
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = button_size },
                volume_row,
            })
    end
    if sync_row then
        table.insert(content,
            VerticalSpan:new{ width = self.height * 0.02 })
        table.insert(content,
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = button_size },
                sync_row,
            })
    end
    table.insert(content, VerticalSpan:new{ width = Size.padding.small })

    -- Match the reader's configured background color so the player blends with
    -- the user's theme instead of forcing pure white.
    local bg_color = self:_getThemeBackground()
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        background = bg_color,
        bordersize = 0,
        padding = 0,
        content,
    }

    self.dimen = self[1]:getSize()
    self.dimen.x = 0
    self.dimen.y = 0

    -- Key / D-pad navigation of the full-screen player (FocusManager):
    -- rows as they appear on screen; arrows move, Press presses.
    local function row(...)
        local r = {}
        for i = 1, select("#", ...) do
            local w = select(i, ...)
            if w then table.insert(r, w) end
        end
        return r
    end
    local nav = {}
    local function add_row(r) if #r > 0 then table.insert(nav, r) end end
    add_row(row(self.chapter_list_button, self.sleep_timer_button, self.locate_button,
        self.show_shuffle and self.shuffle_button or false,
        self.show_loop and self.loop_button or false,
        self.speed_button, self.tts_mode and self.settings_button or false,
        self.minimize_button, self.close_button))
    add_row(row(self.skip_back_button, self.line_back_button or false, self.play_pause_button,
        self.line_forward_button or false, self.skip_forward_button))
    add_row(row(self.prev_chapter_button, self.vol_minus_button, self.vol_plus_button,
        self.next_chapter_button))
    add_row(row(self.sync_minus_button or false, self.sync_plus_button or false))
    self.layout = nav
    self._play_row = 2
    -- Start on Play.
    self.selected = { x = 1, y = 1 }
    if nav[2] then
        for i, w in ipairs(nav[2]) do
            if w == self.play_pause_button then self.selected = { x = i, y = 2 } end
        end
    end
    -- Back minimizes (the ✕ button stops playback; a key should not).
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.MinimizeKey = { { "Back" }, event = "Minimize" }
    end

    -- ── Mini-player bar (shown when minimized) ──
    self._mini_height = Screen:scaleBySize(44)
    local mini_btn_size = self._mini_height - 20  -- keep clear of the mini bar border

    self._mini_play_pause = Button:new{
        text = self.is_playing and "⏸" or "▶",
        width = mini_btn_size,
        height = mini_btn_size,
        text_font_size = 18,
        callback = function() self:onPlayPause() end,
        bordersize = 0,
        show_parent = self,
    }

    self._mini_close = Button:new{
        text = "✕",
        width = mini_btn_size,
        height = mini_btn_size,
        text_font_size = 16,
        callback = function() self:onClose() end,
        bordersize = 0,
        show_parent = self,
    }

    local refocus_group = {}
    if self.on_refocus then
        self._mini_refocus = Button:new{
            text = "○",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 18,
            callback = function() self:onRefocus() end,
            bordersize = 0,
            show_parent = self,
        }
        refocus_group = {
            self._mini_refocus,
            HorizontalSpan:new{ width = math.floor(spacing / 2) },
        }
    end

    -- Center: title + time stacked and centered.
    -- Width is reduced as optional side button groups are added; the actual
    -- TextWidgets are created after center_max_width is final.
    local center_max_width = self.width - mini_btn_size * 2 - spacing * 4
    if self.on_refocus then
        center_max_width = center_max_width - mini_btn_size - spacing
    end

    -- Read-along: live sync-offset nudge buttons.  The sync loop reads the
    -- setting every tick, so each press shifts the highlight immediately;
    -- the new value flashes in the mini time display until the next
    -- regular time update overwrites it.
    -- TTS: this slot holds the speed button and the settings gear.  TTS has no
    -- full-screen player, so the gear is the way into voice, speed, pauses,
    -- volume and the sleep timer.
    local nudge_group = {}
    if self.tts_mode then
        self._mini_speed = Button:new{
            text = self:_speedText(),
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 11,
            callback = function() self:onSpeed() end,
            bordersize = 0,
            show_parent = self,
        }
        self._mini_settings = Button:new{
            text = "⚙",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 16,
            callback = function() self:onTtsSettings() end,
            bordersize = 0,
            show_parent = self,
        }
        center_max_width = center_max_width - (mini_btn_size + spacing) * 2
        nudge_group = {
            self._mini_speed,
            HorizontalSpan:new{ width = spacing },
            self._mini_settings,
            HorizontalSpan:new{ width = spacing },
        }
    elseif self.on_sync_nudge then
        local function nudge(delta_ms)
            self:_nudgeSync(delta_ms)
        end
        self._mini_sync_minus = Button:new{
            text = "−",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 16,
            callback = function() nudge(-100) end,
            bordersize = 0,
            show_parent = self,
        }
        self._mini_sync_plus = Button:new{
            text = "+",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 16,
            callback = function() nudge(100) end,
            bordersize = 0,
            show_parent = self,
        }
        center_max_width = center_max_width - (mini_btn_size + spacing) * 2
        nudge_group = {
            self._mini_sync_minus,
            HorizontalSpan:new{ width = spacing },
            self._mini_sync_plus,
            HorizontalSpan:new{ width = spacing },
        }
    end

    -- Volume nudge buttons (♪− / ♪+).  These belong to audiobook and music
    -- playback; TTS reaches volume from its settings gear instead, so its
    -- mini bar stays uncluttered.
    local vol_group = {}
    if not self.tts_mode and self.on_volume then
        self._mini_vol_minus = Button:new{
            text = "♪−",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 13,
            callback = function() self:_applyVolume(-10) end,
            bordersize = 0,
            show_parent = self,
        }
        self._mini_vol_plus = Button:new{
            text = "♪+",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 13,
            callback = function() self:_applyVolume(10) end,
            bordersize = 0,
            show_parent = self,
        }
        center_max_width = center_max_width - (mini_btn_size + spacing) * 2
        vol_group = {
            self._mini_vol_minus,
            HorizontalSpan:new{ width = spacing },
            self._mini_vol_plus,
            HorizontalSpan:new{ width = spacing },
        }
    end

    -- Chapter list on the mini bar (overlay): avoids expanding the fullscreen
    -- player just to tap ☰, which was crashing on Boox.
    local chapter_group = {}
    if self.on_chapter_list then
        self._mini_chapters = Button:new{
            text = "☰",
            width = mini_btn_size,
            height = mini_btn_size,
            text_font_size = 16,
            callback = function() self:onChapterList() end,
            bordersize = 0,
            show_parent = self,
        }
        center_max_width = center_max_width - mini_btn_size - spacing
        chapter_group = {
            self._mini_chapters,
            HorizontalSpan:new{ width = spacing },
        }
    end

    -- Create the centered title stack now that side buttons have reserved
    -- their full width, so the text cannot overlap the volume/sync buttons.
    -- TTS carries no time on the bar: read-along has no meaningful clock
    -- (there is no audio timeline, only sentences), so the line is dropped.
    self._mini_title = TextWidget:new{
        text = (self.chapter_title and self.chapter_title ~= "" and self.chapter_title)
            or self.output_name or self.title or _("Audiobook"),
        face = Font:getFace("cfont", 13),
        max_width = center_max_width,
        truncate_left = false,
    }
    local mini_center
    if self.tts_mode then
        self._mini_time = nil
        mini_center = VerticalGroup:new{
            align = "center",
            self._mini_title,
        }
    else
        self._mini_time = TextWidget:new{
            text = self.current_time_str or "",
            face = Font:getFace("cfont", 11),
            max_width = center_max_width,
        }
        mini_center = VerticalGroup:new{
            align = "center",
            self._mini_title,
            self._mini_time,
        }
    end

    local mini_row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = spacing },
        self._mini_play_pause,
        HorizontalSpan:new{ width = spacing },
        chapter_group[1] or HorizontalSpan:new{ width = 0 },
        chapter_group[2] or HorizontalSpan:new{ width = 0 },
        vol_group[1] or HorizontalSpan:new{ width = 0 },
        vol_group[2] or HorizontalSpan:new{ width = 0 },
        vol_group[3] or HorizontalSpan:new{ width = 0 },
        vol_group[4] or HorizontalSpan:new{ width = 0 },
        CenterContainer:new{
            dimen = Geom:new{ w = center_max_width, h = self._mini_height },
            mini_center,
        },
        nudge_group[1] or HorizontalSpan:new{ width = 0 },
        nudge_group[2] or HorizontalSpan:new{ width = 0 },
        nudge_group[3] or HorizontalSpan:new{ width = 0 },
        nudge_group[4] or HorizontalSpan:new{ width = 0 },
        HorizontalSpan:new{ width = spacing },
        refocus_group[1] or HorizontalSpan:new{ width = 0 },
        refocus_group[2] or HorizontalSpan:new{ width = 0 },
        self._mini_close,
        HorizontalSpan:new{ width = spacing },
    }
    self._mini_bar = FrameContainer:new{
        width = self.width,
        height = self._mini_height,
        background = self:_getThemeBackground(),
        bordersize = Size.border.thin,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self._mini_height - Size.border.thin * 2 },
            mini_row,
        },
    }

    -- Optional large bar: replaces the widgets built above.
    if self.large_mini_bar then
        self:_buildLargeMiniBar()
    end

    -- EPUB read-along mode: stay on the book page (highlights + page
    -- follow are the UI) with only the mini bar for transport control,
    -- instead of covering the text with the full-screen player.
    if self.start_minimized then
        self:_applyMinimizedGeometry()
        self:_updateMiniWidgets()
    end

    -- TTS: seed the center line with the first context item.  The cycler
    -- itself starts in show(), once the widget is visible.
    if self.tts_mode then
        local lines = self:_ttsInfoLines()
        if #lines > 0 then
            self._tts_info_idx = 1
            if self._mini_title then
                self:_fitMiniTitle(lines[1])
            end
        end
    end
end

--- Bottom inset so the mini player can sit above KOReader's status/progress bar.
--- MediaSync also reflows page margins by this chrome height + mini bar so
--- book text never renders underneath the player.
function AudiobookPlayer:_statusBarInset()
    if not self:_shouldSitAboveFooter() then return 0 end
    local ui = self.ui_widget or (self.plugin and self.plugin.ui)
    local view = ui and ui.view
    if not view or not view.footer_visible or not view.footer then return 0 end
    local ok, h = pcall(function() return view.footer:getHeight() end)
    if ok and type(h) == "number" and h > 0 then return h end
    ok, h = pcall(function()
        local d = view.footer.dimen
        return d and d.h or 0
    end)
    if ok and type(h) == "number" and h > 0 then return h end
    -- Last resort: typical status+progress stack on PW11-class screens.
    return Screen:scaleBySize(36)
end

--- The bar's own slot: the book's margins leave room for it here.
function AudiobookPlayer:_dockedBarY()
    -- Above the status bar when it shows; at the very bottom, with a small
    -- margin, when it does not.
    local inset = self:_statusBarInset()
    local gap = inset > 0 and 0 or Screen:scaleBySize(4)
    return self.height - self._mini_height - inset - gap
end

--- Where the bar sits.  On the book page always in its slot (the text is
--- laid out around it); while a menu or list from the book is under it,
--- wherever the user last dragged it (bar_menu_y_pct), else the slot.
function AudiobookPlayer:_miniBarY()
    if self._minimized and self:_menuOver()
            and (self._menu_y_pct or self:_menuOver(true)) then
        return self:_overMenuY()
    end
    return self:_dockedBarY()
end

--- Where the bar sits over a menu: where the user dragged it, else at the
--- very bottom (the menu hides the status bar, so it needs no room).
function AudiobookPlayer:_overMenuY()
    local pct = self._menu_y_pct
    if pct then
        local y = math.floor(pct * self.height + 0.5)
        return math.max(0, math.min(y, self.height - self._mini_height))
    end
    return self.height - self._mini_height - Screen:scaleBySize(4)
end

--- True when a menu, list or dialog lies between this bar and the book.
--- full_screen: only one that covers the whole screen (and so the status
--- bar), such as a settings page or the table of contents.
function AudiobookPlayer:_menuOver(full_screen)
    local stack = UIManager._window_stack
    if not (stack and self.ui_widget) then return false end
    local seen_self = false
    for j = #stack, 1, -1 do
        local w = stack[j].widget
        if seen_self then
            if w == self.ui_widget then return false end
            if not w.toast and not w._plugin_chrome
                    and (not full_screen or w.covers_fullscreen) then
                return true
            end
        elseif w == self then
            seen_self = true
        end
    end
    return false
end

--- Follow a menu opening or closing: move dimen and repaint both places.
--- The reader's status bar was shown or hidden: sit above it, or drop to
--- the bottom.
function AudiobookPlayer:onFooterChanged()
    if not self._minimized then return end
    self.covers_footer = not self:_shouldSitAboveFooter()
    self:_syncPosition()
end

function AudiobookPlayer:_syncPosition()
    if not (self.visible and self._minimized) then return end
    local y = self:_miniBarY()
    if self.dimen.y == y then return end
    local old = Geom:new{ x = 0, y = self.dimen.y, w = self.width, h = self._mini_height }
    self.dimen.y = y
    local new = Geom:new{ x = 0, y = y, w = self.width, h = self._mini_height }
    UIManager:setDirty("all", function() return "ui", old:combine(new) end)
end

--- End of a hold-and-drag: the bar keeps the offset at which it was grabbed.
function AudiobookPlayer:_finishMove(finger_y)
    local grab = self._moving and self._moving.grab or 0
    self._moving = nil
    self:_closeHint()
    local y = math.max(0, math.min(finger_y - grab, self.height - self._mini_height))
    self._menu_y_pct = y / self.height
    if self.plugin and self.plugin.setSetting then
        -- No flush: KOReader writes the settings on suspend and exit.
        self.plugin:setSetting("bar_menu_y_pct", self._menu_y_pct, true)
    end
    logger.warn("AudiobookPlayer: bar moved over menus to y=", y)
    self:_syncPosition()
end

function AudiobookPlayer:_applyMinimizedGeometry()
    self._minimized = true
    self.covers_fullscreen = false
    self.covers_footer = not self:_shouldSitAboveFooter()
    self.dimen.h = self._mini_height
    self.dimen.y = self:_miniBarY()
end

-- Callback handlers
function AudiobookPlayer:onPlayPause()
    -- Off the narrated page: Play opens into "play and go back" / "go back"
    -- choices (see Audiobook:_showReturnChoices).
    if self._return_hint_active and self.on_return_choice then
        self.on_return_choice()
        return
    end
    if self.on_play_pause then self.on_play_pause() end
end

function AudiobookPlayer:onSkipBack()
    if self.on_skip_back then self.on_skip_back() end
end

function AudiobookPlayer:onSkipForward()
    if self.on_skip_forward then self.on_skip_forward() end
end

function AudiobookPlayer:onPrevChapter()
    if self.on_prev_chapter then self.on_prev_chapter() end
end

function AudiobookPlayer:onNextChapter()
    if self.on_next_chapter then self.on_next_chapter() end
end

function AudiobookPlayer:onClose()
    if self.on_close then self.on_close() end
end

function AudiobookPlayer:onMinimize()
    self._scrubber_dragging = false
    self._scrubber_drag_pct = nil
    self:_updateMiniWidgets()
    -- Shrink dimen to only cover the mini bar area at the bottom
    -- so touch events pass through to the rest of the screen.
    self:_applyMinimizedGeometry()
    logger.warn("AudiobookPlayer: minimized, dimen=",
        self.dimen.x, self.dimen.y, self.dimen.w, self.dimen.h)
    -- Full refresh to erase the full-screen player image and redraw only the
    -- mini bar, avoiding a ghost of the full player controls on e-ink.
    UIManager:setDirty("all", "full")
    if self.on_minimize then self.on_minimize() end
end

function AudiobookPlayer:_restore()
    -- TTS read-along has no full-screen player: the mini bar is the whole UI.
    if self.tts_mode then return end
    self._minimized = false
    self._scrubber_dragging = false
    self._scrubber_drag_pct = nil
    -- Full-screen player covers the book (and status bars) while expanded.
    self.covers_fullscreen = true
    self.covers_footer = true
    -- Restore dimen to full screen so we receive all events again
    self.dimen.h = self.height
    self.dimen.y = 0
    -- Key devices: show the focus on Play.
    if self.layout and self.selected then
        pcall(self.moveFocusTo, self, self.selected.x, self.selected.y,
            FocusManager.FOCUS_ONLY_ON_NT)
    end
    UIManager:setDirty("all", "full")
end

--- Open the full-screen player (from a gesture or key action).
function AudiobookPlayer:openFull()
    if self._minimized then self:_restore() end
end

function AudiobookPlayer:onChapterList()
    if not self.on_chapter_list then return end
    local cb = self.on_chapter_list
    -- Boox crashes when a second top-level dialog is stacked on the fullscreen
    -- player (covers_fullscreen + OpenGL).  Collapse to the mini bar first,
    -- then open the chapter picker on the next tick.
    if not self._minimized then
        pcall(function() self:onMinimize() end)
    end
    UIManager:scheduleIn(0.25, function()
        local ok, err = pcall(cb)
        if not ok then
            logger.err("AudiobookPlayer: chapter list failed:", err)
            local DL = package.loaded["audiobook_debuglog"]
            if DL and DL.log then
                pcall(DL.log, DL, "player: onChapterList failed:", tostring(err))
            end
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Could not open chapter list.") .. "\n" .. tostring(err),
                timeout = 6,
            })
        end
    end)
end

function AudiobookPlayer:onShuffle()
    if self.on_shuffle then self.on_shuffle() end
end

function AudiobookPlayer:onLoop()
    if self.on_loop then self.on_loop() end
end

function AudiobookPlayer:onFixAudio()
    if self.on_fix_audio then self.on_fix_audio() end
end

function AudiobookPlayer:onSeek(pct)
    if self.on_seek then self.on_seek(pct) end
end

function AudiobookPlayer:onSpeed()
    local ButtonDialog = require("ui/widget/buttondialog")
    local min_speed = self.tts_mode and 0.25 or 0.5
    local max_speed = self.tts_mode and 2.0 or 3.0
    local presets = { 0.8, 1.0, 1.25, 1.5, 2.0 }
    local player = self
    local current = self.playback_speed or 1.0

    local function closeDialog()
        if player._speed_dialog then
            UIManager:close(player._speed_dialog)
            player._speed_dialog = nil
        end
    end

    local function refreshDialog()
        local dialog = player._speed_dialog
        if not dialog then return end
        local value = dialog:getButtonById("speed_value")
        if value then value:setText(player:_speedText(), value.width) end
        local slower_10 = dialog:getButtonById("speed_slower_10")
        if slower_10 then
            slower_10:enableDisable(current >= min_speed + 0.1 - 0.001)
        end
        local slower_05 = dialog:getButtonById("speed_slower_05")
        if slower_05 then
            slower_05:enableDisable(current >= min_speed + 0.05 - 0.001)
        end
        local faster_05 = dialog:getButtonById("speed_faster_05")
        if faster_05 then
            faster_05:enableDisable(current <= max_speed - 0.05 + 0.001)
        end
        local faster_10 = dialog:getButtonById("speed_faster_10")
        if faster_10 then
            faster_10:enableDisable(current <= max_speed - 0.1 + 0.001)
        end
        for _, preset in ipairs(presets) do
            local button = dialog:getButtonById("speed_preset_" .. tostring(preset))
            if button then
                local text = (math.abs(current - preset) < 0.01 and "✓ " or "")
                    .. string.format("%g×", preset)
                button:setText(text, button.width)
            end
        end
        UIManager:setDirty(dialog, "ui")
    end

    local function applySpeed(speed, keep_open)
        speed = math.max(min_speed, math.min(max_speed,
            tonumber(speed) or 1.0))
        speed = math.floor(speed * 100 + 0.5) / 100
        if not keep_open then closeDialog() end
        current = speed
        if player.on_speed then player.on_speed(speed) end
        if keep_open then refreshDialog() end
    end

    local function adjustSpeed(delta)
        applySpeed(current + delta, true)
    end

    local preset_buttons = {}
    for _, speed in ipairs(presets) do
        local preset_speed = speed
        table.insert(preset_buttons, {
            id = "speed_preset_" .. tostring(preset_speed),
            text = (math.abs(current - preset_speed) < 0.01 and "✓ " or "")
                .. string.format("%g×", preset_speed),
            callback = function() applySpeed(preset_speed, false) end,
        })
    end

    self._speed_dialog = ButtonDialog:new{
        title = _("Playback speed"),
        _plugin_chrome = true,
        buttons = {
            {
                {
                    id = "speed_slower_10",
                    text = "− 0.1",
                    enabled = current >= min_speed + 0.1 - 0.001,
                    callback = function()
                        adjustSpeed(-0.1)
                    end,
                },
                {
                    id = "speed_slower_05",
                    text = "− 0.05",
                    enabled = current >= min_speed + 0.05 - 0.001,
                    callback = function()
                        adjustSpeed(-0.05)
                    end,
                },
                { id = "speed_value", text = self:_speedText(), enabled = false },
                {
                    id = "speed_faster_05",
                    text = "+ 0.05",
                    enabled = current <= max_speed - 0.05 + 0.001,
                    callback = function()
                        adjustSpeed(0.05)
                    end,
                },
                {
                    id = "speed_faster_10",
                    text = "+ 0.1",
                    enabled = current <= max_speed - 0.1 + 0.001,
                    callback = function()
                        adjustSpeed(0.1)
                    end,
                },
            },
            preset_buttons,
            {
                {
                    text = _("Close"),
                    callback = closeDialog,
                },
            },
        },
    }
    UIManager:show(self._speed_dialog)
end

function AudiobookPlayer:onTtsSettings()
    if self.on_tts_settings then self.on_tts_settings() end
end

-- UI update helpers
function AudiobookPlayer:setPlaying(is_playing)
    -- Always push the icon/text even when the boolean is unchanged: on Boox
    -- the mini-bar dirty region sometimes misses the first toggle.
    local was_playing = self.is_playing
    self.is_playing = is_playing and true or false
    -- The choice buttons differ between playing and paused.
    if self._return_hint_active and was_playing ~= self.is_playing
            and self:_rebuildChoiceBar() then
        self:_refreshPlayButton(self.play_pause_button)
        self:_refreshPlayButton(self._mini_play_pause)
        return
    end
    self:_refreshPlayButton(self.play_pause_button)
    self:_refreshPlayButton(self._mini_play_pause)
    if self._minimized then
        self:_dirtyChrome(self._mini_play_pause and self._mini_play_pause.dimen)
    else
        self:_dirtyChrome(self.play_pause_button and self.play_pause_button.dimen)
    end
end

--- Refresh a rectangle. Never fall back to the whole mini bar for a clock
--- tick: that full-bar repaint every second is what made e-ink flash the
--- entire chrome (and ghost a second bar over KOReader's footer).
function AudiobookPlayer:_dirtyChrome(region)
    local mode = self:_isEink() and "fast" or "ui"
    if not (region and region.w and region.h and region.w > 0 and region.h > 0) then
        if self._minimized then
            region = self:_miniTimeDirtyRegion()
        else
            UIManager:setDirty(self, mode)
            return
        end
    end
    UIManager:setDirty(self, function()
        return mode, region
    end)
end

--- Tight screen rect around the elapsed/total label (the only 1 Hz change).
function AudiobookPlayer:_miniTimeDirtyRegion()
    local t = self._mini_time
    if t and t.dimen and t.dimen.w and t.dimen.w > 0 then
        local d = t.dimen
        local pad = 2
        -- Large bar: the clock's row across the whole centre box, so a
        -- longer time is never clipped to the previous text's width.
        local box = self.large_mini_bar and self._mini_center_box
            and self._mini_center_box.dimen
        if box and box.w and box.w > 0 and box.x then
            return Geom:new{
                x = math.max(0, box.x),
                y = math.max(0, d.y - pad),
                w = box.w,
                h = d.h + pad * 2,
            }
        end
        return Geom:new{
            x = math.max(0, d.x - pad),
            y = math.max(0, d.y - pad),
            w = d.w + pad * 2,
            h = d.h + pad * 2,
        }
    end
    local y = self:_miniBarY()
    local h = math.max(12, math.floor(self._mini_height * 0.42))
    local w = math.min(Screen:scaleBySize(180), self.width)
    return Geom:new{
        x = math.floor((self.width - w) / 2),
        y = y + self._mini_height - h - 2,
        w = w,
        h = h,
    }
end

--- Show a loading line (e.g. "Loading 12 / 73") where the clock sits, so
--- the book stays readable while the audiobook loads. nil clears it.
function AudiobookPlayer:setLoadingText(text)
    if text == self._loading_text then return end
    self._loading_text = text
    self.current_time_str = text or ""
    if self.time_widget then self.time_widget:setText(self.current_time_str) end
    if self._mini_time then self:_fitMiniTime(self.current_time_str) end
    -- The text changes width: repaint the whole bar, not the old clock rect.
    UIManager:setDirty(self, self:_isEink() and "fast" or "ui")
end

function AudiobookPlayer:updateTimeDisplay(current_sec, total_sec, force)
    -- Pollers must not overwrite the loading line with 0:00 / 0:00.
    if self._loading_text then return end
    local text
    if self._time_display_mode == "chapter" and self._current_chapter_end > self._current_chapter_start then
        local chapter_pos = math.max(0, current_sec - self._current_chapter_start)
        local chapter_dur = self._current_chapter_end - self._current_chapter_start
        text = self:_formatTime(chapter_pos) .. " / " .. self:_formatTime(chapter_dur)
    else
        text = self:_formatTime(current_sec) .. " / " .. self:_formatTime(total_sec)
    end
    if text == self.current_time_str and not force then return end
    self.current_time_str = text
    self.time_widget:setText(text)
    -- A sync note owns the bar's clock line until it times out.
    if self._sync_note_timer then return end
    if self._mini_time then
        self:_fitMiniTime(text)
    end
    if self._minimized then
        self:_dirtyChrome(self:_miniTimeDirtyRegion())
    else
        self:_dirtyChrome(self.time_widget and self.time_widget.dimen)
    end
end

function AudiobookPlayer:updateProgress(progress, force)
    -- Suppress poller updates while user is dragging the scrubber
    if self._scrubber_dragging then return end
    if progress == self.progress and not force then return end
    self.progress = progress
    self.progress_bar:setPercentage(progress / 100)
    -- The mini chrome has no scrubber: the ticking clock IS the progress
    -- display. Dirtying the whole bar here repainted all of it every 1%.
    if self._minimized then return end
    self:_dirtyChrome(self.progress_bar and self.progress_bar.dimen)
end

function AudiobookPlayer:updateChapterTitle(title)
    if title and title ~= self.chapter_title then
        self.chapter_title = title
        if self.chapter_widget then
            self.chapter_widget:setText(title)
        end
        -- Mini bar prefers chapter_title for read-aloud (see _updateMiniWidgets).
        if self._mini_title then
            self:_updateMiniWidgets()
        end
        if self._minimized then
            self:_dirtyChrome(self._mini_title and self._mini_title.dimen
                or self:_miniTimeDirtyRegion())
        else
            self:_dirtyChrome(self.chapter_widget and self.chapter_widget.dimen)
        end
    end
end

function AudiobookPlayer:_formatSleepTimerText(remaining_seconds, active)
    if not active or remaining_seconds <= 0 then
        return "⏲"
    end
    return "⏲✓"
end

function AudiobookPlayer:_formatSleepTimerRemaining(remaining_seconds)
    local m = math.floor(remaining_seconds / 60)
    local s = remaining_seconds % 60
    if m >= 60 then
        local h = math.floor(m / 60)
        m = m % 60
        return T(_("%1 h %2 min %3 s"), h, m, s)
    end
    return T(_("%1 min %2 s"), m, s)
end

function AudiobookPlayer:updateSleepTimer(remaining_seconds, active)
    self._sleep_timer_remaining = remaining_seconds or 0
    self._sleep_timer_active = active and remaining_seconds > 0
    local text = self:_formatSleepTimerText(self._sleep_timer_remaining, self._sleep_timer_active)
    if self.sleep_timer_button then
        self.sleep_timer_button:setText(text, self.sleep_timer_button.width)
    end
    UIManager:setDirty(self, function()
        if self._minimized then
            return "ui", self.dimen
        end
        if self.sleep_timer_button and self.sleep_timer_button.dimen then
            return "ui", self.sleep_timer_button.dimen
        end
        return "ui", self.dimen
    end)
end

function AudiobookPlayer:onSleepTimer()
    if self._sleep_timer_active then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = T(_("Sleep timer active.\nTime remaining: %1\n\nCancel the timer?"), self:_formatSleepTimerRemaining(self._sleep_timer_remaining)),
            ok_text = _("Cancel"),
            cancel_text = _("Keep"),
            ok_callback = function()
                if self.on_sleep_timer_cancel then
                    self.on_sleep_timer_cancel()
                end
                self:updateSleepTimer(0, false)
            end,
        })
    else
        -- Let the plugin show a single hours+minutes picker (DateTimeWidget
        -- when available, sequential SpinWidget fallback).
        if self.plugin and self.plugin._showSleepTimerDialog then
            self.plugin:_showSleepTimerDialog(nil, function(total_minutes)
                if total_minutes and total_minutes > 0 and self.on_sleep_timer_set then
                    self.on_sleep_timer_set(total_minutes)
                    self:updateSleepTimer(total_minutes * 60, true)
                end
            end)
        else
            -- Fallback for unusual plugin states: use a single SpinWidget in minutes.
            local SpinWidget = require("ui/widget/spinwidget")
            UIManager:show(SpinWidget:new{
                title_text = _("Sleep timer"),
                info_text = _("Select minutes."),
                value = 15,
                value_min = 1,
                value_max = 180,
                value_step = 5,
                value_hold_step = 15,
                ok_text = _("Set"),
                callback = function(spin)
                    local total = spin.value
                    if total > 0 and self.on_sleep_timer_set then
                        self.on_sleep_timer_set(total)
                        self:updateSleepTimer(total * 60, true)
                    end
                end,
            })
        end
    end
end

function AudiobookPlayer:onRefocus()
    logger.warn("ABP: onRefocus called, on_refocus=", self.on_refocus and "set" or "nil")
    if self.on_refocus then
        self.on_refocus()
    end
    return true
end

function AudiobookPlayer:setCurrentChapter(chapter)
    if chapter then
        self._current_chapter_start = chapter.start_time or 0
        self._current_chapter_end = chapter.end_time or 0
    else
        self._current_chapter_start = 0
        self._current_chapter_end = 0
    end
end

function AudiobookPlayer:setTitle(title)
    self.title = title or _("Audiobook")
    if self.title_widget then
        self.title_widget:setText(self.title)
        UIManager:setDirty(self, function()
            return "ui", self.title_widget.dimen
        end)
    end
end

function AudiobookPlayer:setShuffleActive(active)
    if self.shuffle_button then
        self.shuffle_button.bordersize = active and Size.border.default or 0
        self.shuffle_button:init()
        UIManager:setDirty(self, function()
            return "ui", self.shuffle_button.dimen
        end)
    end
end

function AudiobookPlayer:setLoopActive(active)
    if self.loop_button then
        self.loop_button.bordersize = active and Size.border.default or 0
        self.loop_button:init()
        UIManager:setDirty(self, function()
            return "ui", self.loop_button.dimen
        end)
    end
end

function AudiobookPlayer:_buildOutputWidget(name)
    -- The book title already shows in full at the top (two lines): do not
    -- repeat it under the chapter name.
    if name and self.title and name == self.title then
        return VerticalSpan:new{ width = 0 }
    end
    local max_w = self.width - Size.padding.small * 4
    local face = Font:getFace("cfont", 12)
    -- Simple word-wrap: split into up to 2 lines at word boundaries.
    local lines = {}
    if name and name ~= "" then
        local words = {}
        for w in name:gmatch("%S+") do
            table.insert(words, w)
        end
        local line1, line2 = "", ""
        for i, w in ipairs(words) do
            local test = line1 .. (line1 ~= "" and " " or "") .. w
            local tw = RenderText:sizeUtf8Text(0, max_w, face, test, true).x
            if tw <= max_w then
                line1 = test
            else
                -- remaining words go to line 2
                line2 = table.concat(words, " ", i)
                break
            end
        end
        if line1 ~= "" then table.insert(lines, line1) end
        if line2 ~= "" then
            local tw = RenderText:sizeUtf8Text(0, max_w, face, line2, true).x
            if tw > max_w then
                -- Truncate with ellipsis if still too long
                line2 = line2:sub(1, math.floor(#line2 * 0.8)) .. "…"
            end
            table.insert(lines, line2)
        end
    end
    if #lines == 0 then
        lines = { name or "" }
    end
    local widgets = {}
    for _, line in ipairs(lines) do
        table.insert(widgets, TextWidget:new{
            text = line,
            face = face,
            max_width = max_w,
        })
    end
    local vg = VerticalGroup:new{ align = "center" }
    for _, w in ipairs(widgets) do
        table.insert(vg, w)
    end
    return vg
end

function AudiobookPlayer:updateOutputName(name)
    if name and name ~= self.output_name then
        self.output_name = name
        self.output_widget = self:_buildOutputWidget(name)
        if self._minimized then
            self:_updateMiniWidgets()
            UIManager:setDirty(self, function()
                return "ui", self.dimen
            end)
        else
            UIManager:setDirty(self, function()
                return "ui", self.output_widget and self.output_widget.dimen or self.dimen
            end)
        end
    end
end

function AudiobookPlayer:_buildCoverFrame()
    local cover_height = self._cover_height or math.floor(math.min(self.width, self.height) * 0.32)
    local cover_width = self._cover_width or math.floor(cover_height * 0.75)

    -- Cache cover frames by path + dimensions so rotation does not re-decode and
    -- re-scale the image every time.
    local cache_key = string.format("%s|%dx%d", self.cover_image_path or "", cover_width, cover_height)
    if self._cover_frame_cache and self._cover_frame_cache[cache_key] then
        return self._cover_frame_cache[cache_key]
    end

    local frame
    if self.cover_image_path then
        local padding = Size.padding.small
        local max_w = cover_width - padding * 2
        local max_h = cover_height - padding * 2

        -- Let ImageWidget auto-scale the image to fit inside max_w x max_h
        -- without cropping.  scale_factor = 0 uses math.min so the entire
        -- image is visible, centered with blank space on the shorter side.
        local scale_factor = 0

        local function try_image(path)
            local widget = ImageWidget:new{
                file = path,
                width = max_w,
                height = max_h,
                scale_factor = scale_factor,
            }
            -- Force an early render so image-cache exhaustion is caught here
            -- instead of during the widget paint cycle (which would crash).
            widget:getSize()
            return widget
        end

        local ok, image_widget = pcall(try_image, self.cover_image_path)

        -- If the full-size cover exhausted KOReader's image cache, try a
        -- small thumbnail generated by ffmpeg (fits in ~200 kB vs ~4 MB).
        if not ok or not image_widget then
            local thumb_path = self.cover_image_path .. ".thumb.jpg"
            local ffmpeg_cmd = string.format(
                '"plugins/audiobook.koplugin/bin/ffmpeg" -y -i "%s" -vf "scale=300:-1" -q:v 2 -f image2 -vframes 1 "%s" 2>/dev/null',
                self.cover_image_path:gsub('"', '\\"'),
                thumb_path:gsub('"', '\\"')
            )
            os.execute(ffmpeg_cmd)
            local f = io.open(thumb_path, "r")
            if f then
                f:close()
                ok, image_widget = pcall(try_image, thumb_path)
            end
        end

        if ok and image_widget then
            frame = FrameContainer:new{
                width = cover_width,
                height = cover_height,
                background = self:_getThemeBackground(),
                bordersize = 0,
                padding = 0,
                CenterContainer:new{
                    dimen = Geom:new{ w = cover_width, h = cover_height },
                    image_widget,
                },
            }
        end
    end

    if not frame then
        -- Fallback: placeholder inside a framed box that blends with the theme
        local inner_widget = TextWidget:new{
            text = "♪",
            face = Font:getFace("cfont", 36),
        }
        frame = FrameContainer:new{
            width = cover_width,
            height = cover_height,
            background = self:_getThemeBackground(),
            bordersize = Size.border.thin,
            radius = Screen:scaleBySize(4),
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = cover_width, h = cover_height },
                inner_widget,
            },
        }
    end

    if not self._cover_frame_cache then self._cover_frame_cache = {} end
    self._cover_frame_cache[cache_key] = frame
    return frame
end

--- Optional large mini bar (large_mini_bar).  Sized for fingers on e-ink:
--- a tall strip, buttons that answer to their whole column
--- (_isTapOnMiniButton), a wide outlined play/pause as the anchor, and a
--- single rule on top instead of a boxed frame.  Carries the same buttons
--- as the classic bar and sets the same self._mini_* fields.
-- ── Arrangeable bar ──────────────────────────────────────────────────
-- Default order of the large bar, left to right. "title" is the title and
-- clock: items before it sit on its left, items after it on its right.
-- ✕ always stays last. Labels are for the arrange list.
AudiobookPlayer.BAR_ITEMS = {
    { id = "line_back",    label = function() return _("Previous line") end },
    { id = "play",         label = function() return _("Play / pause") end },
    { id = "line_forward", label = function() return _("Next line") end },
    { id = "chapters",     label = function() return _("Chapters") end },
    { id = "title",        label = function() return _("— Title and time —") end },
    { id = "sync_minus",   label = function() return _("Sync earlier") end },
    { id = "sync_plus",    label = function() return _("Sync later") end },
    { id = "vol_down",     label = function() return _("Volume down") end },
    { id = "vol_up",       label = function() return _("Volume up") end },
    { id = "speed",        label = function() return _("Speed (text-to-speech)") end },
    { id = "settings",     label = function() return _("Settings (text-to-speech)") end },
}

-- The ways back shown off the read-along page, default order.
AudiobookPlayer.CHOICE_ITEMS = {
    { id = "page", label = function() return "▶ " .. _("Here") end },
    { id = "mark", label = function() return "▶ " .. _("Resume") end },
    { id = "back", label = function() return "↩ " .. _("Back") end },
}

local function savedOrder(plugin, key, items)
    local saved = plugin and plugin.getSetting and plugin:getSetting(key, nil)
    local seq, seen, known = {}, {}, {}
    for _i, it in ipairs(items) do known[it.id] = true end
    if type(saved) == "table" then
        for _i, id in ipairs(saved) do
            if known[id] and not seen[id] then
                table.insert(seq, id)
                seen[id] = true
            end
        end
    end
    -- Items the saved list does not know yet (new buttons) keep their
    -- default side: before the title if they are before it by default.
    local title_pos
    for i, id in ipairs(seq) do if id == "title" then title_pos = i end end
    local before_title = true
    for _i, it in ipairs(items) do
        if it.id == "title" then before_title = false end
        if not seen[it.id] then
            if before_title and title_pos then
                table.insert(seq, title_pos, it.id)
                title_pos = title_pos + 1
            else
                table.insert(seq, it.id)
                if it.id == "title" then title_pos = #seq end
            end
            seen[it.id] = true
        end
    end
    return seq
end

--- The full saved bar order (ids), defaults filled in.
function AudiobookPlayer:_barOrder()
    return savedOrder(self.plugin, "bar_button_order", AudiobookPlayer.BAR_ITEMS)
end

--- "Back" with an arrow toward the line being read: right when it is
--- further on in the book, left when it is earlier; mirrored for books
--- whose pages turn the other way (inverse reading order).
function AudiobookPlayer:_backLabel()
    local ahead = true
    local p = self.plugin
    local ms = p and p.media_sync
    local doc = p and p.ui and p.ui.document
    pcall(function()
        local line_page = ms and ms:_entryPage(ms:_skipBase())
        local page = doc and doc:getCurrentPage()
        if line_page and page then ahead = line_page >= page end
    end)
    local view = p and p.ui and p.ui.view
    if view and view.inverse_reading_order then ahead = not ahead end
    return ahead and (_("Back") .. " →") or ("← " .. _("Back"))
end

--- After a page turn while the ways back show: flip Back's arrow if the
--- line being read is now on the other side.
function AudiobookPlayer:refreshBackArrow()
    if not self._mini_choice_buttons then return end
    local want = self:_backLabel()
    for _i, b in ipairs(self._mini_choice_buttons) do
        if b.text and b.text:find(_("Back"), 1, true) and b.text ~= want then
            self:_rebuildChoiceBar()
            return
        end
    end
end

--- The saved order of the ways back (ids).
function AudiobookPlayer:_choiceOrder()
    return savedOrder(self.plugin, "return_choice_order", AudiobookPlayer.CHOICE_ITEMS)
end

--- Split the widgets present (by id) into left-of-title and right-of-title
--- lists following the saved order.
function AudiobookPlayer:_orderBar(by_id)
    local left, right = {}, {}
    local side = left
    for _i, id in ipairs(self:_barOrder()) do
        if id == "title" then
            side = right
        elseif by_id[id] then
            table.insert(side, by_id[id])
        end
    end
    return left, right
end

--- Re-lay out the bar after its order changed.
function AudiobookPlayer:refreshLayout()
    if self.large_mini_bar then
        pcall(self._buildLargeMiniBar, self)
        self:_updateMiniWidgets()
        UIManager:setDirty(self, function() return "ui", self.dimen end)
    end
end

function AudiobookPlayer:_buildLargeMiniBar()
    self._mini_height = Screen:scaleBySize(76)
    local rule_h = Size.line.thick
    local inner_h = self._mini_height - rule_h
    local gap = Size.padding.large
    self._mini_hit_slop = math.floor(gap / 2)

    -- Read-along with line skip: the bar is for listening, so it carries
    --   [◂line] [ PLAY ] [line▸]  title / time  [vol−] [vol+] [◎] | [✕]
    -- Chapters live in the full player, and so do the sync nudges when the
    -- line view (which has its own sync row) is on.
    local line_skip = self.on_skip_line ~= nil and not self.tts_mode
    local show_chapters = self.on_chapter_list and not line_skip
    local show_sync = self.on_sync_nudge and not self.tts_mode
        and not (line_skip and self.lines_mode)

    -- Count the buttons this bar will carry so they can shrink together on
    -- narrow screens instead of squeezing the title to nothing.
    local n_buttons = 1 -- close
    -- (◎ is not on the large bar; see below.)
    if show_chapters then n_buttons = n_buttons + 1 end
    if self.tts_mode or show_sync then n_buttons = n_buttons + 2 end
    if not self.tts_mode and self.on_volume then n_buttons = n_buttons + 2 end
    if line_skip then n_buttons = n_buttons + 2 end
    local play_ratio = 1.5
    local n_gaps = n_buttons + 4 -- between items, around the title and separator
    local mini_btn_size = math.min(
        inner_h - Screen:scaleBySize(6),
        math.floor((self.width * 0.86 - gap * n_gaps) / (n_buttons + play_ratio)))
    local play_w = math.floor(mini_btn_size * play_ratio)

    -- Off the read-along page the ways back take the line buttons' place
    -- and the side buttons shrink to leave the title room.
    local choice_mode = line_skip and self._return_hint_active and self.on_return_choice_kind
        and true or false
    local side_size = mini_btn_size

    local function miniButton(icon, text, font_size, callback)
        if icon then
            return self:_iconButton(icon, text, side_size, callback,
                { icon_ratio = 0.62, font_size = font_size })
        end
        return Button:new{
            text = text,
            width = side_size,
            height = side_size,
            text_font_size = font_size,
            text_font_bold = true,
            callback = callback,
            bordersize = 0,
            show_parent = self,
        }
    end

    -- Button draws its border and padding outside this height; take them
    -- off so the outline keeps clear of the bar's edges.
    local play_h = mini_btn_size - (Size.border.thick + Size.padding.button) * 2
    self._mini_play_pause = self:_iconButton(self.is_playing and "pause" or "play",
        self.is_playing and "⏸" or "▶", play_h,
        function() self:onPlayPause() end,
        { width = play_w, icon_ratio = 0.8, bordersize = Size.border.thick,
          radius = Screen:scaleBySize(10), font_size = 26 })

    self._mini_close = miniButton("close", "✕", 20, function() self:onClose() end)

    if self.on_refocus then
        self._mini_refocus = miniButton("locate", "○", 22, function() self:onRefocus() end)
    end

    -- Chapter list on the mini bar (overlay): avoids expanding the fullscreen
    -- player just to tap ☰, which was crashing on Boox.
    if show_chapters then
        self._mini_chapters = miniButton("chapters", "☰", 22, function() self:onChapterList() end)
    else
        self._mini_chapters = nil
    end

    if line_skip then
        self._mini_line_back = miniButton("line.back", "◂≡", 20,
            function() self.on_skip_line(-1) end)
        self._mini_line_forward = miniButton("line.forward", "≡▸", 20,
            function() self.on_skip_line(1) end)
    else
        self._mini_line_back, self._mini_line_forward = nil, nil
    end

    -- Read-along: sync-offset nudges.  TTS: speed and the settings gear.
    local right_buttons = {}
    if self.tts_mode then
        self._mini_speed = miniButton(nil, self:_speedText(), 16, function() self:onSpeed() end)
        self._mini_settings = miniButton(nil, "⚙", 22, function() self:onTtsSettings() end)
        right_buttons = { self._mini_speed, self._mini_settings }
    elseif show_sync then
        self._mini_sync_minus = miniButton(nil, "−", 24, function() self:_nudgeSync(-100) end)
        self._mini_sync_plus = miniButton(nil, "+", 24, function() self:_nudgeSync(100) end)
        right_buttons = { self._mini_sync_minus, self._mini_sync_plus }
    else
        self._mini_sync_minus, self._mini_sync_plus = nil, nil
    end

    -- Volume nudge buttons.  These belong to audiobook and music playback;
    -- TTS reaches volume from its settings gear instead, so its mini bar
    -- stays uncluttered.  With line skip they sit on the right, away from
    -- the transport cluster.
    local left_buttons = {}
    -- Off the read-along page: the line buttons give way to the ways back
    -- (paused: play here / resume / go back; playing: pause / go back),
    -- and return once the view is back in sync (setReturnHint rebuilds).
    self._mini_choice_buttons = nil
    local choice_box
    if choice_mode then
        -- One outlined box, split into segments (like the play button grown
        -- sideways): paused, play here / resume / back; playing, pause / back.
        -- Equal segments, each as wide as the longest one-line label.
        local specs
        if self.is_playing then
            specs = { { "⏸ " .. _("Pause"), "pause" }, { self:_backLabel(), "back" } }
        else
            -- In the order chosen under Player bar > Arrange the choices.
            local by_kind = {}
            for _i, c in ipairs(AudiobookPlayer.CHOICE_ITEMS) do by_kind[c.id] = c end
            specs = {}
            for _i, id in ipairs(self:_choiceOrder()) do
                local c = by_kind[id]
                if c then
                    table.insert(specs, { id == "back" and self:_backLabel() or c.label(), id })
                end
            end
        end
        local seg_font = 15
        local seg_pad = Screen:scaleBySize(12)
        local seg_w = math.floor(play_w * 0.7)
        for _i, s in ipairs(specs) do
            local probe = TextWidget:new{
                text = s[1], face = Font:getFace("cfont", seg_font), bold = true,
            }
            seg_w = math.max(seg_w, probe:getSize().w + 2 * seg_pad)
            probe:free()
        end
        -- Keep the segments inside the rounded outline: painted at the
        -- edge, their white fill cut into the corners' curve.
        local box_radius = Screen:scaleBySize(10)
        local box_pad = math.ceil(box_radius * 0.35)
        self._mini_choice_buttons = {}
        for _i, s in ipairs(specs) do
            local kind = s[2]
            table.insert(self._mini_choice_buttons, Button:new{
                text = s[1],
                width = seg_w,
                height = play_h - 2 * box_pad,
                text_font_size = seg_font,
                text_font_bold = true,
                bordersize = 0,
                callback = function() self.on_return_choice_kind(kind) end,
                show_parent = self,
            })
        end
        local seg_items = { align = "center" }
        for i, b in ipairs(self._mini_choice_buttons) do
            if i > 1 then
                table.insert(seg_items, LineWidget:new{
                    dimen = Geom:new{ w = Size.line.medium, h = math.floor(play_h * 0.7) },
                    background = Blitbuffer.COLOR_GRAY,
                })
            end
            table.insert(seg_items, b)
        end
        choice_box = FrameContainer:new{
            bordersize = Size.border.thick,
            radius = box_radius,
            padding = box_pad,
            padding_top = box_pad,
            padding_bottom = box_pad,
            margin = 0,
            background = self:_getThemeBackground(),
            HorizontalGroup:new(seg_items),
        }
        left_buttons = { choice_box }
    elseif line_skip then
        left_buttons = { self._mini_line_back, self._mini_play_pause, self._mini_line_forward }
    else
        left_buttons = { self._mini_play_pause }
    end
    if self._mini_chapters then
        table.insert(left_buttons, self._mini_chapters)
    end
    -- While the ways back show, volume and ◎ step aside: Back does what ◎
    -- does, and the bar stays readable.
    if not self.tts_mode and self.on_volume and not choice_mode then
        self._mini_vol_minus = miniButton("volume.down", "♪−", 17, function() self:_applyVolume(-10) end)
        self._mini_vol_plus = miniButton("volume.up", "♪+", 17, function() self:_applyVolume(10) end)
        local vol_list = line_skip and right_buttons or left_buttons
        table.insert(vol_list, self._mini_vol_minus)
        table.insert(vol_list, self._mini_vol_plus)
    else
        self._mini_vol_minus, self._mini_vol_plus = nil, nil
    end
    -- ◎ (go to the read-along line) is not on the large bar: Back does it
    -- off the page, and the full-screen player carries it for the rest.
    self._mini_refocus = nil
    if choice_mode then
        -- Not on the bar now: drop them so a tap cannot hit where they were.
        self._mini_line_back, self._mini_line_forward = nil, nil
    end

    -- The saved order (Player bar > Arrange the bar's buttons): which side
    -- of the title each button sits on, and in what order. The ways back
    -- take the play button's place while they show.
    do
        local by_id = {
            line_back = self._mini_line_back,
            play = choice_box or self._mini_play_pause,
            line_forward = self._mini_line_forward,
            chapters = self._mini_chapters,
            sync_minus = show_sync and self._mini_sync_minus or nil,
            sync_plus = show_sync and self._mini_sync_plus or nil,
            vol_down = self._mini_vol_minus,
            vol_up = self._mini_vol_plus,
            speed = self.tts_mode and self._mini_speed or nil,
            settings = self.tts_mode and self._mini_settings or nil,
        }
        -- Only what this layout would have shown.
        local shown = {}
        for _i, b in ipairs(left_buttons) do shown[b] = true end
        for _i, b in ipairs(right_buttons) do shown[b] = true end
        for id, w in pairs(by_id) do
            if not shown[w] then by_id[id] = nil end
        end
        left_buttons, right_buttons = self:_orderBar(by_id)
    end

    -- Whatever width the buttons actually take leaves the rest to the
    -- centred title stack (measured, so shrunk buttons give room back).
    local used = gap -- leading gap
    local function width_of(w) return w and w:getSize().w or 0 end
    for _i, b in ipairs(left_buttons) do used = used + width_of(b) + gap end
    for _i, b in ipairs(right_buttons) do used = used + width_of(b) + gap end
    used = used + Size.line.medium + gap + width_of(self._mini_close) + gap
    used = used + gap -- around the centre stack
    local center_max_width = math.max(mini_btn_size, self.width - used)
    -- Later text (clock, loading lines, TTS info) is fitted to this width.
    self._mini_center_w = center_max_width
    self._mini_time_fit_key = nil
    self._mini_title_fit_text = nil

    -- Title and time always fit: the largest font that fits on one line,
    -- else the title wraps onto two lines (ellipsis only past that).
    local function fitted(text, sizes, bold, two_lines)
        for _i, size in ipairs(sizes) do
            local w = TextWidget:new{
                text = text, face = Font:getFace("cfont", size), bold = bold,
            }
            if w:getSize().w <= center_max_width then return w end
            w:free()
        end
        local small = sizes[#sizes]
        if two_lines then
            local face = Font:getFace("cfont", small)
            local box = TextBoxWidget:new{
                text = text, face = face, bold = bold, width = center_max_width,
                alignment = "center",
            }
            local lh = box.line_height_px
            if lh and box:getSize().h > lh * 2 then
                box:free()
                box = TextBoxWidget:new{
                    text = text, face = face, bold = bold, width = center_max_width,
                    alignment = "center", height = lh * 2,
                    height_overflow_show_ellipsis = true,
                }
            end
            return box
        end
        return TextWidget:new{
            text = text, face = Font:getFace("cfont", small), bold = bold,
            max_width = center_max_width,
        }
    end
    local title_text = self:_miniTitleText()
    self._mini_title_built_text = title_text
    self._mini_title = fitted(title_text, { 17, 15, 13 }, true, true)
    local mini_center
    if self.tts_mode then
        self._mini_time = nil
        mini_center = VerticalGroup:new{
            align = "center",
            self._mini_title,
        }
    else
        -- Sized for the clock's shape ("88:88 / 88:88", hours when the
        -- current text has them) so ticking never needs a bigger box.
        local shape = (self.current_time_str and self.current_time_str ~= ""
            and self.current_time_str:gsub("%d", "8")) or "88:88 / 88:88"
        if #shape < #"88:88 / 88:88" then shape = "88:88 / 88:88" end
        local probe = fitted(shape, { 15, 14, 13, 12 }, false, false)
        local time_face = probe.face
        probe:free()
        self._mini_time = TextWidget:new{
            text = self.current_time_str or "",
            face = time_face,
            max_width = center_max_width,
        }
        mini_center = VerticalGroup:new{
            align = "center",
            self._mini_title,
            VerticalSpan:new{ width = Size.span.vertical_default },
            self._mini_time,
        }
    end

    local row_items = { align = "center", HorizontalSpan:new{ width = gap } }
    local function add(w)
        table.insert(row_items, w)
        table.insert(row_items, HorizontalSpan:new{ width = gap })
    end
    for _i, b in ipairs(left_buttons) do add(b) end
    -- Kept so the clock's 1 Hz repaint covers the whole centre width: the
    -- time widget's own rect shrinks to its last text, which clipped
    -- "0:16 / 15:34" to "0:16 / 15:3".
    -- The stack places each line once, from its width at the time, so it
    -- is told to place them again when a line's text changes.
    self._mini_center_stack = mini_center
    self._mini_center_box = CenterContainer:new{
        dimen = Geom:new{ w = center_max_width, h = inner_h },
        mini_center,
    }
    add(self._mini_center_box)
    for _i, b in ipairs(right_buttons) do add(b) end
    -- A short divider keeps ✕ apart from the buttons used while listening.
    add(LineWidget:new{
        dimen = Geom:new{ w = Size.line.medium, h = math.floor(mini_btn_size * 0.6) },
        background = Blitbuffer.COLOR_GRAY,
    })
    add(self._mini_close)
    local mini_row = HorizontalGroup:new(row_items)

    self._mini_bar = FrameContainer:new{
        width = self.width,
        height = self._mini_height,
        background = self:_getThemeBackground(),
        bordersize = 0,
        padding = 0,
        VerticalGroup:new{
            LineWidget:new{
                dimen = Geom:new{ w = self.width, h = rule_h },
                background = Blitbuffer.COLOR_BLACK,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = inner_h },
                mini_row,
            },
        },
    }
end

--- Large mini bar: buttons answer to their whole column.  The caller has
--- already checked the tap is on the bar, so any x within the button (plus
--- half the gap beside it) counts, even when the finger lands above or below.
function AudiobookPlayer:_isTapOnMiniButton(pos, widget)
    if not self.large_mini_bar then
        return self:_isTapOnWidget(pos, widget)
    end
    if not widget or not widget.dimen then return false end
    local d = widget.dimen
    local slop = self._mini_hit_slop or 0
    return pos.x >= d.x - slop and pos.x <= d.x + d.w + slop
end

--- The sync UI module (words, scale, control), or nil.
function AudiobookPlayer:_syncUI()
    local p = self.plugin
    if not (p and p._syncUI) then return nil end
    local ok, SyncUI = p:_syncUI()
    return ok and SyncUI or nil
end

function AudiobookPlayer:_syncOffset()
    local SyncUI = self:_syncUI()
    if SyncUI then return SyncUI.get(self.plugin) end
    local p = self.plugin
    return (p and p.getSetting and p:getSetting("smil_sync_offset_ms", 0)) or 0
end

--- Fallback text when the sync UI didn't load.
function AudiobookPlayer:_syncText(offset_ms)
    offset_ms = offset_ms or self:_syncOffset()
    return string.format("Sync %+.1f s", offset_ms / 1000)
end

--- Put offset_ms (default: the current one) into the full player's label.
function AudiobookPlayer:_setSyncLabel(offset_ms)
    local w = self.sync_widget
    if not w then return end
    offset_ms = offset_ms or self:_syncOffset()
    if w.setOffset then
        w:setOffset(offset_ms)
    else
        w:setText(self:_syncText(offset_ms))
    end
end

--- Screen rect of the sync label: the label's own (it records where it was
--- painted), else its box's.
function AudiobookPlayer:_syncLabelRect()
    local d = self.sync_widget and self.sync_widget.dimen
    if d and d.x then return d end
    return self._sync_label_box and self._sync_label_box.dimen
end

--- The full player's label after a change made in the sync control.
function AudiobookPlayer:refreshSyncLabel()
    if not self.sync_widget then return end
    self:_setSyncLabel()
    local rect = self:_syncLabelRect()
    if rect and not self._minimized then
        UIManager:setDirty(self, function() return "fast", rect end)
    end
end

--- Open the sync control (words, scale, Earlier / Later, Reset).
function AudiobookPlayer:_openSyncControl()
    local SyncUI = self:_syncUI()
    if SyncUI then SyncUI.showControl(self.plugin) end
end

--- Shift the read-along highlight timing by delta_ms.  Minimized: the new
--- value shows in an overlay above the bar.  Full screen (line-by-line
--- view): the label between the sync buttons updates in place.
function AudiobookPlayer:_nudgeSync(delta_ms)
    if not self.on_sync_nudge then return end
    local v = self.on_sync_nudge(delta_ms)
    if not v then return end
    self:_setSyncLabel(v)
    if self._minimized and self._mini_time then
        -- A small note in the bar's clock line, only while adjusting.
        local ok, err = pcall(self._showSyncNote, self, v)
        if not ok then logger.err("AudiobookPlayer: sync note failed:", err) end
    elseif self._minimized then
        local ok, err = pcall(self._showSyncOverlay, self, v)
        if not ok then logger.err("AudiobookPlayer: sync overlay failed:", err) end
    elseif self:_syncLabelRect() then
        local rect = self:_syncLabelRect()
        UIManager:setDirty(self, function() return "fast", rect end)
    end
end

--- One wrapped, centered line of the line-by-line view.  Text taller than
--- its slot is cut with an ellipsis rather than spilling into its neighbours.
function AudiobookPlayer:_makeLineWidget(i, text)
    local spec = self._line_specs[i]
    -- The line being narrated is never cut off: step the font down until the
    -- whole sentence fits its slot. Only a sentence too long even at the
    -- smallest size falls through to the ellipsis below.
    if spec.shrink then
        local size = spec.size
        while size >= spec.min_size do
            local w = TextBoxWidget:new{
                text = text or "",
                face = Font:getFace("cfont", size),
                bold = spec.bold,
                fgcolor = spec.color,
                bgcolor = self:_getThemeBackground(),
                width = self._cover_width,
                alignment = "center",
            }
            if w:getSize().h <= spec.h then return w end
            w:free()
            size = size - 2
        end
    end
    local function build(height)
        return TextBoxWidget:new{
            text = text or "",
            face = Font:getFace("cfont", spec.min_size or spec.size),
            bold = spec.bold,
            fgcolor = spec.color,
            bgcolor = self:_getThemeBackground(),
            width = self._cover_width,
            alignment = "center",
            height = height,
            height_adjust = height and true or false,
            height_overflow_show_ellipsis = height and true or false,
        }
    end
    local w = build(nil)
    if w:getSize().h > spec.h then
        w:free()
        w = build(spec.h)
    end
    return w
end

--- Line-by-line view: the sentence being narrated, large and bold, with the
--- previous and next sentences in gray above and below it.
function AudiobookPlayer:_buildLinesFrame()
    local h = self._cover_height
    local gap = Size.padding.large
    local side_h = math.floor(h * 0.2)
    self._line_specs = {
        { size = 18, color = Blitbuffer.COLOR_DARK_GRAY, h = side_h },
        { size = 28, min_size = 14, shrink = true, bold = true,
          color = Blitbuffer.COLOR_BLACK, h = h - side_h * 2 - gap * 2 },
        { size = 18, color = Blitbuffer.COLOR_DARK_GRAY, h = side_h },
    }
    local lines = self._lines or {}
    self._line_slots = {}
    local group = VerticalGroup:new{ align = "center" }
    for i = 1, 3 do
        self._line_slots[i] = CenterContainer:new{
            dimen = Geom:new{ w = self._cover_width, h = self._line_specs[i].h },
            self:_makeLineWidget(i, lines[i]),
        }
        if i > 1 then
            table.insert(group, VerticalSpan:new{ width = gap })
        end
        table.insert(group, self._line_slots[i])
    end
    return FrameContainer:new{
        background = self:_getThemeBackground(),
        bordersize = 0,
        padding = 0,
        group,
    }
end

--- Show the narration's previous, current and next sentence (lines_mode).
function AudiobookPlayer:setLines(prev, cur, nxt)
    local lines = { prev or "", cur or "", nxt or "" }
    local old = self._lines
    if old and old[1] == lines[1] and old[2] == lines[2] and old[3] == lines[3] then return end
    self._lines = lines
    if not self._line_slots then return end
    for i = 1, 3 do
        if not old or old[i] ~= lines[i] then
            local slot = self._line_slots[i]
            local stale = slot[1]
            slot[1] = self:_makeLineWidget(i, lines[i])
            if stale and stale.free then stale:free() end
        end
    end
    if self.visible and not self._minimized and not self.suppressed then
        UIManager:setDirty(self, function()
            return "ui", self.cover_frame and self.cover_frame.dimen or nil
        end)
    end
end

function AudiobookPlayer:setCoverImage(path)
    self.cover_image_path = path
    self._cover_frame_cache = nil
    -- Rebuild the cover frame widget
    if self.cover_frame then
        self.cover_frame = self:_buildCoverFrame()
        -- Rebuild the main layout with the new cover frame
        self:setupUI()
        -- Restore other state
        if self.chapter_title and self.chapter_title ~= "" then
            self.chapter_widget:setText(self.chapter_title)
        end
        if self.output_name and self.output_name ~= "" then
            self.output_widget = self:_buildOutputWidget(self.output_name)
        end
        self.time_widget:setText(self.current_time_str or "0:00 / 0:00")
        self.progress_bar:setPercentage((self.progress or 0) / 100)
        self:_refreshPlayButton(self.play_pause_button)
        self.speed_button:setText(self:_speedText(), self.speed_button.width)
        UIManager:setDirty(self, "ui")
    end
end

function AudiobookPlayer:updateSpeed(speed)
    speed = tonumber(speed) or 1.0
    self.playback_speed = speed
    if self.speed_button then
        self.speed_button:setText(self:_speedText(), self.speed_button.width)
    end
    if self._mini_speed then
        self._mini_speed:setText(self:_speedText(), self._mini_speed.width)
    end
    UIManager:setDirty(self, function()
        if self._minimized then
            return "ui", self.dimen
        end
        if self.speed_button and self.speed_button.dimen then
            return "ui", self.speed_button.dimen
        end
        return "ui"
    end)
end

function AudiobookPlayer:_volumeText()
    return string.format("♪ %d%%", self.volume_pct or 100)
end

--- Nudge the volume by delta percent.  The on-screen value updates instantly;
--- non-Android backends debounce the apply (pipeline restart).  Android uses
--- MediaPlayer.setVolume live, so apply immediately for responsive ♪ buttons.
function AudiobookPlayer:_applyVolume(delta)
    local pct = (self.volume_pct or 100) + delta
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    if pct == self.volume_pct then return end
    self.volume_pct = pct

    if self.volume_widget then
        self.volume_widget:setText(self:_volumeText())
    end
    -- When minimized, flash the level in the mini time slot (the volume row
    -- itself is off-screen).  While expanded the volume widget shows it.
    if self._minimized and self._mini_time then
        self:_fitMiniTime(string.format("vol %d%%", pct))
    end
    UIManager:setDirty(self, function()
        if self._minimized then return "ui", self.dimen end
        return "ui", self.volume_widget and self.volume_widget.dimen or nil
    end)

    local Device = require("device")
    local live = Device.isAndroid and Device:isAndroid()
    if live then
        if self._vol_apply_timer then
            UIManager:unschedule(self._vol_apply_timer)
            self._vol_apply_timer = nil
        end
        if self.on_volume then self.on_volume(self.volume_pct) end
        return
    end

    if self._vol_apply_timer then
        UIManager:unschedule(self._vol_apply_timer)
    end
    self._vol_apply_timer = UIManager:scheduleIn(0.6, function()
        self._vol_apply_timer = nil
        if self.on_volume then self.on_volume(self.volume_pct) end
    end)
end

--- External sync of the displayed volume (e.g. when restored from settings).
function AudiobookPlayer:updateVolume(pct)
    pct = tonumber(pct)
    if not pct then return end
    self.volume_pct = pct
    if self.volume_widget then
        self.volume_widget:setText(self:_volumeText())
        UIManager:setDirty(self, function()
            return "ui", self.volume_widget.dimen
        end)
    end
end

function AudiobookPlayer:_speedText()
    local s = self.playback_speed or 1.0
    if s == 1.0 then return "1×" end
    if s == math.floor(s) then return string.format("%d×", s) end
    return string.format("%.2f×", s):gsub("0×", "×"):gsub("%.(%d)0×", ".%1×")
end

function AudiobookPlayer:_formatTime(seconds)
    seconds = math.floor(seconds or 0)
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    if mins >= 60 then
        local hours = math.floor(mins / 60)
        mins = mins % 60
        return string.format("%d:%02d:%02d", hours, mins, secs)
    end
    return string.format("%d:%02d", mins, secs)
end

-- Return the reader's configured background color so the overlay matches the
-- user's theme (white, sepia, dark, etc.) instead of forcing pure white.
-- KOReader widgets must manually invert for night mode; the framebuffer does
-- not do it automatically.
function AudiobookPlayer:_getThemeBackground()
    local bg_color

    -- Try ReaderUI's current page background first
    if self.plugin and self.plugin.ui and self.plugin.ui.view then
        local view = self.plugin.ui.view
        if view.page_bgcolor then
            bg_color = view.page_bgcolor
        end
    end

    if not bg_color then
        local ok, defaults = pcall(require, "defaults")
        if ok and defaults and defaults.readSetting then
            local bg_val = defaults:readSetting("DBACKGROUND_COLOR")
            if bg_val then
                bg_color = Blitbuffer.gray(bg_val * (1 / 15))
            end
        end
    end

    if not bg_color then
        bg_color = Blitbuffer.COLOR_WHITE
    end

    -- Night mode: invert the grayscale value so white becomes black.
    -- KOReader uses 8-bit e-ink colors where 0x00 = white and 0xFF = black.
    if Screen.night_mode then
        local gray_val = (type(bg_color) == "number") and bg_color or (bg_color.a or 0)
        bg_color = Blitbuffer.gray(0xFF - gray_val)
    end

    return bg_color
end

function AudiobookPlayer:_xToPercentage(x)
    if not self.progress_bar or not self.progress_bar.dimen then return nil end
    local bar_left = self.progress_bar.dimen.x
    local bar_width = self.progress_bar.dimen.w
    if not bar_left or not bar_width or bar_width <= 0 then return nil end
    local pct = (x - bar_left) / bar_width
    return math.max(0, math.min(1, pct))
end

function AudiobookPlayer:_updateScrubberPreview(x)
    local pct = self:_xToPercentage(x)
    if not pct then return end
    self._scrubber_drag_pct = pct
    self.progress_bar:setPercentage(pct)
    -- Use "fast" mode for drag updates: it refreshes the entire widget
    -- region more thoroughly than "ui", which reduces ghosting on e-ink
    -- screens during rapid scrubber movements.
    UIManager:setDirty(self, "fast")
end

--- The mini bar's centre line: the live chapter (else track/book) title,
--- or, while browsing away from the audio page, a cue to get back.
function AudiobookPlayer:_miniTitleText()
    if self._return_hint_active then
        return (self._mini_choice_buttons and _("Off the read-along page"))
            or (self.on_return_choice and _("Off the read-along page: tap ▶"))
            or _("Return to read-aloud")
    end
    local track = self.chapter_title
    if not track or track == "" then
        track = self.output_name
    end
    if not track or track == "" then
        track = self.title or _("Audiobook")
    end
    return track
end

--- Largest font size from `sizes` at which `text` fits `max_w`.
local function fitSize(text, sizes, max_w, bold)
    for _i, size in ipairs(sizes) do
        local probe = TextWidget:new{ text = text, face = Font:getFace("cfont", size), bold = bold }
        local w = probe:getSize().w
        probe:free()
        if w <= max_w then return size, true end
    end
    return sizes[#sizes], false
end

--- Shorter forms of the bar's second line, for when it does not fit even
--- at the smallest size: without the word "audiobook" ("Loading…"), then
--- just the numbers ("3 / 10").
local function trimLine(text, how)
    if how == "word" then
        return (text:gsub("%s*" .. _("audiobook"):gsub("%p", "%%%0"), "", 1))
    elseif how == "nums" then
        return text:match("%d+%s*/%s*%d+") or text
    end
    return text
end

--- Set the bar's second line (clock, loading progress, volume) so it always
--- fits: re-fitted whenever the text's length changes (the clock ticking at
--- the same length costs nothing extra).
function AudiobookPlayer:_fitMiniTime(text)
    local t = self._mini_time
    if not t then return end
    text = text or ""
    local max_w = self.large_mini_bar and self._mini_center_w
    -- Keyed by length, so the ticking clock is not measured every second.
    if max_w and self._mini_time_fit_key ~= #text then
        self._mini_time_fit_key = #text
        local sizes = { 15, 14, 13, 12, 11, 10 }
        local size, fits = fitSize(text, sizes, max_w)
        self._mini_time_trim = nil
        for _i, how in ipairs({ "word", "nums" }) do
            if fits then break end
            local short = trimLine(text, how)
            if short ~= text then
                size, fits = fitSize(short, sizes, max_w)
                self._mini_time_trim = how
            end
        end
        t.face = Font:getFace("cfont", size)
    end
    if max_w and self._mini_time_trim then text = trimLine(text, self._mini_time_trim) end
    t:setText(text)
    local stack = self._mini_center_stack
    if stack and stack.resetLayout then stack:resetLayout() end
end

--- Set the bar's title line so it always fits (one line: shrink; the
--- two-line box wraps by itself).
function AudiobookPlayer:_fitMiniTitle(text)
    local t = self._mini_title
    if not t then return end
    text = text or ""
    local max_w = self.large_mini_bar and self._mini_center_w
    if max_w and not t.line_height_px and self._mini_title_fit_text ~= text then
        self._mini_title_fit_text = text
        t.face = Font:getFace("cfont", (fitSize(text, { 17, 15, 13, 12, 11 }, max_w, true)))
    end
    t:setText(text)
    local stack = self._mini_center_stack
    if stack and stack.resetLayout then stack:resetLayout() end
end

function AudiobookPlayer:_updateMiniWidgets()
    local track = self:_miniTitleText()
    -- Large bar: its title is sized to fit when built, so new text means
    -- building it again (chapter changes are rare; the clock is not this).
    if self.large_mini_bar and not self.tts_mode and self._mini_title
            and self._mini_title_built_text ~= track and not self._rebuilding_mini then
        self._rebuilding_mini = true
        local ok, err = pcall(self._buildLargeMiniBar, self)
        self._rebuilding_mini = nil
        if not ok then logger.warn("AudiobookPlayer: bar rebuild failed:", err) end
        if self._minimized then
            UIManager:setDirty(self, function() return "ui", self.dimen end)
        end
    end
    -- TTS owns its center line through the context cycler (see
    -- _scheduleTtsInfo); do not clobber it with the chapter/track name.
    if self._mini_title and not self.tts_mode and self._mini_title_built_text ~= track then
        self:_fitMiniTitle(track)
    end
    if self._mini_time and not self._sync_note_timer then
        self:_fitMiniTime(self.current_time_str or "")
    end
    self:_refreshPlayButton(self._mini_play_pause)
    if self._mini_speed then
        self._mini_speed:setText(self:_speedText(), self._mini_speed.width)
    end
    if self._mini_refocus then
        -- Make the existing ○ control more obvious while the hint is active.
        local label = self._return_hint_active and "◎" or "○"
        self._mini_refocus:setText(label, self._mini_refocus.width)
    end
end

--- TTS context lines for the mini bar center, shown one at a time.
-- Read-along has no clock and no meaningful track title, so the center line
-- carries what is actually in effect: engine, voice, speed, volume.
function AudiobookPlayer:_ttsInfoLines()
    local p = self.plugin
    if not p or not p.getSetting then return {} end
    local lines = {}
    local engine = p.tts_engine
    local backend = engine and engine.backend or nil
    local engine_names = {
        espeak = "espeak-ng",
        piper = "Piper",
        sanotts = "sanoTTS",
        ["sanotts-jp"] = "sanoTTS-jp",
        pico = "Pico TTS",
        flite = "Flite",
        festival = "Festival",
        android = _("System TTS"),
        ["platform-native"] = _("Native voice"),
    }
    if backend then
        lines[#lines + 1] = engine_names[backend] or backend
    end

    local voice
    if backend == "piper" then
        voice = p:getSetting("piper_model_label", "")
    elseif backend == "android" then
        voice = p:getSetting("android_tts_voice_label", "")
    elseif backend == "sanotts" then
        -- The sanoTTS voice is chosen by name; tts_voice_label belongs to the
        -- espeak backend and would name an unrelated language here.  Prefer
        -- the live engine state, then the persisted setting, and map the name
        -- to its display label.
        local name = (engine and engine.sanotts_voice_name)
            or p:getSetting("sanotts_voice", nil) or "amy"
        voice = name
        if engine and engine.listSanottsVoices then
            local ok, voices = pcall(function() return engine:listSanottsVoices() end)
            if ok and voices then
                for _, v in ipairs(voices) do
                    if v.name == name then
                        -- The full label carries a size and a comment
                        -- ("kristin (English light, less accurate)") that the
                        -- narrow bar would clip; the name alone identifies it.
                        voice = (v.label or name):match("^([^%(]+)") or name
                        voice = voice:gsub("%s+$", "")
                        break
                    end
                end
            end
        end
    elseif backend == "sanotts-jp" then
        -- Single bring-your-own-weights voice: there is no espeak label to
        -- show, and printing one would be wrong.
        voice = nil
    elseif backend == "espeak" and p:getSetting("tts_mbrola_voice", "") ~= "" then
        -- MBROLA rides on the espeak backend, but tts_voice_label names the
        -- last plain espeak voice (stale and unrelated here); the MBROLA
        -- picker stores its own label.
        voice = p:getSetting("tts_mbrola_voice_label", "")
    else
        voice = p:getSetting("tts_voice_label", "")
    end
    if voice and voice ~= "" then
        lines[#lines + 1] = voice
    end

    lines[#lines + 1] = string.format("%s %sx", _("Speed"),
        tostring(p:getSetting("speech_rate", 1.0)))
    lines[#lines + 1] = string.format("%s %d%%", _("Volume"),
        math.floor((p:getSetting("speech_volume", 1.0) or 1.0) * 100))
    return lines
end

--- Advance the TTS center line to the next context item, on a timer.
-- The bar is narrow, so the items cycle instead of being clipped.
function AudiobookPlayer:_scheduleTtsInfo()
    if not (self.tts_mode and self._tts_info_active and self.visible) then return end
    UIManager:scheduleIn(3.5, function()
        if not (self.tts_mode and self._tts_info_active and self.visible) then return end
        local lines = self:_ttsInfoLines()
        if #lines == 0 then
            self:_scheduleTtsInfo()
            return
        end
        self._tts_info_idx = ((self._tts_info_idx or 0) % #lines) + 1
        if self._mini_title then
            self:_fitMiniTitle(lines[self._tts_info_idx])
        end
        UIManager:setDirty(self, function()
            return "ui", self._minimized and self.dimen or nil
        end)
        self:_scheduleTtsInfo()
    end)
end

--- Toggle Readest-style "return to read-aloud" cue on the mini bar.
-- When active, tapping the mini bar (outside transport buttons) refocuses
-- instead of expanding the full player.
--- Large bar with the ways back: rebuild it so the choice buttons appear
--- or the line buttons come back (the layout differs, not just labels).
function AudiobookPlayer:_rebuildChoiceBar()
    if not (self.large_mini_bar and self.on_return_choice_kind) then return false end
    self:_buildLargeMiniBar()
    self:_updateMiniWidgets()
    if self._minimized then
        UIManager:setDirty(self, function()
            return "ui", self.dimen
        end)
    end
    return true
end

function AudiobookPlayer:setReturnHint(active)
    active = not not active
    if self._return_hint_active == active then return end
    self._return_hint_active = active
    if self:_rebuildChoiceBar() then return end
    if self._minimized then
        self:_updateMiniWidgets()
        UIManager:setDirty(self, function()
            return "ui", self.dimen
        end)
    end
end

-- Show / hide
function AudiobookPlayer:show()
    self.visible = true
    -- If setupUI already minimized us (read-along mode), keep it minimized
    -- and avoid a disruptive full-screen flash.
    UIManager:show(self, self._minimized and "ui" or "full")
    self:_claimTop()
    if self.tts_mode then
        self._tts_info_active = true
        self:_scheduleTtsInfo()
    end
end

function AudiobookPlayer:hide()
    self:_releaseTop()
    self.visible = false
    self._minimized = false
    -- Stop the TTS context cycler so it does not keep a timer alive (and
    -- touch a widget that is being torn down).
    self._tts_info_active = false
    self:_closeSyncOverlay()
    self:_closeSyncNote()
    UIManager:close(self)
    UIManager:setDirty("all", "full")
end

function AudiobookPlayer:isVisible()
    return self.visible
end

-- Event handling
function AudiobookPlayer:handleEvent(event)
    -- Rotation support: KOReader dispatches SetRotationMode first, then
    -- SetDimensions.  On Kobo the framebuffer size never changes, so we
    -- track rotation mode and swap width/height ourselves.
    -- Rotation handling: UIManager:sendEvent only reaches the top widget.
    -- We must let ReaderUI handle rotation FIRST (it checks old Screen mode),
    -- then rotate Screen, then rebuild ourselves.  Order is critical:
    -- 1) ReaderUI sees old mode -> does full re-layout
    -- 2) Screen rotates atomically
    -- 3) Our widget rebuilds for the new orientation
    if event.handler == "onSetRotationMode" then
        local new_mode = event.args and event.args[1]
        logger.warn("ABP onSetRotationMode event, mode=", new_mode,
            "current=", self._rotation_mode)
        -- Hide our widget before the underlying UI rotates so the user never
        -- sees the old layout stretched into the new orientation.
        if self.visible then
            UIManager:close(self)
        end
        -- Let ReaderUI/FileManager do its rotation handling while Screen
        -- still reports the old mode (ReaderUI compares old vs new).
        if self.ui_widget then
            self.ui_widget:handleEvent(event)
        end
        -- Rotate the display atomically
        Screen:setRotationMode(new_mode)
        UIManager:onRotation()
        -- Rebuild and show for the new orientation now that Screen is updated.
        if self.visible then
            self:onSetDimensions(nil, new_mode)
        end
        return false
    end
    if event.handler == "onSetDimensions" then
        local size = event.args and event.args[1]
        return self:onSetDimensions(size)
    end

    -- Suppressed (TTS paused_only mode while playing): the bar renders
    -- nothing, so it must never dispatch taps to invisible buttons.  Mirror
    -- PlaybackBar's suppressed behavior: any tap is a tap-to-pause, every
    -- other gesture goes to the underlying UI.
    if self.suppressed then
        local arg1 = event.args and event.args[1]
        local ges = type(arg1) == "table" and arg1 or nil
        if ges and ges.ges == "tap" then
            self:onPlayPause()
            return true
        end
        if self._minimized and ges then
            return self:_dispatchGestureBelow(event)
        end
        return false
    end

    -- When minimized, handle taps on the mini bar; forward ALL other gestures
    -- to the underlying UI widget (ReaderUI/FileManager) so the user can
    -- interact with menus, swipe pages, pull down the top bar, etc.
    if self._minimized then
        local arg1 = event.args and event.args[1]
        local is_gesture = event.handler == "onGesture" or (type(arg1) == "table" and arg1.ges)
        if is_gesture then
            local ges = type(arg1) == "table" and arg1 or nil
            if ges and self.plugin and self.plugin.session_recorder then
                self.plugin.session_recorder:recordGesture(ges, "audiobookplayer")
            end
            -- Moving the bar: everything up to the lift is ours.
            if ges and self._moving then
                if ges.ges == "hold_release" and ges.pos then
                    self:_finishMove(ges.pos.y)
                    return true
                end
                if ges.ges == "hold_pan" then return true end
                self._moving = nil
                self:_closeHint()
            end
            -- A hold that started on the bar is ours up to the lift, even if
            -- the finger drifts off it: passed below, the hold selected the
            -- nearest word and the lift opened a dictionary lookup.
            if ges and self._hold_on_bar
                    and (ges.ges == "hold_pan" or ges.ges == "hold_release") then
                if ges.ges == "hold_release" then self._hold_on_bar = nil end
                return true
            end
            if ges and ges.pos then
                local mini_y = self:_miniBarY()
                local on_bar = ges.pos.y >= mini_y
                    and ges.pos.y < mini_y + self._mini_height
                if ges.ges == "hold" then
                    self._hold_on_bar = on_bar or nil
                end
                -- With double tap enabled in the reader, two quick taps arrive
                -- as one double_tap; count it as two presses of a sync
                -- button and as one press of anything else, never as a
                -- gesture for the book underneath.
                local is_double = ges.ges == "double_tap"
                -- Hold on a line button: by page instead of by line.
                if on_bar and ges.ges == "hold" and self.on_skip_page then
                    if self:_isTapOnMiniButton(ges.pos, self._mini_line_back) then
                        self.on_skip_page(-1)
                        return true
                    end
                    if self:_isTapOnMiniButton(ges.pos, self._mini_line_forward) then
                        self.on_skip_page(1)
                        return true
                    end
                end
                -- Hold anywhere else on the bar while a menu is open: drag
                -- it out of the way, lift to place.  Only then: on the
                -- book page the text is laid out around the bar's slot.
                if on_bar and ges.ges == "hold" and self:_menuOver() then
                    self._moving = { grab = ges.pos.y - mini_y }
                    self:_showHint(_("Drag the bar, lift to place it"))
                    return true
                end
                -- The ways back, shown in place of the line buttons.
                if on_bar and (ges.ges == "tap" or is_double) and self._mini_choice_buttons then
                    for _i, b in ipairs(self._mini_choice_buttons) do
                        if self:_isTapOnMiniButton(ges.pos, b) then
                            b.callback()
                            return true
                        end
                    end
                end
                if on_bar and is_double then
                    for _i, b in pairs{ self._mini_sync_minus, self._mini_sync_plus,
                            self._mini_line_back, self._mini_line_forward } do
                        if self:_isTapOnMiniButton(ges.pos, b) then
                            b.callback()
                            b.callback()
                            return true
                        end
                    end
                end
                if on_bar and (ges.ges == "tap" or is_double) then
                    -- Tap on play/pause button?
                    if self:_isTapOnMiniButton(ges.pos, self._mini_play_pause) then
                        self:onPlayPause()
                        return true
                    end
                    -- Line skip (read-along).
                    for _i, b in ipairs{ self._mini_line_back, self._mini_line_forward } do
                        if self:_isTapOnMiniButton(ges.pos, b) then
                            b.callback()
                            return true
                        end
                    end
                    -- Tap on chapter list (mini ☰)?
                    if self._mini_chapters
                        and self:_isTapOnMiniButton(ges.pos, self._mini_chapters) then
                        if self._mini_chapters.callback then
                            self._mini_chapters.callback()
                        end
                        return true
                    end
                    -- Tap on close button?
                    if self:_isTapOnMiniButton(ges.pos, self._mini_close) then
                        self:onClose()
                        return true
                    end
                    -- Tap on the read-along sync-nudge buttons?  These only
                    -- exist on the mini bar (read-along is always minimized),
                    -- so without handling them here the tap would fall through
                    -- to _restore() and the buttons would appear dead.  Invoke
                    -- the same callback the Button carries.
                    if self._mini_sync_minus
                        and self:_isTapOnMiniButton(ges.pos, self._mini_sync_minus) then
                        if self._mini_sync_minus.callback then
                            self._mini_sync_minus.callback()
                        end
                        return true
                    end
                    if self._mini_sync_plus
                        and self:_isTapOnMiniButton(ges.pos, self._mini_sync_plus) then
                        if self._mini_sync_plus.callback then
                            self._mini_sync_plus.callback()
                        end
                        return true
                    end
                    -- Volume buttons (audiobook / music mini bar).
                    if self._mini_vol_minus
                        and self:_isTapOnMiniButton(ges.pos, self._mini_vol_minus) then
                        if self._mini_vol_minus.callback then
                            self._mini_vol_minus.callback()
                        end
                        return true
                    end
                    if self._mini_vol_plus
                        and self:_isTapOnMiniButton(ges.pos, self._mini_vol_plus) then
                        if self._mini_vol_plus.callback then
                            self._mini_vol_plus.callback()
                        end
                        return true
                    end
                    -- TTS mini bar: speed and settings occupy the sync-nudge
                    -- slot (TTS has no sync offset).
                    if self._mini_speed
                        and self:_isTapOnMiniButton(ges.pos, self._mini_speed) then
                        self:onSpeed()
                        return true
                    end
                    if self._mini_settings
                        and self:_isTapOnMiniButton(ges.pos, self._mini_settings) then
                        self:onTtsSettings()
                        return true
                    end
                    -- Tap on the refocus button?
                    if self._mini_refocus
                        and self:_isTapOnMiniButton(ges.pos, self._mini_refocus) then
                        logger.warn("ABP: refocus button tapped")
                        if self._mini_refocus.callback then
                            logger.warn("ABP: invoking refocus callback")
                            self._mini_refocus.callback()
                        else
                            logger.warn("ABP: refocus button has no callback")
                        end
                        return true
                    end
                    -- While browsing away from the narration page, a tap on
                    -- the unused mini-bar area means "return to read-aloud"
                    -- (same as ○), not "expand full player". With the Play
                    -- button choices wired, Play is the way back instead.
                    if self._return_hint_active and self.on_refocus
                            and not self.on_return_choice then
                        logger.warn("ABP: return-hint bar tap -> refocus")
                        self:onRefocus()
                        return true
                    end
                    -- TTS has no full-screen player: a tap on empty bar space
                    -- does nothing.  Audiobook / music expand to the player.
                    if not self.tts_mode then
                        self:_restore()
                    end
                    return true
                end
                -- Any other hold on the bar stops here: below the bar it
                -- would select a word of the book.
                if on_bar and ges.ges == "hold" then return true end
                -- Gesture outside mini bar (or non-tap on bar) -> deliver
                -- below the bar, interleaved widgets first (see helper).
                return self:_dispatchGestureBelow(event)
            end
        end
        -- Non-gesture events pass through
        return false
    end

    local arg1 = event.args and event.args[1]
    if event.handler == "onGesture" or (type(arg1) == "table" and arg1.ges) then
        local ges = type(arg1) == "table" and arg1 or nil
        if ges and self.plugin and self.plugin.session_recorder then
            self.plugin.session_recorder:recordGesture(ges, "audiobookplayer")
        end
        if not ges then return false end

        -- DEBUG: log every gesture we receive
        logger.dbg("ABP gesture:", ges.ges,
            "pos=", ges.pos and (tostring(ges.pos.x) .. "," .. tostring(ges.pos.y)) or "nil",
            "minimized=", self._minimized,
            "dragging=", self._scrubber_dragging)

        -- Hold on a line button: by page instead of by line. Any other
        -- hold passes through.
        -- Swipe is treated as a release when we're in the middle of a drag.
        if ges.ges == "hold" then
            if self.on_skip_page and ges.pos then
                if self:_isTapOnWidget(ges.pos, self.line_back_button) then
                    self.on_skip_page(-1)
                    return true
                end
                if self:_isTapOnWidget(ges.pos, self.line_forward_button) then
                    self.on_skip_page(1)
                    return true
                end
            end
            -- The full player covers the page: a hold must not reach the
            -- book underneath (it selected a word there).
            return true
        end
        if ges.ges == "swipe" and self._scrubber_dragging then
            -- Gesture detector sometimes emits swipe instead of pan_release.
            -- Treat it as a release and perform the seek.
            logger.warn("ABP swipe while dragging -> seek")
            self._scrubber_dragging = false
            if self._scrubber_drag_pct and self.on_seek then
                self:onSeek(self._scrubber_drag_pct)
                self._scrubber_drag_pct = nil
            end
            return true
        end

        -- Pan / hold_pan on progress bar: visual drag preview
        -- NOTE: hold_pan is what KOReader emits for press-and-drag on e-ink.
        -- pan is what KOReader emits for quick drags (move > PAN_THRESHOLD while down).
        if (ges.ges == "pan" or ges.ges == "hold_pan") and ges.pos then
            if self.progress_bar and self.progress_bar.dimen then
                local bar_y = self.progress_bar.dimen.y
                local bar_h = self.progress_bar.dimen.h
                local in_zone = ges.pos.y >= bar_y - self._scrubber_touch_height / 2
                    and ges.pos.y <= bar_y + bar_h + self._scrubber_touch_height / 2
                logger.dbg("ABP pan/hold_pan bar_y=", bar_y, "bar_h=", bar_h,
                    "touch_h=", self._scrubber_touch_height,
                    "in_zone=", in_zone, "dragging=", self._scrubber_dragging)
                if in_zone then
                    self:_updateScrubberPreview(ges.pos.x)
                    self._scrubber_dragging = true
                    return true
                end
            else
                logger.dbg("ABP pan/hold_pan NO progress_bar.dimen")
            end
        end

        -- Pan release / hold release on progress bar: perform seek
        if (ges.ges == "pan_release" or ges.ges == "hold_release")
            and self._scrubber_dragging then
            self._scrubber_dragging = false
            if self._scrubber_drag_pct and self.on_seek then
                self:onSeek(self._scrubber_drag_pct)
                self._scrubber_drag_pct = nil
            end
            return true
        end

        -- Tap handling
        -- Two quick presses of a sync button arrive as one double_tap.
        if ges.ges == "double_tap" and ges.pos then
            for _i, b in pairs{ self.sync_minus_button, self.sync_plus_button,
                    self.line_back_button, self.line_forward_button } do
                if self:_isTapOnWidget(ges.pos, b) then
                    b.callback()
                    b.callback()
                    return true
                end
            end
        end

        if ges.ges == "tap" and ges.pos then
            -- If we were dragging and got a tap instead of pan_release, complete the seek
            -- only if the tap is on or near the progress bar.  Otherwise cancel the drag.
            if self._scrubber_dragging then
                local on_bar = false
                if self.progress_bar and self.progress_bar.dimen then
                    local bar_y = self.progress_bar.dimen.y
                    local bar_h = self.progress_bar.dimen.h
                    on_bar = ges.pos.y >= bar_y - self._scrubber_touch_height
                        and ges.pos.y <= bar_y + bar_h + self._scrubber_touch_height
                end
                if on_bar then
                    self._scrubber_dragging = false
                    local pct = self:_xToPercentage(ges.pos.x)
                    if pct and self.on_seek then
                        self:onSeek(pct)
                        self._scrubber_drag_pct = nil
                    end
                    return true
                else
                    -- Cancel the stale drag
                    self._scrubber_dragging = false
                    self._scrubber_drag_pct = nil
                end
            end

            -- Check if tap is inside any button
            local buttons = {
                self.play_pause_button, self.skip_back_button, self.skip_forward_button,
                self.prev_chapter_button, self.next_chapter_button,
                self.speed_button, self.close_button, self.minimize_button,
                self.chapter_list_button, self.sleep_timer_button,
                self.vol_minus_button, self.vol_plus_button,
                self.settings_button,
            }
            if self.sync_minus_button then
                table.insert(buttons, self.sync_minus_button)
                table.insert(buttons, self.sync_plus_button)
                if self.sync_widget then table.insert(buttons, self.sync_widget) end
            end
            -- The sync label (words + scale) opens the sync control.
            if self.sync_widget and self.sync_widget.setOffset
                    and self:_isTapOnWidget(ges.pos, self.sync_widget) then
                self:_openSyncControl()
                return true
            end
            if self.locate_button then
                table.insert(buttons, 1, self.locate_button)
            end
            if self.line_back_button then
                table.insert(buttons, self.line_back_button)
                table.insert(buttons, self.line_forward_button)
            end
            if self.show_shuffle and self.shuffle_button then
                table.insert(buttons, self.shuffle_button)
            end
            if self.show_loop and self.loop_button then
                table.insert(buttons, self.loop_button)
            end
            for _, btn in ipairs(buttons) do
                if self:_isTapOnWidget(ges.pos, btn) then
                    return InputContainer.handleEvent(self, event)
                end
            end

            -- Check time widget tap (toggle book/chapter time display)
            if self.time_widget and self.time_widget.dimen then
                if self:_isTapOnWidget(ges.pos, self.time_widget) then
                    self._time_display_mode = (self._time_display_mode == "book")
                        and "chapter" or "book"
                    -- Force a time refresh on next poller tick by clearing cached string
                    self.current_time_str = nil
                    return true
                end
            end

            -- Check progress bar area (tap to seek)
            if self.progress_bar and self.progress_bar.dimen then
                local bar_y = self.progress_bar.dimen.y
                local bar_h = self.progress_bar.dimen.h
                if ges.pos.y >= bar_y - self._scrubber_touch_height / 2
                    and ges.pos.y <= bar_y + bar_h + self._scrubber_touch_height / 2 then
                    local pct = self:_xToPercentage(ges.pos.x)
                    if pct then
                        self:onSeek(pct)
                        return true
                    end
                end
            end

            -- Tap outside any control: do nothing (only X closes)
            return true
        end
    end

    return InputContainer.handleEvent(self, event)
end

-- Deliver a gesture the bar did not consume: first to any widgets stacked
-- between this bar and the reader (a ButtonDialog shown at read-aloud
-- start, or a menu the bar was raised over), then to the reader.
-- KOReader's own dispatcher only hands unconsumed gestures to *active*
-- sub-widgets of lower widgets, so without this pass a plain dialog
-- between us and ReaderUI would never see a tap.  A full-screen or modal
-- widget ends the walk (bar the always-active ones, as KOReader does), so
-- a tap a contents list ignores never turns a page behind it.
function AudiobookPlayer:_dispatchGestureBelow(event)
    local stack = UIManager._window_stack
    local below = {}
    local seen_self = false
    for j = #stack, 1, -1 do
        local w = stack[j].widget
        if seen_self then
            if w == self.ui_widget then break end
            below[#below + 1] = w
        elseif w == self then
            seen_self = true
        end
    end
    local blocked = false
    for _, w in ipairs(below) do
        if not blocked or w.is_always_active then
            if w.handleEvent and w:handleEvent(event) then
                return true
            end
        elseif w.active_widgets then
            for _, aw in ipairs(w.active_widgets) do
                if aw:handleEvent(event) then return true end
            end
        end
        if w.covers_fullscreen or w.modal then blocked = true end
    end
    local ui = self.ui_widget
    if not ui then return false end
    if not blocked then
        return ui:handleEvent(event)
    end
    for _, aw in ipairs(ui.active_widgets or {}) do
        if aw:handleEvent(event) then return true end
    end
    return false
end

-- ── Stay above screens opened from the book ──────────────────────────────
-- Menus, lists and dialogs opened while the bar is up used to cover it.
-- UIManager.show is wrapped once (the hook survives plugin reloads, which
-- re-run this file, by looking the bar up on UIManager) and lifts the
-- minimized bar back to the top after every new screen.  Never above:
-- toasts and modals (UIManager's own order), the on-screen keyboard (it
-- sits where the bar is) and the sleep screen.
local STAY_BELOW = { VirtualKeyboard = true, ScreenSaver = true, ScreenSaverLock = true }

--- Screen height a menu may use so it ends above the floating bar, or nil
--- when the bar is not floating over menus (or sits in the upper half,
--- where the user dragged it out of the way).
local function menuRoomAboveBar(top_menu)
    local bar = rawget(UIManager, "_audiobook_top_bar")
    if not bar then UIManager._audiobook_fit_why = "no bar claimed"; return nil end
    if not (bar.visible and bar._minimized) or bar.suppressed then
        UIManager._audiobook_fit_why = string.format("bar visible=%s minimized=%s suppressed=%s",
            tostring(bar.visible), tostring(bar._minimized), tostring(bar.suppressed))
        return nil
    end
    local p = bar.plugin
    if p and p.getSetting and not (p:getSetting("floating_enabled", true)
            and p:getSetting("bar_over_menus", true)) then
        UIManager._audiobook_fit_why = "floating/over-menus off"
        return nil
    end
    -- Full-screen pages hide the status bar and the bar drops to the
    -- bottom over them; the top menu leaves it in its slot.
    local y
    if top_menu and not bar._menu_y_pct then
        y = bar:_dockedBarY()
    else
        y = bar:_overMenuY()
    end
    if not y or y < bar.height / 2 then
        UIManager._audiobook_fit_why = "bar in upper half y=" .. tostring(y)
        return nil
    end
    UIManager._audiobook_fit_why = nil
    return y
end

--- While the bar floats over menus, make KOReader's menus fit above it:
--- the top menu (TouchMenu) and full-height lists (Menu: table of
--- contents, bookmarks, chapter lists...) get a shorter height, so fewer
--- items go on each page and the rest move to the next page instead of
--- hiding under the bar. Lists are usually centred, so they lose the
--- bar's height at both ends.
local function installMenuFit()
    if UIManager._audiobook_menu_fit then return end
    UIManager._audiobook_menu_fit = true
    local ok_t, TouchMenu = pcall(require, "ui/widget/touchmenu")
    if ok_t and TouchMenu and TouchMenu.init then
        local orig = TouchMenu.init
        TouchMenu.init = function(tm, ...)
            local ok, y = pcall(menuRoomAboveBar, true)
            if ok and y and (not tm.height or tm.height > y) then
                tm.height = y
            end
            return orig(tm, ...)
        end
    end
    -- The height above only bounds TouchMenu's own estimate of a row.
    -- Themes with taller rows (ZenOS) still ran past the bar, so after
    -- laying a page out, measure it: if it ends below the bar, put fewer
    -- items on each page and lay it out again.
    if ok_t and TouchMenu and TouchMenu.updateItems then
        local orig_update = TouchMenu.updateItems
        TouchMenu.updateItems = function(tm, ...)
            if tm._ab_base_max then tm.max_per_page = tm._ab_base_max end
            local r = orig_update(tm, ...)
            local ok, y = pcall(menuRoomAboveBar, true)
            local d = tm.dimen
            if not (ok and y and d and d.h and tm.perpage and tm.perpage > 1) then
                return r
            end
            local bottom = (d.y or 0) + d.h
            if bottom <= y then return r end
            local item_group_h = tm.item_group and tm.item_group:getSize().h or d.h
            local row_h = item_group_h / (tm.perpage + 2) -- rows + tab bar + footer, roughly
            local cut = math.max(1, math.ceil((bottom - y) / math.max(1, row_h)))
            tm._ab_base_max = tm._ab_base_max or tm.max_per_page
            tm.max_per_page = math.max(1, tm.perpage - cut)
            r = orig_update(tm, ...)
            -- Still too tall (rows taller than guessed): one more step.
            d = tm.dimen
            if d and ((d.y or 0) + d.h) > y and tm.perpage > 1 then
                tm.max_per_page = tm.perpage - 1
                r = orig_update(tm, ...)
            end
            return r
        end
    end
    -- Sortable lists (ZenOS shows its settings menus as these) lay out
    -- their rows and page arrows from their height: build them ending at
    -- the bar, so the arrows sit just above it rather than under it.
    local ok_s, SortWidget = pcall(require, "ui/widget/sortwidget")
    if ok_s and SortWidget and SortWidget.init then
        local orig_sort_init = SortWidget.init
        SortWidget.init = function(sw, ...)
            local ok, y = pcall(menuRoomAboveBar)
            if ok and y and (not sw.height or sw.height > y) then
                sw.height = y
            end
            return orig_sort_init(sw, ...)
        end
    end
    local ok_m, Menu = pcall(require, "ui/widget/menu")
    if ok_m and Menu and Menu.init then
        local orig = Menu.init
        Menu.init = function(m, ...)
            local ok, y = pcall(menuRoomAboveBar)
            local screen_h = Screen:getHeight()
            if ok and y and (not m.height or m.height >= screen_h) then
                if rawget(m, "covers_fullscreen") then
                    -- A full-screen page shown at the top (ZenOS settings):
                    -- it can run all the way down to the bar.
                    m.height = y
                else
                    -- Usually centred in a screen-sized container (table of
                    -- contents...): it loses the bar's height at both ends.
                    m.height = math.max(math.floor(screen_h / 2), 2 * y - screen_h)
                end
            end
            return orig(m, ...)
        end
    end
end

--- Fewer rows per page for a full-screen list that runs under the bar.
--- Called after the list has laid itself out; returns true if it changed.
local function shrinkListUnderBar(w)
    local ok, y = pcall(menuRoomAboveBar)
    local d, item = w.dimen, w.item_dimen
    if not (ok and y and d and d.h and item and item.h and item.h > 0
            and w.available_height and w.perpage) then
        return false
    end
    local over = (d.y or 0) + d.h - y
    if over <= 0 then return false end
    local perpage = math.max(1, math.floor((w.available_height - over) / item.h))
    if perpage >= w.perpage then return false end
    w.perpage = perpage
    if w.getPageNumber and w.item_table then
        w.page_num = w:getPageNumber(#w.item_table)
        w.page = math.min(w.page or 1, w.page_num)
    end
    return true
end

--- Some full-screen lists (ZenOS's settings pages) work out their rows
--- in their own code, out of reach of the Menu hooks above. When one is
--- shown, wrap its layout step so every page it lays out (submenus too)
--- stops above the bar, then lay it out again.
local function fitShownList(w)
    if w._ab_fit_wrapped then return end
    if type(w._recalculateDimen) ~= "function" or not w.item_dimen or not w.updateItems then
        -- Diagnostic for lists this cannot fit (once per kind).
        if w.item_table and UIManager._audiobook_unfit_logged ~= w.name then
            UIManager._audiobook_unfit_logged = w.name
            logger.warn("AudiobookPlayer: list not fitted:", w.name,
                "recalc", type(w._recalculateDimen), "item_dimen", w.item_dimen ~= nil,
                "updateItems", w.updateItems ~= nil)
        end
        return
    end
    w._ab_fit_wrapped = true
    local own = w._recalculateDimen
    w._recalculateDimen = function(self, ...)
        local r = own(self, ...)
        pcall(shrinkListUnderBar, self)
        return r
    end
    local before = w.perpage
    local changed = shrinkListUnderBar(w)
    -- One line per kind of list, so a page that still runs under the
    -- bar can be traced from the log.
    if UIManager._audiobook_fit_logged ~= w.name then
        UIManager._audiobook_fit_logged = w.name
        local d = w.dimen
        logger.warn("AudiobookPlayer: list fit", w.name, "rows", before, "->", w.perpage,
            "dimen", d and d.y, d and d.h, UIManager._audiobook_fit_why or "")
    end
    if changed then
        w:updateItems()
    end
end

--- Sortable lists (KOReader's SortWidget; ZenOS shows its settings menus,
--- the Read-Along menu among them, as one) count their rows from their
--- own height, the whole screen. End the list at the bar and lay it out
--- again: fewer rows per page, the rest on the next page. Their own
--- re-layouts keep the shorter height.
-- @treturn bool true if it changed the list
local function fitSortList(w)
    if type(w._populateItems) ~= "function" or not (w.dimen and w.dimen.h and w.item_height) then
        return false
    end
    local ok, y = pcall(menuRoomAboveBar)
    if not (ok and y) then return false end
    local d = w.dimen
    if (d.y or 0) + d.h <= y then return false end
    local before = w.items_per_page
    d.h = y - (d.y or 0)
    w:_populateItems()
    logger.warn("AudiobookPlayer: list ended at the bar:", w.name or w.title or "?",
        "rows", before, "->", w.items_per_page)
    -- The strip it gave up shows the book again.
    UIManager:setDirty("all", "ui")
    return true
end

--- Wrap UIManager.show / close, and wrap them again whenever something
--- puts back an older copy (ZenOS swaps UIManager.show while it runs a
--- KOReader menu item, then restores the one it saw first, which dropped
--- this hook: the bar then stopped fitting menus).
local function installTopHook()
    installMenuFit()
    if UIManager.show == rawget(UIManager, "_audiobook_show_fn")
            and UIManager.close == rawget(UIManager, "_audiobook_close_fn") then
        return
    end
    if rawget(UIManager, "_audiobook_show_fn") then
        logger.warn("AudiobookPlayer: UIManager.show was replaced; hooking it again")
        -- Lists opened while the hook was gone: fit them now.
        local stack = UIManager._window_stack or {}
        for i = 1, #stack do
            local w = stack[i].widget
            if type(w) == "table" and w ~= rawget(UIManager, "_audiobook_top_bar") then
                pcall(fitShownList, w)
            end
        end
    end
    UIManager._audiobook_top_hook = true
    local orig_show = UIManager.show
    if UIManager.show ~= rawget(UIManager, "_audiobook_show_fn") then
    UIManager.show = function(um, widget, ...)
        local r = orig_show(um, widget, ...)
        local bar = rawget(UIManager, "_audiobook_top_bar")
        if bar and widget ~= bar and type(widget) == "table" and not widget.toast then
            local ok, err = pcall(bar._keepOnTop, bar)
            if not ok then logger.warn("AudiobookPlayer: keep on top failed:", err) end
            ok, err = pcall(fitShownList, widget)
            if not ok then logger.warn("AudiobookPlayer: list fit failed:", err) end
            ok, err = pcall(fitSortList, widget)
            if not ok then logger.warn("AudiobookPlayer: sort list fit failed:", err) end
        elseif type(widget) == "table" and widget.item_table
                and UIManager._audiobook_nobar_logged ~= widget.name then
            -- Diagnostic: a list opened while no bar is registered on top.
            UIManager._audiobook_nobar_logged = widget.name
            logger.warn("AudiobookPlayer: list shown with no bar on top:", widget.name)
        end
        return r
    end
    UIManager._audiobook_show_fn = UIManager.show
    end
    -- A screen closing may put the bar back in its slot (see _miniBarY).
    local orig_close = UIManager.close
    if UIManager.close ~= rawget(UIManager, "_audiobook_close_fn") then
    UIManager.close = function(um, widget, ...)
        local r = orig_close(um, widget, ...)
        local bar = rawget(UIManager, "_audiobook_top_bar")
        if bar and widget ~= bar and type(widget) == "table" and not widget.toast then
            local ok, err = pcall(bar._syncPosition, bar)
            if not ok then logger.warn("AudiobookPlayer: bar position failed:", err) end
        end
        return r
    end
    UIManager._audiobook_close_fn = UIManager.close
    end
end

function AudiobookPlayer:_claimTop()
    installTopHook()
    UIManager._audiobook_top_bar = self
end

function AudiobookPlayer:_releaseTop()
    if rawget(UIManager, "_audiobook_top_bar") == self then
        UIManager._audiobook_top_bar = nil
    end
end

--- Move this bar's window to the top of the stack, where UIManager would put
--- a new non-modal widget.  Only the minimized bar of a book still open.
function AudiobookPlayer:_keepOnTop()
    if not (self.visible and self._minimized) or self.suppressed then return end
    -- Settings: Floating player > Enable / Appear over in-book menus.
    local p = self.plugin
    if p and p.getSetting and not (p:getSetting("floating_enabled", true)
            and p:getSetting("bar_over_menus", true)) then
        return
    end
    local stack = UIManager._window_stack
    if not stack then return end
    local idx, has_ui
    for i = 1, #stack do
        local w = stack[i].widget
        if w == self then idx = i end
        if w == self.ui_widget then has_ui = true end
        if w and STAY_BELOW[w.name] then return end
    end
    if not (idx and has_ui) then return end
    local window = table.remove(stack, idx)
    local pos = 1
    for i = #stack, 0, -1 do
        local top = stack[i]
        if not (top and top.widget.toast) then
            if not top or not top.widget.modal then
                pos = i + 1
                break
            end
        end
    end
    table.insert(stack, pos, window)
    if pos ~= idx then
        UIManager:setDirty(self, "ui")
    end
    self:_syncPosition()
end

function AudiobookPlayer:_isTapOnWidget(pos, widget)
    if not widget or not widget.dimen then return false end
    local d = widget.dimen
    return pos.x >= d.x and pos.x <= d.x + d.w
        and pos.y >= d.y and pos.y <= d.y + d.h
end

function AudiobookPlayer:_doRebuild(new_w, new_h)
    -- Preserve state across the rebuild
    local was_minimized = self._minimized
    local was_playing = self.is_playing
    local title = self.title
    local chapter = self.chapter_title
    local output = self.output_name
    local progress = self.progress
    local time_str = self.current_time_str
    local speed = self.playback_speed
    local cover_path = self.cover_image_path
    -- Re-derive dimensions from the (potentially rotated) screen
    self.width = new_w
    self.height = new_h
    self._rotation_mode = Screen:getRotationMode()
    -- Rebuild the UI tree with new dimensions
    self:setupUI()
    -- Restore state into the fresh widgets
    self.is_playing = was_playing
    self.title = title
    self.chapter_title = chapter
    self.output_name = output
    self.progress = progress
    self.current_time_str = time_str
    self.playback_speed = speed
    self.cover_image_path = cover_path
    self:_refreshPlayButton(self.play_pause_button)
    self:_refreshPlayButton(self._mini_play_pause)
    if chapter and chapter ~= "" then self.chapter_widget:setText(chapter) end
    if output and output ~= "" then self.output_widget = self:_buildOutputWidget(output) end
    self.time_widget:setText(time_str or "0:00 / 0:00")
    self.progress_bar:setPercentage((progress or 0) / 100)
    self.speed_button:setText(self:_speedText(), self.speed_button.width)
    if self.sleep_timer_button then
        self.sleep_timer_button:setText(
            self:_formatSleepTimerText(self._sleep_timer_remaining, self._sleep_timer_active),
            self.sleep_timer_button.width)
    end
    self:_updateMiniWidgets()
    -- Position at the correct coordinates for the new dimensions
    self.visible = true
    if was_minimized then
        self:_applyMinimizedGeometry()
    else
        self._minimized = false
        self.covers_fullscreen = true
        self.covers_footer = true
        self.dimen.h = self.height
        self.dimen.y = 0
    end
end

-- Handle rotation mode change.  On Kobo the framebuffer size is fixed
-- (1264x1680) and the hardware rotates the display; we must rebuild
-- with the SAME dimensions so the framebuffer content is rotated
-- Handle screen dimension changes (e.g. after device rotation).
-- We close and re-show the widget so UIManager registers the new
-- x, y coordinates, matching how PlaybackBar handles rotation.
function AudiobookPlayer:onSetDimensions(size, rotation_mode)
    if not self.visible then return end
    -- Kobo framebuffer is fixed at 1264x1680.  Standalone widgets never see
    -- updated Screen dimensions after rotation, so we derive logical size
    -- from the rotation mode passed in (or from the event that triggered us).
    local rot = rotation_mode or Screen:getRotationMode()
    local new_w, new_h
    if size and size.w and size.h then
        new_w = size.w
        new_h = size.h
    elseif rot == 1 or rot == 3 then
        new_w = 1680
        new_h = 1264
    else
        new_w = 1264
        new_h = 1680
    end
    logger.warn("AudiobookPlayer: onSetDimensions, size=",
        size and (size.w .. "x" .. size.h) or "nil",
        "rot=", rot, "using=", new_w, "x", new_h,
        "screen=", Screen:getWidth(), "x", Screen:getHeight())
    -- Remove from UIManager so old coordinates are discarded
    UIManager:close(self)
    self:_doRebuild(new_w, new_h)
    -- Re-show at the correct position — this registers the new x,y with
    -- UIManager so paintTo receives the right coordinates.
    UIManager:show(self, "ui")
    self:_claimTop()
    UIManager:setDirty(self, "ui")
    return true
end

function AudiobookPlayer:onCloseWidget()
    self:_releaseTop()
    self._moving = nil
    self:_closeHint()
    -- Dismiss the speed picker if the player is closed while it is open.
    if self._speed_dialog then
        UIManager:close(self._speed_dialog)
        self._speed_dialog = nil
    end
    self:_closeSyncOverlay()
    self:_closeSyncNote()
end

--- Read-along sync nudges: show the new offset in a box just above the mini
--- bar for a couple of seconds.  The time line under the title only held it
--- until the next clock tick, too brief to read on e-ink.  The box is a toast,
--- so taps (including further nudges) pass straight through it.
local SYNC_OVERLAY_SECONDS = 2.5

function AudiobookPlayer:_showSyncOverlay(offset_ms)
    local SyncUI = self:_syncUI()
    local text = SyncUI and SyncUI.words(offset_ms)
        or string.format("Sync %+.1f s", offset_ms / 1000)
    if self._sync_overlay then
        self._sync_overlay_text:setText(text)
        if self._sync_overlay_scale then self._sync_overlay_scale:setOffset(offset_ms) end
        UIManager:setDirty(self._sync_overlay, function()
            return "fast", self._sync_overlay_rect
        end)
    else
        local face = Font:getFace("cfont", 22)
        local pad_x = Size.padding.large * 2
        -- Fixed width from the widest label so updates repaint in place,
        -- never wider than the screen.
        local max_w = self.width - 2 * (pad_x + Size.border.thick) - Screen:scaleBySize(16)
        local w = SyncUI and SyncUI.wordsWidth(face)
            or TextWidget:new{ text = "Sync +00.0 s", face = face }:getSize().w
        w = math.min(w, max_w)
        self._sync_overlay_text = TextWidget:new{ text = text, face = face, max_width = w }
        local inner = CenterContainer:new{
            dimen = Geom:new{ w = w, h = self._sync_overlay_text:getSize().h },
            self._sync_overlay_text,
        }
        if SyncUI then
            self._sync_overlay_scale = SyncUI.Scale:new{
                width = w,
                height = Screen:scaleBySize(12),
                offset_ms = offset_ms,
            }
            inner = VerticalGroup:new{
                align = "center",
                inner,
                VerticalSpan:new{ width = Size.padding.default },
                self._sync_overlay_scale,
            }
        end
        local frame = FrameContainer:new{
            toast = true,
            _plugin_chrome = true,
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.thick,
            radius = Screen:scaleBySize(10),
            padding = Size.padding.large,
            padding_left = pad_x,
            padding_right = pad_x,
            inner,
        }
        local size = frame:getSize()
        local x = math.floor((self.width - size.w) / 2)
        local y = self:_toastY(size.h)
        self._sync_overlay = frame
        self._sync_overlay_rect = Geom:new{ x = x, y = y, w = size.w, h = size.h }
        UIManager:show(frame, "fast", self._sync_overlay_rect, x, y)
    end
    if self._sync_overlay_timer then
        UIManager:unschedule(self._sync_overlay_timer)
    end
    self._sync_overlay_timer = function() self:_closeSyncOverlay() end
    UIManager:scheduleIn(SYNC_OVERLAY_SECONDS, self._sync_overlay_timer)
end

--- A toast just above the bar, or just below it when the bar is at the top.
function AudiobookPlayer:_toastY(h)
    local gap = Screen:scaleBySize(12)
    local bar_y = self:_miniBarY()
    if bar_y - h - gap >= 0 then return bar_y - h - gap end
    return math.min(bar_y + self._mini_height + gap, self.height - h)
end

--- A short instruction near the bar until _closeHint (or 4 s).
function AudiobookPlayer:_showHint(text)
    self:_closeHint()
    local frame = FrameContainer:new{
        toast = true,
        _plugin_chrome = true,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.thick,
        radius = Screen:scaleBySize(10),
        padding = Size.padding.large,
        padding_left = Size.padding.large * 2,
        padding_right = Size.padding.large * 2,
        TextWidget:new{ text = text, face = Font:getFace("cfont", 22) },
    }
    local size = frame:getSize()
    local x = math.floor((self.width - size.w) / 2)
    local y = self:_toastY(size.h)
    self._hint = frame
    self._hint_rect = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    UIManager:show(frame, "fast", self._hint_rect, x, y)
    self._hint_timer = function() self:_closeHint() end
    UIManager:scheduleIn(4, self._hint_timer)
end

function AudiobookPlayer:_closeHint()
    if self._hint_timer then
        UIManager:unschedule(self._hint_timer)
        self._hint_timer = nil
    end
    if self._hint then
        UIManager:close(self._hint, "ui", self._hint_rect)
        self._hint = nil
    end
end

--- Read-along sync nudge on the bar: the offset replaces the clock line
--- ("Sync +0.8 s") for a few seconds, then the clock comes back. Fitted
--- like the clock, so it always fits the bar.
function AudiobookPlayer:_showSyncNote(offset_ms)
    if not self._mini_time then return end
    self:_fitMiniTime(string.format("Sync %+.1f s", offset_ms / 1000))
    -- The note and the clock differ in width: repaint the whole bar.
    UIManager:setDirty(self, function() return "fast", self.dimen end)
    if self._sync_note_timer then
        UIManager:unschedule(self._sync_note_timer)
    end
    self._sync_note_timer = function() self:_closeSyncNote() end
    UIManager:scheduleIn(SYNC_OVERLAY_SECONDS, self._sync_note_timer)
end

function AudiobookPlayer:_closeSyncNote()
    if not self._sync_note_timer then return end
    UIManager:unschedule(self._sync_note_timer)
    self._sync_note_timer = nil
    if self._mini_time then
        self:_fitMiniTime(self.current_time_str or "")
        if self._minimized then
            UIManager:setDirty(self, function() return "fast", self.dimen end)
        end
    end
end

function AudiobookPlayer:_closeSyncOverlay()
    if self._sync_overlay_timer then
        UIManager:unschedule(self._sync_overlay_timer)
        self._sync_overlay_timer = nil
    end
    if self._sync_overlay then
        UIManager:close(self._sync_overlay, "ui", self._sync_overlay_rect)
        self._sync_overlay = nil
        self._sync_overlay_text = nil
        self._sync_overlay_scale = nil
    end
end

-- Compatibility with SyncController's PlaybackBar API.
function AudiobookPlayer:updatePlayState(is_playing)
    self:setPlaying(is_playing)
end

function AudiobookPlayer:updateCurrentWord(word)
    -- TTS shows a cycling context line (engine, voice, speed, volume) in the
    -- mini bar rather than the word being spoken: the highlight already shows
    -- the word on the page, and overwriting the bar with each word was noise.
    if self.tts_mode then return end
    if word and word ~= "" then
        self:updateChapterTitle(word)
    end
end

function AudiobookPlayer:setSuppressed(suppressed)
    suppressed = suppressed and true or false
    if self.suppressed == suppressed then return end
    self.suppressed = suppressed
    UIManager:setDirty("all", "ui")
end

function AudiobookPlayer:isSuppressed()
    return self.suppressed and true or false
end

--- Extra window-stack widgets (menus/dialogs) besides this chrome.
function AudiobookPlayer:_isOverlayActive()
    local stack = UIManager._window_stack
    if not stack then return false end
    local non_toast = 0
    for i = 1, #stack do
        local w = stack[i].widget
        if w ~= self and not w.toast and not w._plugin_chrome then
            non_toast = non_toast + 1
            if non_toast > 1 then
                return true
            end
        end
    end
    return false
end

function AudiobookPlayer:paintTo(bb, x, y)
    if not self.visible or self.suppressed then return end
    -- Cheap check (two compares): if our UIManager hook was dropped, put
    -- it back after this paint.
    if rawget(UIManager, "_audiobook_top_bar") == self and not self._rehook_pending
            and (UIManager.show ~= rawget(UIManager, "_audiobook_show_fn")
                or UIManager.close ~= rawget(UIManager, "_audiobook_close_fn")) then
        self._rehook_pending = true
        UIManager:nextTick(function()
            self._rehook_pending = nil
            local ok, err = pcall(installTopHook)
            if not ok then logger.warn("AudiobookPlayer: re-hook failed:", err) end
        end)
    end
    -- Lists can reach the screen without passing UIManager.show while we
    -- watch it (ZenOS reuses its settings page, and a bar put back by
    -- another path never registered itself on top). When what is on screen
    -- changes, register the bar and fit any list under it. Cheap: compares
    -- the stack's size and top before doing anything.
    if self._minimized and not self._list_scan_pending then
        local stack = UIManager._window_stack
        local n = stack and #stack or 0
        local sig = n .. ":" .. tostring(stack and stack[n] and stack[n].widget)
        if sig ~= self._list_scan_sig then
            self._list_scan_sig = sig
            self._list_scan_pending = true
            UIManager:nextTick(function()
                self._list_scan_pending = nil
                if not (self.visible and self._minimized) or self.suppressed then return end
                if rawget(UIManager, "_audiobook_top_bar") ~= self then
                    logger.warn("AudiobookPlayer: bar was not registered on top; registering")
                    pcall(self._claimTop, self)
                end
                -- Over a full-screen page, drop to the bottom (and back after).
                pcall(self._syncPosition, self)
                local st = UIManager._window_stack or {}
                -- Diagnostic (first 8 changes): what is on screen.
                self._list_scan_logs = (self._list_scan_logs or 0) + 1
                if self._list_scan_logs <= 8 then
                    local parts = {}
                    for i = 1, #st do
                        local w = st[i].widget
                        parts[#parts + 1] = tostring(type(w) == "table" and (w.name or "?") or w)
                            .. (type(w) == "table" and w.item_table and "[list]" or "")
                            .. (type(w) == "table" and type(w._populateItems) == "function" and "[sort]" or "")
                            .. (w == self and "[bar]" or "")
                    end
                    local ok_y, y = pcall(menuRoomAboveBar)
                    logger.warn("AudiobookPlayer: on screen:", table.concat(parts, ", "),
                        "registered:", rawget(UIManager, "_audiobook_top_bar") == self,
                        "room y:", ok_y and y or "?", UIManager._audiobook_fit_why or "")
                end
                for i = 1, #st do
                    local w = st[i].widget
                    if type(w) == "table" and w ~= self and w.item_table then
                        local ok, err = pcall(fitShownList, w)
                        if not ok then logger.warn("AudiobookPlayer: list fit failed:", err) end
                    end
                    if type(w) == "table" and w ~= self then
                        local ok, err = pcall(fitSortList, w)
                        if not ok then logger.warn("AudiobookPlayer: sort list fit failed:", err) end
                    end
                end
            end)
        end
    end
    if self._minimized then
        -- Draw only the mini player bar at bottom (optionally above status bar).
        -- UIManager's window.y for this widget is always 0 (set when first shown),
        -- so we must add the bottom offset ourselves.
        if self._mini_bar and self._mini_bar.paintTo then
            self._mini_bar:paintTo(bb, x or 0, (y or 0) + self:_miniBarY())
        end
        return
    end
    if self[1] and self[1].paintTo then
        self[1]:paintTo(bb, x or 0, y or 0)
    end
end

return AudiobookPlayer
