--[[--
Bluetooth UI functions for the Audiobook plugin.
Handles BT device menus, connect/disconnect, scan, and
the disconnect alert watcher.

All functions take `plugin` (the Audiobook WidgetContainer instance)
as their first parameter to access settings, bt_manager, etc.

@module btui
--]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("audiobook_gettext")
local T = require("ffi/util").template

local BtUI = {}

--- Build the BT disconnect alert interval submenu.
function BtUI.buildBTDisconnectMenu(plugin)
    local options = {
        { label = _("Off"),  value = 0 },
        { label = _("15 s"), value = 15 },
        { label = _("30 s"), value = 30 },
        { label = _("60 s"), value = 60 },
    }
    local items = {}
    for _, opt in ipairs(options) do
        table.insert(items, {
            text = opt.label,
            checked_func = function()
                return plugin:getSetting("bt_disconnect_check", 30) == opt.value
            end,
            callback = function()
                plugin:setSetting("bt_disconnect_check", opt.value)
            end,
        })
    end
    return items
end

--- Top-level label for the Bluetooth menu entry.
-- Shows connected device name when available.
function BtUI.btMenuLabel(plugin)
    local bt = plugin.bt_manager
    if not bt then
        return _("Bluetooth (unavailable)")
    end
    -- On Kindle, BT is managed by the OS; show simple status
    if bt:getStackType() == "kindle" then
        local powered = bt:isPowered()
        return powered and _("Bluetooth (Kindle)") or _("Bluetooth (off)")
    end
    if not bt:isPowered() then
        return _("Bluetooth (off)")
    end
    -- Find a connected device to show its name
    local devices = bt:listAudioDevices()
    for _i, dev in ipairs(devices) do
        if dev.connected then
            local dname = dev.name ~= "" and dev.name or dev.address
            return T(_("BT: %1"), dname)
        end
    end
    -- Powered but nothing connected
    local saved = plugin:getSetting("bt_device_name", nil)
    if saved then
        return T(_("BT: %1 (not connected)"), saved)
    end
    return _("Bluetooth (on)")
end

function BtUI.buildBluetoothMenu(plugin)
    local bt = plugin.bt_manager
    local menu = {}

    if not bt then
        table.insert(menu, {
            text = _("Bluetooth unavailable"),
            enabled = false,
        })
        return menu
    end

    -- On Kindle, BT is managed by the Amazon firmware through the
    -- com.lab126.btfd LIPC service.  BTManager implements scan, pair,
    -- connect, disconnect and forget on top of it, so Kindle now uses
    -- the same device-list menu as every other platform (below).  The
    -- only Kindle-specific extra is a settings hint for pairing flows
    -- that need an on-screen confirmation dialog from the firmware.

    local powered = bt:isPowered()
    local menu = {}

    -- Power toggle
    table.insert(menu, {
        text = powered and _("Turn Bluetooth off") or _("Turn Bluetooth on"),
        callback = function()
            if powered then
                bt:powerOff()
                plugin:setSetting("bt_device_addr", nil)
                UIManager:show(InfoMessage:new{
                    text = _("Bluetooth turned off."),
                    timeout = 2,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = _("Turning Bluetooth on…"),
                    timeout = 1,
                })
                local ok = bt:powerOn()
                if ok then
                    UIManager:show(InfoMessage:new{
                        text = _("Bluetooth is on."),
                        timeout = 2,
                    })
                else
                    local msg
                    if Device.isKobo and Device:isKobo() and bt:getStackType() == "bluez" then
                        msg = _("Failed to power on Bluetooth.\n\nOn some Kobo models, the Bluetooth hardware must first be initialized by the stock reading software. Please exit KOReader, pair your headphones in the Kobo library, then return to KOReader.\n\nIf Bluetooth was already working in the Kobo library, generate a bug report (Audiobook > Generate bug report) and share it on GitHub.")
                    else
                        msg = _("Failed to power on Bluetooth.")
                    end
                    UIManager:show(InfoMessage:new{
                        text = msg,
                        timeout = 8,
                    })
                end
            end
        end,
    })

    if not powered then
        return menu
    end

    -- Scan for devices
    table.insert(menu, {
        text = _("Scan for new devices..."),
        callback = function()
            BtUI.btScanAndShow(plugin)
        end,
    })

    -- List known / visible devices — single-tap to connect
    local devices = bt:listAudioDevices()
    if #devices == 0 then
        table.insert(menu, {
            text = _("No devices found. Tap Scan above."),
            enabled = false,
        })
    end
    for _, dev in ipairs(devices) do
        local label = dev.name ~= "" and dev.name or dev.address
        local icon = "  "
        if dev.connected then
            icon = "[*] "
        elseif dev.paired then
            icon = "✓ "
        end
        table.insert(menu, {
            text = icon .. label,
            -- Tap = connect (or disconnect if already connected)
            callback = function(touchmenu_instance)
                BtUI.btQuickConnect(plugin, dev, touchmenu_instance)
            end,
            -- Hold = show more actions (forget, info)
            hold_callback = function(touchmenu_instance)
                BtUI.btDeviceHoldMenu(plugin, dev, touchmenu_instance)
            end,
            checked_func = function()
                return dev.connected
            end,
        })
    end

    return menu
end

--- Quick connect/disconnect: tap on a device row in the BT menu.
function BtUI.btQuickConnect(plugin, dev, touchmenu_instance)
    local bt = plugin.bt_manager
    local name = dev.name ~= "" and dev.name or dev.address

    if dev.connected then
        -- Already connected → disconnect
        bt:disconnect(dev.address)
        dev.connected = false  -- update captured state so checked_func refreshes
        plugin:setSetting("bt_device_addr", nil)
        plugin:setSetting("bt_device_name", nil)
        UIManager:show(InfoMessage:new{
            text = T(_("Disconnected from %1."), name),
            timeout = 2,
        })
        -- Menu auto-refreshes via checked_func after callback returns
        return
    end

    -- Connecting
    UIManager:show(InfoMessage:new{
        text = T(_("Connecting to %1…\nVerifying audio…"), name),
        timeout = 8,
    })
    UIManager:scheduleIn(0.3, function()
        -- Pair first if needed
        if not dev.paired then
            local ok, err = bt:pair(dev.address)
            if ok then
                dev.paired = true
            else
                -- Pairing may report failure but the device could still be
                -- connectable (e.g. already paired from a previous session
                -- but D-Bus Paired property lagged behind).  Try connecting
                -- anyway instead of bailing out immediately.
                logger.warn("BtUI: pairing reported failure:", err,
                            "-- attempting connect anyway")
            end
        end
        local ok, err = bt:connect(dev.address)
        if ok then
            dev.connected = true  -- update captured state
            -- Remember this as the preferred device
            plugin:setSetting("bt_device_addr", dev.address)
            plugin:setSetting("bt_device_name", name)

            -- Re-probe audio player now that BT is connected and bluealsa
            -- may have been started by connect().
            local engine = plugin.tts_engine
            if engine then
                engine._cached_player = nil
                engine._no_real_audio_output = false
                engine.player_cmd = engine:findAudioPlayer()
            end

            -- Check if there's an actual audio output path to this BT device.
            -- On BlueZ Kobo without mtkbtmwrpcaudiosink, audio won't reach
            -- the headphones even if the connection succeeds.
            local has_bt_audio = engine and (
                engine.audio_player_type == "gst-bt"
                or engine.audio_player_type == "android"
                or engine.audio_player_type == "bluealsa")
            if has_bt_audio then
                UIManager:show(InfoMessage:new{
                    text = T(_("Connected to %1."), name),
                    timeout = 2,
                })
            else
                logger.warn("BtUI: BT connected but no BT audio sink found")
                UIManager:show(InfoMessage:new{
                    text = T(_("Connected to %1.\n\nNote: no Bluetooth audio sink was detected on this device. Audio may play through the internal speaker only.\n\nIf you hear no sound, your device model may not support Bluetooth audio streaming."), name),
                    timeout = 8,
                })
            end
            -- Scan for AVRCP media control input device (may appear after connect)
            UIManager:scheduleIn(2.0, function()
                local BtMediaControl = dofile(
                    (debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./")
                    .. "btmediacontrol.lua")
                pcall(BtMediaControl.rescan)
            end)
        else
            logger.warn("BtUI: connection failed:", err)
            UIManager:show(InfoMessage:new{
                text = T(_("Connection failed: %1\n\nBluetooth will be turned off to prevent device standby issues."), err or "unknown"),
                timeout = 4,
            })
            -- Power off BT to prevent the Kobo standby death spiral:
            -- when BT is powered on, the kernel blocks writes to
            -- /sys/power/state, causing repeated standby failures
            -- that eventually escalate to a full device power-off.
            bt:powerOff()
        end
        -- Refresh the menu to show updated connection state
        if touchmenu_instance then
            touchmenu_instance:updateItems()
        end
    end)
end

--- Long-press on a device row: show additional actions.
function BtUI.btDeviceHoldMenu(plugin, dev, touchmenu_instance)
    local bt = plugin.bt_manager
    local name = dev.name ~= "" and dev.name or dev.address
    local ButtonDialog = require("ui/widget/buttondialog")

    local buttons = {}

    if dev.connected then
        table.insert(buttons, {{
            text = _("Disconnect"),
            callback = function()
                UIManager:close(plugin._bt_dialog)
                bt:disconnect(dev.address)
                plugin:setSetting("bt_device_addr", nil)
                plugin:setSetting("bt_device_name", nil)
                UIManager:show(InfoMessage:new{
                    text = T(_("Disconnected from %1."), name),
                    timeout = 2,
                })
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }})
    else
        table.insert(buttons, {{
            text = _("Connect"),
            callback = function()
                UIManager:close(plugin._bt_dialog)
                BtUI.btQuickConnect(plugin, dev)
                if touchmenu_instance then
                    UIManager:scheduleIn(4, function()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end)
                end
            end,
        }})
    end

    if dev.paired then
        table.insert(buttons, {{
            text = _("Forget (un-pair)"),
            callback = function()
                UIManager:close(plugin._bt_dialog)
                bt:remove(dev.address)
                if dev.address == plugin:getSetting("bt_device_addr", nil) then
                    plugin:setSetting("bt_device_addr", nil)
                    plugin:setSetting("bt_device_name", nil)
                end
                UIManager:show(InfoMessage:new{
                    text = T(_("Removed %1."), name),
                    timeout = 2,
                })
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }})
    end

    table.insert(buttons, {{
        text = T(_("%1"), dev.address),
        enabled = false,
    }})

    table.insert(buttons, {{
        text = _("Cancel"),
        callback = function()
            UIManager:close(plugin._bt_dialog)
        end,
    }})

    plugin._bt_dialog = ButtonDialog:new{
        title = name,
        buttons = buttons,
    }
    UIManager:show(plugin._bt_dialog)
end

function BtUI.btScanAndShow(plugin)
    local bt = plugin.bt_manager

    -- Ensure powered
    if not bt:isPowered() then
        local ok = bt:powerOn()
        if not ok then
            local msg
            if Device.isKobo and Device:isKobo() and bt:getStackType() == "bluez" then
                msg = _("Could not power on Bluetooth.\n\nOn some Kobo models, the Bluetooth hardware must first be initialized by the stock reading software. Please exit KOReader, pair your headphones in the Kobo library, then return to KOReader.")
            else
                msg = _("Could not power on Bluetooth.")
            end
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 8,
            })
            return
        end
    end

    UIManager:show(InfoMessage:new{
        text = _("Scanning for Bluetooth devices…\n\nPlease wait 8 seconds."),
        timeout = 2,
    })

    -- Run the scan in a deferred callback so the InfoMessage can render
    UIManager:scheduleIn(0.5, function()
        bt:startDiscovery()
        -- Wait for scan results, then stop and show device list
        UIManager:scheduleIn(8, function()
            bt:stopDiscovery()
            local devices = bt:listAudioDevices()
            local lines = {}
            for _, dev in ipairs(devices) do
                local tag = ""
                if dev.connected then
                    tag = " [*]"
                elseif dev.paired then
                    tag = " ✓"
                end
                local name = dev.name ~= "" and dev.name or dev.address
                table.insert(lines, name .. tag)
            end
            if #lines == 0 then
                table.insert(lines, _("No audio devices found."))
            end
            UIManager:show(InfoMessage:new{
                text = _("Scan complete:\n\n") .. table.concat(lines, "\n")
                    .. _("\n\nOpen the Bluetooth menu to connect."),
                timeout = 6,
            })
        end)
    end)
