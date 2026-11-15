--[[--
Ask how to read a book when it opens: play its embedded audiobook (EPUB
Media Overlays) or read it aloud with Read-Along's own text-to-speech.

Both offers are off by default (settings "open_choice_narrated" and
"open_choice_tts_only"). The question is a plain ButtonDialog shown from
the reader's init, so it does not depend on the home screen in use
(stock file browser, ZenOS or SimpleUI).
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local OpenChoice = {}

-- Seconds after the reader starts before the question shows: lets the page
-- render and the floating player hand a running narration back first.
OpenChoice.DELAY_S = 1.2

local function docPath(plugin)
    local doc = plugin.ui and plugin.ui.document
    return doc and (doc.file_path or doc.file)
end

local function somethingPlaying(plugin)
    local busy = false
    pcall(function()
        local ms, sc = plugin.media_sync, plugin.sync_controller
        if ms and (ms:isPlaying() or ms:isPaused()) then busy = true end
        if sc and (sc:isPlaying() or sc:isPaused()) then busy = true end
    end)
    return busy
end

--- Called from the reader's init. Schedules the question when one of the
--- two settings asks for it and nothing else already decided what to play.
function OpenChoice.maybeOffer(plugin, _)
    if not plugin._init_ok then return end
    local want_narrated = plugin:getSetting("open_choice_narrated", false)
    local want_tts_only = plugin:getSetting("open_choice_tts_only", false)
    if not (want_narrated or want_tts_only) then return end
    local path = docPath(plugin)
    if not path then return end
    -- "Play aligned/enriched audiobook" from the file browser already chose.
    -- (Must run before _checkPendingAlignedStart clears the request.)
    local pending = plugin._pending_aligned_start
    if pending and pending.path == path then return end

    UIManager:scheduleIn(OpenChoice.DELAY_S, function()
        if docPath(plugin) ~= path then return end
        if somethingPlaying(plugin) then return end
        local narrated = false
        pcall(function() narrated = plugin:_hasMediaOverlays() end)
        if narrated and not want_narrated then return end
        if not narrated and not want_tts_only then return end
        OpenChoice.show(plugin, narrated, _)
    end)
end

function OpenChoice.show(plugin, narrated, _)
    local dialog
    local buttons = {}
    if narrated then
        table.insert(buttons, {{
            text = _("Play audiobook"),
            callback = function()
                UIManager:close(dialog)
                logger.info("Audiobook: open choice -> embedded audiobook")
                plugin:startMediaPlayback()
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Read aloud with text-to-speech"),
        callback = function()
            UIManager:close(dialog)
            logger.info("Audiobook: open choice -> TTS")
            plugin:startReadAlong()
        end,
    }})
    table.insert(buttons, {{
        text = _("Just read"),
        callback = function()
            UIManager:close(dialog)
        end,
    }})
    dialog = ButtonDialog:new{
        title = narrated
            and _("This book has a built-in audiobook. How do you want to read it?")
            or _("Read this book aloud?"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return OpenChoice
