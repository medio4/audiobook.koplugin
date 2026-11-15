--[[--
Floating player: a small bubble, bottom centre, shown while a read-along
keeps playing after its book was closed (setting "Floating player outside
the book"). It floats above whatever KOReader screen is open and does not
move anything else.

Collapsed it is a round play/pause button. A tap on it expands a panel:
line back, play/pause, line forward, open the book at the narration, stop,
hide. Taps anywhere else go to the screens underneath, so the library and
menus work as usual.

The widget only draws and dispatches. What the buttons do is passed in by
main.lua (callbacks), which owns the detached session.

@module floatingplayer
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local logger = require("logger")

local Screen = Device.screen

local FloatingPlayer = InputContainer:extend{
    name = "audiobook_floating_player",
    -- Not a full-screen widget: never let KOReader treat it as one.
    covers_fullscreen = false,
    plugin_path = nil,   -- "plugins/audiobook.koplugin" (for the icons)
    title = nil,         -- book / chapter line shown in the panel
    is_playing = false,
    expanded = false,
    -- Callbacks (all optional): on_play_pause, on_skip_line(n),
    -- on_open_book, on_stop, on_hide.
}

-- Icons: same lookup trick as AudiobookPlayer:_iconName (Button only takes
-- a name, resolved under resources/icons/mdlight).
function FloatingPlayer:_iconName(name)
    local dir = self.plugin_path
    if not dir or dir == "" then return nil end
    if dir:sub(1, 1) == "/" then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        local cwd = ok_lfs and lfs.currentdir and lfs.currentdir()
        if not (cwd and dir:sub(1, #cwd + 1) == cwd .. "/") then return nil end
        dir = dir:sub(#cwd + 2)
    end
    local f = io.open(dir .. "/icons/ab." .. name .. ".svg", "r")
    if not f then return nil end
    f:close()
    return "../../../" .. dir .. "/icons/ab." .. name
end

function FloatingPlayer:_button(icon, fallback, size, callback, opts)
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
        args.icon, args.icon_width, args.icon_height = name, isz, isz
    else
        args.text, args.text_font_size = fallback, 22
    end
    return Button:new(args)
end

function FloatingPlayer:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    -- Sits above KOReader's status bar / the bottom edge.
    self.bottom_gap = Screen:scaleBySize(64)
    self:_build()
end

function FloatingPlayer:_build()
    local size = Screen:scaleBySize(64)
    local play_icon = self.is_playing and "pause" or "play"
    local play_text = self.is_playing and "⏸" or "▶"
    self._buttons = {}
    local content
    if not self.expanded then
        -- Round, thick outline: easy to spot and to hit.
        local b = self:_button(play_icon, play_text, size,
            function() self:_expand(true) end,
            { bordersize = Size.border.thick, radius = math.floor(size / 2),
              icon_ratio = 0.55 })
        table.insert(self._buttons, b)
        content = b
    else
        local bsize = Screen:scaleBySize(60)
        local gap = Size.padding.large
        local row = { align = "center" }
        local function add(icon, text, cb, extra)
            local b = self:_button(icon, text, bsize, cb, extra)
            if #row > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
            table.insert(row, b)
            table.insert(self._buttons, b)
        end
        add("line.back", "◂", function() if self.on_skip_line then self.on_skip_line(-1) end end)
        add(play_icon, play_text, function() if self.on_play_pause then self.on_play_pause() end end,
            { bordersize = Size.border.thick, radius = Screen:scaleBySize(10),
              width = math.floor(bsize * 1.4), icon_ratio = 0.7 })
        add("line.forward", "▸", function() if self.on_skip_line then self.on_skip_line(1) end end)
        add("book", "📖", function() if self.on_open_book then self.on_open_book() end end)
        add("stop", "■", function() if self.on_stop then self.on_stop() end end)
        add("minimize", "▾", function() self:_expand(false) end)
        add("close", "✕", function() if self.on_hide then self.on_hide() end end,
            { icon_ratio = 0.45 })
        local row_w = HorizontalGroup:new(row)
        local items = { align = "center" }
        if self.title and self.title ~= "" then
            table.insert(items, TextWidget:new{
                text = self.title,
                face = Font:getFace("cfont", 15),
                bold = true,
                max_width = row_w:getSize().w,
            })
            table.insert(items, VerticalSpan:new{ width = Size.padding.small })
        end
        table.insert(items, row_w)
        content = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.thick,
            radius = Screen:scaleBySize(14),
            padding = Size.padding.default,
            VerticalGroup:new(items),
        }
    end
    self[1] = content
    local sz = content:getSize()
    -- Absolute rectangle of the visible bubble (hit tests, refresh).
    self.dimen = Geom:new{
        x = math.floor((self.screen_w - sz.w) / 2),
        y = self.screen_h - self.bottom_gap - sz.h,
        w = sz.w, h = sz.h,
    }
end

function FloatingPlayer:paintTo(bb, x, y)
    -- Shown at (0, 0): draw only the bubble; the rest stays the screen below.
    self[1]:paintTo(bb, self.dimen.x, self.dimen.y)
end

--- Repaint after a change; old_dimen is repainted too (the panel shrinks).
function FloatingPlayer:_refresh(old_dimen)
    local region = self.dimen
    if old_dimen then region = old_dimen:combine(self.dimen) end
    UIManager:setDirty("all", function() return "ui", region end)
end

function FloatingPlayer:_expand(on)
    local old = self.dimen and self.dimen:copy()
    self.expanded = on and true or false
    self:_build()
    self:_refresh(old)
end

function FloatingPlayer:setPlaying(playing)
    playing = playing and true or false
    if playing == self.is_playing then return end
    self.is_playing = playing
    local old = self.dimen and self.dimen:copy()
    self:_build()
    self:_refresh(old)
end

function FloatingPlayer:setTitle(title)
    if title == self.title then return end
    self.title = title
    if self.expanded then
        local old = self.dimen and self.dimen:copy()
        self:_build()
        self:_refresh(old)
    end
end

local function inside(pos, d)
    return d and pos and pos.x >= d.x and pos.x < d.x + d.w
        and pos.y >= d.y and pos.y < d.y + d.h
end

--- Hand an event to the widgets under this one, top first.
function FloatingPlayer:_dispatchBelow(event)
    local stack = UIManager._window_stack or {}
    local seen_self = false
    for j = #stack, 1, -1 do
        local w = stack[j].widget
        if seen_self then
            if w and w.handleEvent and w:handleEvent(event) then return true end
        elseif w == self then
            seen_self = true
        end
    end
    return false
end

function FloatingPlayer:handleEvent(event)
    local arg1 = event.args and event.args[1]
    local ges = type(arg1) == "table" and arg1.ges and arg1 or nil
    if ges and ges.pos and inside(ges.pos, self.dimen) then
        if ges.ges == "tap" then
            for _, b in ipairs(self._buttons or {}) do
                if inside(ges.pos, b.dimen) then
                    if b.callback then b.callback() end
                    return true
                end
            end
            -- A tap on the panel's frame or title: collapse.
            if self.expanded then self:_expand(false) end
        end
        return true     -- never let a touch on the bubble reach the page
    end
    -- Touches and keys elsewhere belong to the screens below. Only these:
    -- broadcast events (settings flush, rotation...) already reach every
    -- widget, and forwarding them would deliver them twice.
    local h = event.handler
    if ges or h == "onGesture" or h == "onKeyPress" or h == "onKeyRepeat"
            or h == "onKeyRelease" then
        return self:_dispatchBelow(event)
    end
    return false
end

function FloatingPlayer:onCloseWidget()
    UIManager:setDirty("all", function() return "ui", self.dimen end)
end

return FloatingPlayer