end

-- ── BT Disconnect Watcher ────────────────────────────────────────────

-- Start a low-frequency Bluetooth disconnect watcher while read-along
-- is active.  It checks, via D-Bus, whether any audio-related BT
-- device is still connected, and shows a notification if everything
-- disconnects.  Runs only while this plugin is in use to avoid
-- unnecessary battery drain.
--- Warn when the output is routed to Bluetooth but nothing is connected.
--
-- A paired-but-disconnected device is otherwise indistinguishable from a
-- broken player: no link means no sink, nothing holds the audio socket, the
-- pipeline stalls, and the only symptom is silence.
--
-- This is the case the disconnect watcher cannot see, because that watcher
-- only fires on a connected -> disconnected transition and stays quiet for a
-- device that was already gone when playback began.
--
-- Fires only when the route really is Bluetooth and no audio device is
-- connected, so a user on the built-in speaker is never nagged.  Honours
-- bt_disconnect_check as the off switch and warns once per playback rather
-- than once per tick.
--
-- @tparam table plugin  Audiobook widget container
-- @tparam boolean routed_to_bt  Whether this playback's audio goes to a
--   Bluetooth sink. There is no single signal for that in the plugin: the
--   read-aloud path knows it from `tts_engine.audio_player_type` being
--   "gst-bt" or "bluealsa", and the media path from its persistent pipeline
--   being the A2DP sink. Callers pass whichever applies.
-- @treturn bool  True when the warning was shown
function BtUI.warnIfBtRouteSilent(plugin, routed_to_bt)
    local bt = plugin and plugin.bt_manager
    if not bt or not routed_to_bt then return false end

    if bt:anyAudioDeviceConnected() then
        -- A live device clears the flag so a later drop warns again.
        plugin._bt_silent_warned = nil
        return false
    end
    return BtUI._showBtSilentDialog(plugin)
