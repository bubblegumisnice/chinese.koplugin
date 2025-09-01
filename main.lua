-- Chinese language support for KOReader with CEDICT StarDict headword lexicon.
-- Fast longest-match selection using headwords; final display via KOReader dictionary.
--
-- Place this file as: frontend/apps/plugins/chinese.koplugin/main.lua
--
-- Copyright (C) 2025
-- Licensed under the GPLv3 or later.

-- Chinese Language Support Plugin for KOReader.
-- Provides integration with a StarDict headword lexicon.
--
-- Implements efficient longest-match selection using headwords,
-- with final display handled through KOReader’s built-in dictionary system.
--
-- Installation:
--   Place the plugin folder in: frontend/apps/plugins/  
--
-- Requirements:
--   • 	A compatible Chinese dictionary (CEDICT recommended). 
--		Set the path to the stardict files on line 210 (including file name, without file extension).
-- 	  	looks like: local dict_base = "/mnt/onboard/.adds/koreader/plugins/chinese.koplugin/cedict"
--		You can also just use the path to an existing Stardict dictionary (koreader/data/dict).
--
-- Copyright (C) 2025
-- Licensed under the GNU GPL v3 or later.

local LanguageSupport = require("languagesupport")
local ReaderDictionary = require("apps/reader/modules/readerdictionary")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local Chinese = WidgetContainer:extend{
    name = "chinese",
    pretty_name = "Chinese",
}

-- Chinese phrases do not exceed 20 characters in running text.
-- CEdict statistics:
-- Length 1: 14497 headwords
-- Length 2: 91454 headwords
-- Length 3: 40669 headwords
-- Length 4: 34562 headwords
-- Length 5: 5606 headwords
-- Length 6: 2474 headwords
-- Length 7: 1638 headwords
-- Length 8: 597 headwords
-- Length 9: 694 headwords
-- Length 10: 214 headwords
-- Length 11: 237 headwords
-- Length 12: 49 headwords
-- Length 13: 52 headwords
-- Length 14: 12 headwords
-- Length 15: 47 headwords
-- Length 16: 2 headwords
-- Length 17: 4 headwords
-- Length 19: 3 headwords
-- Length 20: 2 headwords
local DEFAULT_TEXT_SCAN_LENGTH = 20

-- Punctuation / separators to stop expansion on (full-width + ASCII). Don't include commas as some dictionary entry phrases contain commas.
local CJK_PUNCT = "。．.！？!？；;：:、‧·—－–…‥“”\"『』「」《》〈〉【】（）()〔〕［］〔〕　 \n\t"

local function isPossibleChineseWord(str)
    for c in str:gmatch(util.UTF8_CHAR_PATTERN) do
        if CJK_PUNCT:find(c, 1, true) ~= nil or not util.isCJKChar(c) then
            return false
        end
    end
    return true
end

-- ===== StarDict lexicon loader (headwords only) =====

-- Read big-endian 32-bit
local function read_u32(fh)
    local b1,b2,b3,b4 = fh:read(1), fh:read(1), fh:read(1), fh:read(1)
    if not b4 then return nil end
    return string.byte(b1) * 16777216 + string.byte(b2) * 65536 + string.byte(b3) * 256 + string.byte(b4)
end

