--[[--
Hold a book's cover (or its row in the library) to choose how to read it:
play its embedded audiobook (EPUB Media Overlays) or read it aloud with
Read-Along's own text-to-speech.

Both offers are off by default (settings "open_choice_narrated" and
"open_choice_tts_only"). The buttons are added through KOReader's own
FileManager:addFileDialogButtons, which feeds the hold menu of the stock
library, History, Collections and file search, and ZenOS's context menu
(under "More" while ZenOS's "Plugin actions" is on).
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local OpenChoice = {}

-- Seconds after the reader starts before TTS starts: lets the page render.
OpenChoice.TTS_DELAY_S = 1.0

-- book path -> true/false: does it carry Media Overlays (unzip -l is not free)
local narrated_cache = {}

local function isNarrated(plugin, path)
    local v = narrated_cache[path]
    if v == nil then
        v = false
        pcall(function() v = plugin:_documentHasMediaOverlays(path) and true or false end)
        narrated_cache[path] = v
    end
    return v
end

--- Close whichever hold menu is showing (library, History, Collections,
--- file search, or ZenOS's context menu, which ZenOS stores on the chooser).
local function closeHoldMenu()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    local fc = FileManager.getMenuInstance and FileManager.getMenuInstance()
        or (fm and fm.file_chooser)
    for _, owner in ipairs({ fc, fm and fm.history, fm and fm.collections, fm and fm.filesearcher }) do
        if owner and owner.file_dialog then
            UIManager:close(owner.file_dialog)
            owner.file_dialog = nil
        end
    end
end

local function openBook(path)
    local fm = require("apps/filemanager/filemanager").instance
    if fm and fm.openFile then
        fm:openFile(path)
    else
        require("apps/reader/readerui"):showReader(path)
    end
end

--- Called from the FileManager instance's init.
function OpenChoice.registerButtons(plugin, _)
    local fm = plugin.ui
    if not (fm and fm.addFileDialogButtons) then return end
    fm:addFileDialogButtons("audiobook_open_choice", function(file, is_file)
        if not is_file or not plugin._init_ok then return nil end
        local want_narrated = plugin:getSetting("open_choice_narrated", false)
        local want_tts_only = plugin:getSetting("open_choice_tts_only", false)
        if not (want_narrated or want_tts_only) then return nil end
        if not plugin:_isBookFile(file) then return nil end
        local narrated = isNarrated(plugin, file)
        if narrated and not want_narrated then return nil end
        if not narrated and not want_tts_only then return nil end

        local row = {}
        if narrated then
            table.insert(row, {
                text = _("Play audiobook"),
                callback = function()
                    closeHoldMenu()
                    logger.info("Audiobook: hold menu -> embedded audiobook", file)
                    local FileManager = require("apps/filemanager/filemanager")
                    plugin:_startAlignedPlaybackFromBrowserPath(FileManager.instance or fm, file)
                end,
            })
        end
        table.insert(row, {
            text = _("Read aloud (TTS)"),
            callback = function()
                closeHoldMenu()
                logger.info("Audiobook: hold menu -> TTS", file)
                -- The FileManager instance is torn down when the reader
                -- opens; the ReaderUI instance picks this up in its init.
                getmetatable(plugin).__index._pending_tts_start = { path = file }
                openBook(file)
            end,
        })
        return row
    end)
end

--- Called from the ReaderUI instance's init: start TTS when the hold menu
--- asked for it on this book.
function OpenChoice.checkPendingTts(plugin)
    local cls = getmetatable(plugin) and getmetatable(plugin).__index
    local pending = cls and cls._pending_tts_start
    if not pending then return end
    cls._pending_tts_start = nil
    local doc = plugin.ui and plugin.ui.document
    local path = doc and (doc.file_path or doc.file)
    if not path or path ~= pending.path or not plugin._init_ok then return end
    UIManager:scheduleIn(OpenChoice.TTS_DELAY_S, function()
        local d = plugin.ui and plugin.ui.document
        if not d or (d.file_path or d.file) ~= path then return end
        plugin:startReadAlong()
    end)
end

return OpenChoice