end

--- Show the "no Bluetooth device connected" dialog, once per playback.
--
-- Split from the route check because the disconnect watcher is only running
-- while a Bluetooth route is active, so it needs the dialog without that gate.
--
-- Returns silently on Kindle (its BT is OS-managed and cannot be enumerated)
-- and when the user has turned the advisory off, so every caller can invoke it
-- without repeating those conditions.
--
-- With auto reconnect on, connect to the saved headset instead of asking;
-- the dialog then only appears when that gives up (force = true).
--
-- @tparam table plugin  Audiobook widget container
-- @tparam bool force  Show the dialog even when auto connect could run
-- @treturn bool  True when the dialog was shown (or auto connect took over)
function BtUI._showBtSilentDialog(plugin, force)
    local bt = plugin and plugin.bt_manager
    if not bt then return false end
    if bt:getStackType() == "kindle" then return false end
    if not force and BtUI._autoConnectAtStart(plugin) then return true end
    -- bt_disconnect_check is the existing off switch for Bluetooth advisories,
    -- reused here so there is one setting rather than two.
    if plugin:getSetting("bt_disconnect_check", 30) == 0 then return false end
    if plugin._bt_silent_warned then return false end
    plugin._bt_silent_warned = true

    local name = plugin:getSetting("bt_device_name", nil)
    local address = plugin:getSetting("bt_device_addr", nil)

    local ButtonDialog = require("ui/widget/buttondialog")
    local buttons = {}

    if address then
        table.insert(buttons, {{
            text = name and T(_("Reconnect %1"), name) or _("Reconnect"),
            callback = function()
                UIManager:close(plugin._bt_silent_dialog)
                UIManager:show(InfoMessage:new{
                    text = name and T(_("Reconnecting to %1..."), name)
                        or _("Reconnecting..."),
                    timeout = 2,
                })
                local ok, err = bt:connect(address)
                UIManager:show(InfoMessage:new{
                    text = ok and (name and T(_("Connected to %1."), name)
                            or _("Connected."))
                        or (err or _("Could not reconnect. Turn the speaker on and try again.")),
                    timeout = ok and 2 or 6,
                })
                -- Let a later attempt warn again if it did not take.
                if ok then plugin._bt_silent_warned = nil end
            end,
        }})
    end

    table.insert(buttons, {{
        text = _("Play anyway"),
        callback = function() UIManager:close(plugin._bt_silent_dialog) end,
    }})

    -- Name it only when Bluetooth is actually on; otherwise the honest
    -- statement is that it is off, and the reconnect button simply fails.
    local powered = bt:isPowered()
    local title
    if not powered then
        title = _("Bluetooth is off, so you will not hear anything.")
    elseif name then
        title = T(_("Bluetooth is on but %1 is not connected, so you will not hear anything."), name)
    else
        title = _("Bluetooth is on but no audio device is connected, so you will not hear anything.")
    end

    plugin._bt_silent_dialog = ButtonDialog:new{
        title = title,
        buttons = buttons,
    }
    UIManager:show(plugin._bt_silent_dialog)
    logger.warn("BtUI: no connected BT audio device, warned (powered:",
        tostring(powered), "device:", name or "none", ")")
    return true