-- Read big-endian 64-bit (we don't actually need the value; kept for structure)
local function read_u64(fh)
    local s = fh:read(8)
    if not s or #s ~= 8 then return nil end
    -- Convert to number (lossy > 2^53, but OK—we don't use offsets)
    local t = {string.byte(s,1,8)}
    local hi = t[1]*16777216 + t[2]*65536 + t[3]*256 + t[4]
    local lo = t[5]*16777216 + t[6]*65536 + t[7]*256 + t[8]
    return hi * 4294967296.0 + lo
end

local function parse_ifo(ifo_path)
    local fh = io.open(ifo_path, "rb")
    if not fh then return nil, "cannot open .ifo" end
    local content = fh:read("*a")
    fh:close()
    if not content then return nil, "empty .ifo" end
    if not content:match("^StarDict's dict ifo file") then
        return nil, "not a StarDict .ifo"
    end
    local bits = tonumber(content:match("idxoffsetbits=(%d+)")) or 32
    return { idxoffsetbits = bits }, nil
end

-- Load headwords from uncompressed .idx; ignore offsets/sizes
local function load_headwords_from_idx(idx_path, offset_bits)
    local fh = io.open(idx_path, "rb")
    if not fh then return nil, "cannot open .idx" end
    local words = {}
    while true do
        -- read null-terminated UTF-8 word
        local buf = {}
        while true do
            local ch = fh:read(1)
            if not ch then -- EOF
                fh:close()
                table.sort(words) -- sort for prefix lower_bound
                return words
            end
            if ch == "\0" then break end
            buf[#buf+1] = ch
        end
        local word = table.concat(buf)
        -- skip offset (4 or 8) and size (4)
        if offset_bits == 64 then
            local _ = read_u64(fh); if _ == nil then break end
        else
            local _ = read_u32(fh); if _ == nil then break end
        end
        local __ = read_u32(fh); if __ == nil then break end
        if #word > 0 then
            words[#words+1] = word
        end
    end
    fh:close()
    table.sort(words)
    return words
end

local function lower_bound(arr, key)
    local lo, hi = 1, #arr + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if arr[mid] < key then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

local function build_set(arr)
    local set = {}
    for i = 1, #arr do set[arr[i]] = true end
    return set
end

-- ===== Plugin lifecycle =====

function Chinese:init()
    self.dictionary = (self.ui and self.ui.dictionary) or ReaderDictionary:new()
    self.max_scan_length = G_reader_settings:readSetting("language_chinese_text_scan_length") or DEFAULT_TEXT_SCAN_LENGTH

    -- Add a persistent setting for lexicon on/off
    self.lexicon_enabled = G_reader_settings:readSetting("language_chinese_lexicon_enabled")
    if self.lexicon_enabled == nil then
        self.lexicon_enabled = true -- default ON
        G_reader_settings:saveSetting("language_chinese_lexicon_enabled", self.lexicon_enabled)
    end

    -- Prepare lexicon if enabled
    if self.lexicon_enabled then
        self.words    = nil
        self.wordset  = nil
        self.lex_ready = false
        self:_try_load_lexicon()
    else
        self.words, self.wordset, self.lex_ready = nil, nil, false
        logger.info("Chinese plugin: lexicon disabled via menu setting")
    end

    LanguageSupport:registerPlugin(self)
end


-- Module-level cache (shared across plugin reloads in same KOReader run)
local cached_words = nil
local cached_wordset = nil
local cached_ready = false

function Chinese:_try_load_lexicon()
    if cached_ready and cached_words and cached_wordset then
        -- reuse cache
        self.words = cached_words
        self.wordset = cached_wordset
        self.lex_ready = true
        logger.info("Chinese: reused cached StarDict lexicon (" .. #self.words .. " headwords)")
        return
    end

    self.lex_ready = false
    self.words, self.wordset = nil, nil

    local dict_base = "/mnt/onboard/.adds/koreader/plugins/chinese.koplugin/cedict"
    local ifo = dict_base .. ".ifo"
    local idx = dict_base .. ".idx"

    local info, err = parse_ifo(ifo)
    if not info then
        logger.warn("Chinese: CEDICT .ifo not found/invalid: " .. tostring(err))
        return
    end
    local words, err2 = load_headwords_from_idx(idx, info.idxoffsetbits or 32)
    if not words then
        logger.warn("Chinese: CEDICT .idx not found/invalid: " .. tostring(err2))
        return
    end

    local wordset = build_set(words)
    self.words = words
    self.wordset = wordset
    self.lex_ready = true

    -- populate cache
    cached_words = words
    cached_wordset = wordset
    cached_ready = true

    logger.info(string.format("Chinese: StarDict lexicon loaded and cached (%d headwords)", #words))
end


-- Presence checks
function Chinese:lex_has_word(s)
    return self.lex_ready and self.wordset[s] == true or false
end

function Chinese:lex_has_prefix(p)
    if not self.lex_ready then return false end
    local i = lower_bound(self.words, p)
    if i <= #self.words then
        local w = self.words[i]
        return (#w >= #p) and (w:sub(1, #p) == p)
    end
    return false
end

function Chinese:supportsLanguage(language_code)
    return language_code == "zh"
        or language_code == "zho" or language_code == "chi"
        or language_code == "zh-CN" or language_code == "zh-SG"
        or language_code == "zh-TW" or language_code == "zh-HK"
        or language_code == "zh-Hans" or language_code == "zh-Hant"
end

-- No deinflection needed for Chinese.
function Chinese:onWordLookup(args)
    local text = args.text
    if not util.hasCJKChar(text) then
        return
    end
    return
end

-- Fast longest-match selection using StarDict headwords.
function Chinese:onWordSelection(args)
    local callbacks = args.callbacks
    local current_text = args.text

    -- Ignore non-CJK selections.
    if current_text ~= "" and not util.hasCJKChar(current_text) then
        return
    end

    -- If lexicon unavailable, fall back to KOReader's default behaviour.
    if not self.lex_ready then
        return
    end

    local get_next = callbacks.get_next_char_pos
    local get_text = callbacks.get_text_in_range

    local pos0 = args.pos0
    local pos1 = get_next(pos0)
    if not pos1 then return end

    local best_pos1 = nil
    local steps = 0

    while pos1 and steps < self.max_scan_length do
        pos1 = get_next(pos1)
        if not pos1 then break end

        local cand = get_text(pos0, pos1)

        -- stop expansion on punctuation or non-CJK run
        if not isPossibleChineseWord(cand) then
            break
        end

        -- prefix gate: if no words start with this, stop expanding
        if not self:lex_has_prefix(cand) then
            break
        end

        if self:lex_has_word(cand) then
            best_pos1 = pos1
        end

        steps = steps + 1
    end

    if best_pos1 then
        return { pos0, best_pos1 }
    end
    -- else let base code decide (nil)
end

function Chinese:genMenuItem()
    local sub_item_table = {
        {
            text_func = function()
                return T(N_("Text scan length: %1 character", "Text scan length: %1 characters", self.max_scan_length), self.max_scan_length)
            end,
            help_text = _("Number of characters to look ahead when trying to expand tap-and-hold word selection in documents."),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                local Screen = require("device").screen
                local items = SpinWidget:new{
                    title_text = _("Text scan length"),
                    info_text = T(_([[The maximum number of characters to look ahead when trying to expand tap-and-hold word selection in documents.
Larger values allow longer phrases to be selected automatically, but selections may become slower.

Default value: %1]]), DEFAULT_TEXT_SCAN_LENGTH),
                    width = math.floor(Screen:getWidth() * 0.75),
                    value = self.max_scan_length,
                    value_min = 0,
                    value_max = 50,
                    value_step = 1,
                    value_hold_step = 10,
                    ok_text = _("Set scan length"),
                    default_value = DEFAULT_TEXT_SCAN_LENGTH,
                    callback = function(spin)
                        self.max_scan_length = spin.value
                        G_reader_settings:saveSetting("language_chinese_text_scan_length", self.max_scan_length)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                }
                UIManager:show(items)
            end,
        },
        -- NEW: tickbox to enable/disable lexicon
		{
            text = _("Enable StarDict lexicon"),
			help_text = _("Toggle whether the StarDict lexicon is loaded for Chinese text lookups (loads when opening a book, disable if not needed)"),
            checked_func = function()
                return G_reader_settings:isTrue("language_chinese_lexicon_enabled")
            end,
            callback = function()
                self.lexicon_enabled = not self.lexicon_enabled
                G_reader_settings:saveSetting("language_chinese_lexicon_enabled", self.lexicon_enabled)
                if self.lexicon_enabled then
                    self:_try_load_lexicon()
                else
                    self.words, self.wordset, self.lex_ready = nil, nil, false
                    logger.info("Chinese plugin: lexicon disabled via menu")
                end
            end,
            separator = true,
        },
        {
            text_func = function()
                if self.lex_ready and self.words then
                    return _("Lexicon: loaded ") .. tostring(#self.words) .. _(" headwords")
                else
                    return _("Lexicon: not loaded")
                end
            end,
            keep_menu_open = true,
            callback = function() end,
        },
    }

    return {
        text = _("Chinese"),
        sub_item_table = sub_item_table,
    }
end


return Chinese