end

-- ── Auto reconnect while playing ─────────────────────────────────────

--- Setting: when the headset drops during playback, pause, reconnect
--- without asking, and resume. On by default; off restores the plain
--- "disconnected" message and the Reconnect prompt.
function BtUI.autoReconnectEnabled(plugin)
    return plugin:getSetting("bt_auto_reconnect", true) and true or false
end

-- How often the watcher checks the link while auto reconnect is on. The
-- device list is cached for 5 s, so polling faster buys nothing.
BtUI.AUTO_RECONNECT_POLL_S = 5
-- How long to keep trying before falling back to the Reconnect prompt.
BtUI.AUTO_RECONNECT_GIVE_UP_S = 120
-- Ticks (3 s apart) on which to ask the stack to connect. In between only
-- the cheap "is anything connected" check runs: a connect call blocks the
-- UI while the stack pages the headset, and AirPods often come back by
-- themselves once taken out of the case.
BtUI.AUTO_RECONNECT_CONNECT_TICKS = { [1] = true, [5] = true, [10] = true,
    [18] = true, [28] = true }

local function mediaPlaying(plugin)
    local ms = plugin.media_sync
    return ms ~= nil and ms.state == "playing"
end

--- The headset dropped while a book was playing: pause, reconnect, resume.
--- Media playback only; the read-aloud (TTS) path keeps the old message.
-- @treturn bool true when the auto reconnect took over
--- Shared reconnect loop: scan in the background while the headset is not
--- visible (no UI freeze), connect once it is (or on a scheduled retry),
--- and report back once the link has been up on two checks 3 s apart.
-- opts.still_wanted(): false aborts quietly.
-- opts.on_back(elapsed_s): link confirmed.
-- opts.on_give_up(elapsed_s): not back within AUTO_RECONNECT_GIVE_UP_S.
-- opts.power_on: turn Bluetooth on first if it is off.
-- opts.message: shown with a Cancel button while the loop runs.
-- opts.on_cancel(): the user tapped Cancel (the loop and scan stop).
function BtUI._connectLoop(plugin, address, opts)
    local bt = plugin.bt_manager
    local started = UIManager:getTime()
    local tick, up_count = 0, 0
    local scanning = false
    local cancelled = false
    local dialog
    local function stop_scan()
        if scanning then
            scanning = false
            pcall(bt.stopDiscovery, bt)
        end
    end
    local function close_dialog()
        if dialog then
            UIManager:close(dialog)
            dialog = nil
        end
    end
    local wanted = opts.still_wanted
    opts.still_wanted = function() return not cancelled and wanted() end
    local on_back, on_give_up = opts.on_back, opts.on_give_up
    opts.on_back = function(s) close_dialog(); on_back(s) end
    opts.on_give_up = function(s) close_dialog(); on_give_up(s) end
    if opts.message then
        local ButtonDialog = require("ui/widget/buttondialog")
        dialog = ButtonDialog:new{
            title = opts.message,
            buttons = {{{
                text = _("Cancel"),
                callback = function()
                    cancelled = true
                    close_dialog()
                    stop_scan()
                    logger.warn("BtUI: reconnect cancelled by the user")
                    if opts.on_cancel then opts.on_cancel() end
                end,
            }}},
        }
        UIManager:show(dialog)
    end
    local function elapsed()
        return require("ui/time").to_s(UIManager:getTime() - started)
    end
    local function step()
        if not opts.still_wanted() then
            stop_scan()
            close_dialog()
            if not cancelled then
                logger.warn("BtUI: reconnect cancelled (state changed)")
            end
            return
        end
        tick = tick + 1
        if tick == 1 and opts.power_on then
            local okp, powered = pcall(bt.isPowered, bt)
            if okp and not powered then
                logger.warn("BtUI: Bluetooth is off; turning it on to connect")
                pcall(bt.powerOn, bt)
                if not opts.still_wanted() then close_dialog() return end
            end
        end
        local known = true
        if bt.deviceKnown then
            local okk, k = pcall(bt.deviceKnown, bt, address)
            known = okk and k
        end
        if not known then
            if not scanning then
                scanning = pcall(bt.startDiscovery, bt)
                logger.warn("BtUI: headset not visible; scanning in the background")
            end
        elseif scanning or BtUI.AUTO_RECONNECT_CONNECT_TICKS[tick] then
            -- Just reappeared (or a scheduled retry): connect now.
            stop_scan()
            pcall(bt.connect, bt, address)
            if not opts.still_wanted() then close_dialog() return end
        end
        pcall(bt.clearAudioDeviceCache, bt)
        local ok, up = pcall(bt.anyAudioDeviceConnected, bt)
        -- Need the link up on two checks in a row: right after going into
        -- the case the link can flap, and resuming into it drops again.
        if ok and up then up_count = up_count + 1 else up_count = 0 end
        if up_count == 1 then
            logger.warn("BtUI: headset link up; confirming")
        end
        if up_count >= 2 then
            stop_scan()
            logger.warn("BtUI: headset back after", elapsed(), "s")
            plugin._bt_last_connected = true
            plugin._bt_silent_warned = nil
            opts.on_back(elapsed())
            return
        end
        if elapsed() >= BtUI.AUTO_RECONNECT_GIVE_UP_S then
            stop_scan()
            logger.warn("BtUI: reconnect gave up after", elapsed(), "s")
            opts.on_give_up(elapsed())
            return
        end
        UIManager:scheduleIn(3, step)
    end
    UIManager:scheduleIn(1, step)
end

function BtUI._autoReconnectOnDrop(plugin)
    if not BtUI.autoReconnectEnabled(plugin) then return false end
    if not mediaPlaying(plugin) then return false end
    local bt = plugin.bt_manager
    local address = plugin:getSetting("bt_device_addr", nil)
    if not bt or not address then return false end
    local name = plugin:getSetting("bt_device_name", nil)

    plugin:pauseReadAlong()
    -- The sink was fed by a link that is gone. Give the daemon back now so
    -- the resume below builds a fresh one on the new link.
    local eng = plugin.media_sync and plugin.media_sync.media_engine
    if eng and eng.releasePausedOutput then
        pcall(eng.releasePausedOutput, eng, "bt drop")
    end

    plugin._bt_auto_reconnect_token = (plugin._bt_auto_reconnect_token or 0) + 1
    local token = plugin._bt_auto_reconnect_token
    logger.warn("BtUI: headset dropped while playing; auto reconnect", address)
    local function still_ours()
        -- Abort if the user resumed, stopped, or a newer drop took over.
        return plugin._bt_auto_reconnect_token == token
            and plugin.media_sync and plugin.media_sync.state == "paused"
    end
    BtUI._connectLoop(plugin, address, {
        message = name and T(_("%1 disconnected. Paused, reconnecting..."), name)
            or _("Headset disconnected. Paused, reconnecting..."),
        -- Cancel: stay paused; play resumes on whatever is connected then.
        still_wanted = still_ours,
        on_back = function()
            -- The link was already confirmed 3 s apart; A2DP is up behind it.
            UIManager:scheduleIn(0.5, function()
                if not still_ours() then return end
                plugin:resumeReadAlong()
                UIManager:show(InfoMessage:new{
                    text = name and T(_("%1 reconnected. Resuming."), name)
                        or _("Reconnected. Resuming."),
                    timeout = 2,
                })
            end)
        end,
        on_give_up = function()
            plugin._bt_silent_warned = nil
            BtUI._showBtSilentDialog(plugin, true)
        end,
    })
    return true
end

--- Play was pressed with the saved headset not connected: connect to it
--- (turning Bluetooth on if needed) instead of asking. MediaEngine is
--- already holding the position and starts by itself once a device
--- connects (_startBtReattachWatcher). The Reconnect prompt only appears
--- if this gives up.
-- @treturn bool true when the auto connect took over
function BtUI._autoConnectAtStart(plugin)
    if not BtUI.autoReconnectEnabled(plugin) then return false end
    local bt = plugin.bt_manager
    local address = plugin:getSetting("bt_device_addr", nil)
    if not bt or not address then return false end
    local name = plugin:getSetting("bt_device_name", nil)
    if plugin._bt_auto_connecting then
        -- Already connecting (started when Play was pressed): playback
        -- starts by itself once the headset is up. Say so near the bar,
        -- as a toast that does not block page turns.
        local text = name and T(_("Connecting to %1..."), name) or _("Connecting to the headset...")
        local bar = plugin.media_sync and plugin.media_sync.playback_bar
        if bar and bar._showHint then
            pcall(bar._showHint, bar, text)
        end
        return true
    end
    plugin._bt_auto_connecting = true
    logger.warn("BtUI: headset not connected at play; connecting", address)
    local function wanted()
        local ms = plugin.media_sync
        return ms ~= nil and ms.state ~= "stopped"
    end
    BtUI._connectLoop(plugin, address, {
        power_on = true,
        message = name and T(_("Connecting to %1..."), name) or _("Connecting to the headset..."),
        -- Cancel: pause, so playback does not start by itself if the
        -- headset turns up later; play tries again.
        on_cancel = function()
            plugin._bt_auto_connecting = nil
            pcall(plugin.pauseReadAlong, plugin)
        end,
        still_wanted = function()
            if wanted() then return true end
            plugin._bt_auto_connecting = nil
            return false
        end,
        on_back = function()
            plugin._bt_auto_connecting = nil
            UIManager:show(InfoMessage:new{
                text = name and T(_("Connected to %1."), name) or _("Connected."),
                timeout = 2,
            })
        end,
        on_give_up = function()
            plugin._bt_auto_connecting = nil
            plugin._bt_silent_warned = nil
            BtUI._showBtSilentDialog(plugin, true)
        end,
    })
    return true
end

--- Play was pressed on a read-along: start connecting the saved headset
--- now, quietly (no dialog), while the audiobook loads, instead of after.
--- Turning Bluetooth on and paging AirPods takes 20-25 s on a Clara BW.
--- When the audio starts, _autoConnectAtStart sees this connect running
--- and joins it; playback starts once the headset is up.
-- @treturn bool true when a connect was started
function BtUI.preconnectForBook(plugin, doc_path)
    if not plugin:getSetting("bt_connect_on_play", true) then return false end
    local bt = plugin.bt_manager
    local address = plugin:getSetting("bt_device_addr", nil)
    if not bt or not address then return false end
    if plugin._bt_auto_connecting then return false end
    local ok_c, up = pcall(bt.anyAudioDeviceConnected, bt)
    if ok_c and up then return false end
    plugin._bt_auto_connecting = true
    logger.warn("BtUI: Play pressed; connecting", address, "while the audiobook loads")
    local function book_open()
        local doc = plugin.ui and plugin.ui.document
        return doc ~= nil and (doc.file_path or doc.file) == doc_path
    end
    local function starting()
        local ms = plugin.media_sync
        return plugin._overlay_job ~= nil or plugin._bar_loading ~= nil
            or (ms ~= nil and ms.state ~= "stopped")
    end
    BtUI._connectLoop(plugin, address, {
        power_on = true,
        still_wanted = function()
            -- Keep going while this book loads or plays; stop on ✕/close.
            if (book_open() and starting()) or mediaPlaying(plugin) then return true end
            plugin._bt_auto_connecting = nil
            return false
        end,
        on_back = function(s)
            plugin._bt_auto_connecting = nil
            logger.warn("BtUI: headset ready", s, "s after Play")
        end,
        on_give_up = function()
            plugin._bt_auto_connecting = nil
            logger.warn("BtUI: headset not found after Play")
            -- Play joined this connect and is waiting on it: same prompt
            -- as a connect started by Play.
            local ms = plugin.media_sync
            if ms and ms.state ~= "stopped" then
                plugin._bt_silent_warned = nil
                BtUI._showBtSilentDialog(plugin, true)
            end
        end,
    })
    return true
end

-- ── Disconnect events ────────────────────────────────────────────────
-- Polling for a drop starts a dbus-send process every few seconds.
-- KOReader's Kobo plugin (kobo.koplugin) already runs one dbus-monitor
-- for Bluetooth property changes and lets other code subscribe; its
-- Connected=false arrives the moment the headset drops (measured: same
-- second, 2 s before the 5 s poll). When that monitor is running, listen
-- to it and keep only a slow safety poll.
BtUI.EVENT_SAFETY_POLL_S = 60
local EVENT_KEY = "audiobook:bt_watch"

local function koboDbusMonitor(plugin, quiet)
    local ui = plugin and plugin.ui
    -- PluginLoader names a plugin after its folder (kobo.koplugin -> "kobo");
    -- the "kobo_plugin" in its source is ignored for that.
    local kp = ui and (ui.kobo or ui.kobo_plugin)
    local kb = kp and kp.kobo_bluetooth
    local mon = kb and kb.dbus_monitor
    local why
    if not ui then why = "no ui"
    elseif not kp then why = "no ui.kobo"
    elseif not kb then why = "no kobo_bluetooth"
    elseif not mon then why = "no dbus_monitor"
    elseif not (mon.registerCallback and mon.unregisterCallback) then why = "no callback API"
    elseif mon.isActive and not mon:isActive() then why = "monitor not active"
    end
    if why then
        if not quiet then
            logger.warn("BtUI: no Kobo plugin disconnect events (" .. why .. "); polling")
        end
        return nil
    end
    return mon
end

--- Subscribe to the Kobo plugin's disconnect events if its monitor runs.
function BtUI._subscribeEvents(plugin, quiet)
    local mon = koboDbusMonitor(plugin, quiet)
    if not mon then return false end
    mon:registerCallback(EVENT_KEY, function(address, props)
        BtUI._onConnectedEvent(plugin, address, props)
    end, 60)
    plugin._bt_event_mon = mon
    logger.warn("BtUI: watching disconnect events from the Kobo plugin;",
        "safety poll every", BtUI.EVENT_SAFETY_POLL_S, "s")
    return true
end

--- The headset went away: hand it to auto reconnect, or tell the user.
function BtUI._handleDrop(plugin)
    local name = plugin:getSetting("bt_device_name", nil)
    if BtUI._autoReconnectOnDrop(plugin) then
        -- handled: paused, reconnecting, resumes on its own
        logger.dbg("BtUI: drop handed to auto reconnect")
    elseif plugin:getSetting("bt_disconnect_check", 30) ~= 0 then
        UIManager:show(InfoMessage:new{
            text = name
                and T(_("Bluetooth audio device %1 disconnected."), name)
                or _("Bluetooth audio device disconnected."),
            timeout = 4,
        })
    end
end

function BtUI._onConnectedEvent(plugin, address, props)
    if not (plugin._bt_disconnect_watching and props and props.Connected ~= nil) then
        return
    end
    local saved = plugin:getSetting("bt_device_addr", nil)
    if saved and address and saved:upper() ~= address:upper() then return end
    if props.Connected == false then
        if plugin._bt_last_connected ~= false then
            plugin._bt_last_connected = false
            logger.warn("BtUI: disconnect event for", address)
            -- Off the monitor's dispatch: pausing and reconnecting do I/O.
            UIManager:nextTick(function()
                if plugin._bt_disconnect_watching then BtUI._handleDrop(plugin) end
            end)
        end
    else
        plugin._bt_last_connected = true
    end
end

--- Watcher interval: the alert setting, tightened while auto reconnect is
--- on so a drop is caught within seconds. With disconnect events it is
--- only a safety net. 0 means the watcher is off.
local function watcherInterval(plugin)
    local interval = plugin:getSetting("bt_disconnect_check", 30)
    if BtUI.autoReconnectEnabled(plugin) then
        if interval == 0 or interval > BtUI.AUTO_RECONNECT_POLL_S then
            interval = BtUI.AUTO_RECONNECT_POLL_S
        end
    end
    if interval > 0 and plugin._bt_event_mon then
        interval = math.max(interval, BtUI.EVENT_SAFETY_POLL_S)
    end
    return interval
end

-- ── Bluetooth scans by other plugins ────────────────────────────────
-- On the MTK stack a device scan (StartDiscovery) during playback breaks
-- the A2DP stream: the sink keeps accepting audio, the clock keeps
-- moving, nothing is heard, and pause/resume does not bring it back; only
-- a fresh audioout daemon does. ZenOS's Bluetooth menu scans when opened
-- (log 2026-11-14 22:03:26). Wrap its startScan so that when a scan that
-- began during playback ends, the output is rebuilt at the current
-- position (about a second of gap instead of silence).
local ZEN_BT_MODULE = "modules/menu/bluetooth/kobo_bluetooth"

--- Rebuild the audio output after a scan: fresh daemon at the position.
function BtUI._refreshAudioAfterScan(plugin)
    local ms = plugin.media_sync
    local eng = ms and ms.media_engine
    if not (ms and eng and eng.releasePausedOutput) then return end
    if ms.state == "playing" then
        logger.warn("BtUI: Bluetooth scan ended during playback; rebuilding audio output")
        plugin:pauseReadAlong()
        pcall(eng.releasePausedOutput, eng, "bt scan")
        plugin:resumeReadAlong()
    elseif ms.state == "paused" then
        -- Resume will start a fresh daemon.
        logger.warn("BtUI: Bluetooth scan while paused; output released for resume")
        pcall(eng.releasePausedOutput, eng, "bt scan")
    end
end

function BtUI._hookZenScan(plugin)
    local M = package.loaded[ZEN_BT_MODULE]
    if type(M) ~= "table" or type(M.startScan) ~= "function" then return false end
    if M._readalong_orig_startScan then
        M._readalong_plugin = plugin
        return true
    end
    M._readalong_orig_startScan = M.startScan
    M._readalong_plugin = plugin
    M.startScan = function(done, ...)
        local p = M._readalong_plugin
        local ms = p and p.media_sync
        local during = ms and (ms.state == "playing" or ms.state == "paused")
        if during then
            logger.warn("BtUI: ZenOS started a Bluetooth scan during playback")
        end
        -- done runs whenever the scan ends: timeout, cancel or failure.
        local function wrapped(...)
            if done then done(...) end
            if during and p then
                UIManager:scheduleIn(0.5, function()
                    pcall(BtUI._refreshAudioAfterScan, p)
                end)
            end
        end
        return M._readalong_orig_startScan(wrapped, ...)
    end
    logger.warn("BtUI: watching ZenOS Bluetooth scans")
    return true
end

function BtUI.startWatcher(plugin)
    -- On Kindle, we can't enumerate BT devices via BlueZ, so the
    -- disconnect watcher would always report "no devices". Skip it.
    if plugin.bt_manager:getStackType() == "kindle" then return end
    pcall(BtUI._hookZenScan, plugin)
    if watcherInterval(plugin) == 0 then
        return  -- user disabled the alert and auto reconnect
    end
    if plugin._bt_disconnect_watching then
        logger.dbg("BtUI: watcher already running")
        return
    end
    plugin._bt_disconnect_watching = true
    plugin._bt_last_connected = nil
    logger.warn("BtUI: disconnect watcher starting")
    BtUI._subscribeEvents(plugin)
    BtUI._scheduleBTDisconnectCheck(plugin)
end

function BtUI.stopWatcher(plugin)
    plugin._bt_disconnect_watching = false
    if plugin._bt_event_mon then
        pcall(plugin._bt_event_mon.unregisterCallback, plugin._bt_event_mon, EVENT_KEY)
        plugin._bt_event_mon = nil
    end
end

function BtUI._scheduleBTDisconnectCheck(plugin)
    if not plugin._bt_disconnect_watching then
        return
    end
    -- If the Kobo plugin's monitor stopped (Bluetooth turned off and on),
    -- drop the stale subscription so the fast poll takes over.
    if plugin._bt_event_mon and plugin._bt_event_mon.isActive
            and not plugin._bt_event_mon:isActive() then
        pcall(plugin._bt_event_mon.unregisterCallback, plugin._bt_event_mon, EVENT_KEY)
        plugin._bt_event_mon = nil
        logger.warn("BtUI: Kobo plugin monitor stopped; polling instead")
    end
    -- Not subscribed (yet, or any more): the Kobo plugin restarts its
    -- monitor when Bluetooth reconnects. Join it again once it runs.
    if not plugin._bt_event_mon then BtUI._subscribeEvents(plugin, true) end
    -- Check at a coarse interval to keep overhead and wakeups low.
    local interval = watcherInterval(plugin)
    if interval == 0 then
        plugin._bt_disconnect_watching = false
        return
    end
    UIManager:scheduleIn(interval, function()
        if not plugin._bt_disconnect_watching then
            return
        end

        local any_connected = plugin.bt_manager:anyAudioDeviceConnected()

        if plugin._bt_last_connected == nil then
            plugin._bt_last_connected = any_connected
            -- The watcher only runs while a Bluetooth route is active, so a
            -- device that was already gone when playback began has no
            -- transition to detect and the baseline is the only chance to say
            -- so.  Without this the plugin plays into silence and explains
            -- nothing, which is exactly how it fails in the field.
            if not any_connected then
                BtUI._showBtSilentDialog(plugin)
            end
        elseif plugin._bt_last_connected and not any_connected then
            plugin._bt_last_connected = any_connected
            BtUI._handleDrop(plugin)
        else
            plugin._bt_last_connected = any_connected
        end

        -- Reschedule next check while watcher is active
        if plugin._bt_disconnect_watching then
            BtUI._scheduleBTDisconnectCheck(plugin)
        end
    end)
end

return BtUI
