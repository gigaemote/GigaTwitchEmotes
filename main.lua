-- Private addon namespace shared with bufftracker.lua.
local _, ns = ...
ns = ns or {}

-- Errors caught by SafeCall are recorded here instead of being raised, so a
-- restricted frame or a change in another addon never shows users a Lua
-- error. Use /giga errors to print them.
local caughtErrors = {}
local caughtErrorOrder = {}
local MAX_CAUGHT_ERRORS = 20

local function RecordError(err)
    local msg = tostring(err)
    if caughtErrors[msg] then
        caughtErrors[msg] = caughtErrors[msg] + 1
        return
    end

    if #caughtErrorOrder >= MAX_CAUGHT_ERRORS then
        return
    end

    caughtErrors[msg] = 1
    caughtErrorOrder[#caughtErrorOrder + 1] = msg
end

local function HandleCallResult(ok, ...)
    if not ok then
        RecordError((...))
        return nil
    end

    return ...
end

-- Call fn with pcall, record any error, and return fn's results (nil on error).
local function SafeCall(fn, ...)
    return HandleCallResult(pcall(fn, ...))
end

ns.SafeCall = SafeCall
ns.RecordError = RecordError

local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)

local function EmoteTag(pack, name)
    local path = pack and pack[name]
    if type(path) ~= "string" then
        return ""
    end

    return "|T" .. path .. "|t"
end

-------------------------------------------------------------------------------
-- Emote filters: hide NSFW and/or wide emotes. A hidden emote is removed from
-- TwitchEmotes' word -> emote lookup, so new chat messages show its name as
-- plain text. It is also left out of autocomplete and the emote browser.
-------------------------------------------------------------------------------
local WIDE_EMOTE_MAX_WIDTH = 40
local CHAT_EMOTE_HEIGHT = 28

local registeredEmotes = {} -- names passed to TwitchEmotes:AddEmote
local allSuggestions = nil -- full autocomplete list
local activeSuggestions = nil -- list given to SetupAutoComplete, edited in place
local ApplyEmoteFilters -- defined once the emote browser exists

-- Settings shown on the native settings page (Options > AddOns) and stored
-- in Giga_Settings.
local SETTINGS_CATEGORY_NAME = "Giga Twitch Emotes"
local SETTING_DEFINITIONS = {
    {
        key = "hideNSFW",
        name = "Hide NSFW emotes",
        default = false,
        tooltip = "Show NSFW emotes as plain text in new chat messages and leave them out of autocomplete and the emote browser.",
    },
    {
        key = "hideWide",
        name = "Hide wide emotes",
        default = false,
        tooltip = "Show emotes wider than " .. WIDE_EMOTE_MAX_WIDTH .. "px as plain text in new chat messages and leave them out of autocomplete and the emote browser.",
    },
    {
        key = "clickEmotes",
        name = "Click emotes in chat",
        default = true,
        tooltip = "Click an emote in a chat message to add it to the message you're typing.",
    },
    {
        key = "minimap",
        name = "Show minimap icon",
        default = true,
        tooltip = "Show the Giga Twitch Emotes button on the minimap.",
    },
}

-- Defined with the settings page further down.
local RegisterSettingsPage, SetGigaSetting, OpenGigaSettings, UpdateMinimapIcon

-- Width the emote takes up in chat. Matches how it is drawn: wide animated
-- emotes are scaled to the chat height, static emotes use their tag size
-- (texture tags are height:width).
local function GetChatEmoteWidth(path)
    local texture = path:match("^(.-%.tga)")
    local metadata = TwitchEmotes_animation_metadata
    local animdata = texture and type(metadata) == "table" and metadata[texture]
    if type(animdata) == "table"
        and type(animdata.frameWidth) == "number"
        and type(animdata.frameHeight) == "number"
        and animdata.frameHeight > 0
    then
        if animdata.frameWidth > animdata.frameHeight then
            return math.floor(
                CHAT_EMOTE_HEIGHT * animdata.frameWidth / animdata.frameHeight + 0.5
            )
        end

        return CHAT_EMOTE_HEIGHT
    end

    local _, width = path:match("%.tga:(%d+):(%d+)")
    return tonumber(width) or CHAT_EMOTE_HEIGHT
end

local nsfwEmoteSet = nil
local function IsNSFWEmote(name)
    if not nsfwEmoteSet then
        nsfwEmoteSet = {}
        if type(judhead_nsfw_emotes) == "table" then
            for _, nsfwName in ipairs(judhead_nsfw_emotes) do
                nsfwEmoteSet[nsfwName] = true
            end
        end
    end

    return nsfwEmoteSet[name] == true
end

local function IsEmoteHidden(name)
    if type(Giga_Settings) ~= "table" then
        return false
    end

    if Giga_Settings.hideNSFW and IsNSFWEmote(name) then
        return true
    end

    local path = type(judhead_emotes) == "table" and judhead_emotes[name]
    if Giga_Settings.hideWide
        and type(path) == "string"
        and GetChatEmoteWidth(path) > WIDE_EMOTE_MAX_WIDTH
    then
        return true
    end

    return false
end

-- Emotes the player switched off in the emote browser. They stay listed
-- there (so they can be switched back on) but show as text in chat.
local function IsEmoteDisabled(name)
    return type(Giga_Settings) == "table"
        and type(Giga_Settings.disabledEmotes) == "table"
        and Giga_Settings.disabledEmotes[name] == true
end

local function GetVisibleEmotes()
    local visible = {}
    if type(judhead_emotes) ~= "table" then
        return visible
    end

    for name, path in pairs(judhead_emotes) do
        if type(path) == "string" and not IsEmoteHidden(name) then
            visible[name] = path
        end
    end

    return visible
end

local function ApplyChatAndSuggestionFilters()
    -- TwitchEmotes only swaps a word for an emote if it is in this table.
    if type(TwitchEmotes_emoticons) == "table" then
        for name in pairs(registeredEmotes) do
            if IsEmoteHidden(name) or IsEmoteDisabled(name) then
                TwitchEmotes_emoticons[name] = nil
            else
                TwitchEmotes_emoticons[name] = name
            end
        end
    end

    if allSuggestions and activeSuggestions then
        for i = #activeSuggestions, 1, -1 do
            activeSuggestions[i] = nil
        end

        for _, name in ipairs(allSuggestions) do
            if not (registeredEmotes[name] and (IsEmoteHidden(name) or IsEmoteDisabled(name))) then
                activeSuggestions[#activeSuggestions + 1] = name
            end
        end
    end
end

-- Main frame
local MyAddonFrame = CreateFrame("Frame", "MyAddonMainFrame", UIParent, "BasicFrameTemplateWithInset")
MyAddonFrame:SetSize(680, 550) -- Width, Height
MyAddonFrame:SetPoint("CENTER") -- Position in the center of the screen
MyAddonFrame.title = MyAddonFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
MyAddonFrame.title:SetPoint("CENTER", MyAddonFrame.TitleBg, "CENTER", 0, 0)
MyAddonFrame.title:SetText("GIGA Twitch Emotes")
MyAddonFrame:SetMovable(true)
MyAddonFrame:EnableMouse(true)
MyAddonFrame:RegisterForDrag("LeftButton")
MyAddonFrame:SetScript("OnDragStart", MyAddonFrame.StartMoving)
MyAddonFrame:SetScript("OnDragStop", MyAddonFrame.StopMovingOrSizing)
MyAddonFrame:Hide() -- Initially hidden

-- Close with Escape. Frames listed in UISpecialFrames are hidden by
-- Blizzard's close-windows handling when Escape is pressed.
if type(UISpecialFrames) == "table" then
    tinsert(UISpecialFrames, MyAddonFrame:GetName())
end
local aboutText = (
"六四天安門事件 AshenvaleAutonomousZone Emote Pack \n天安門大屠殺 Originally Just " .. EmoteTag(judhead_emotes, "PEPW") .. "   " .. "\n"..
"反右派鬥爭 Guildies kept contributing 大躍進政策 Grow In Numbers \n文化大革命 Many Emotes 人權 Erotic Role Play \n"..
"民運 Bitcoin Miner \n自由 Horny 獨立 Innuendo 多黨制 Labor of Love\n\n\n"..
EmoteTag(TwitchEmotes_defaultpack, "moon2CUTE")
)
local tabs = {}
local tabNames = {"Emotes", "About", "Buffs", "Kills"}
local panelType = "PanelTabButtonTemplate"
for i, name in ipairs(tabNames) do
    local tab = CreateFrame("Button", "$parentTab"..i, MyAddonFrame, panelType)
    tab:SetID(i)
    tab:SetText(name)
    tab:SetScript("OnClick", function(self)
        PanelTemplates_SetTab(MyAddonFrame, self:GetID())
        ShowTabContent(self:GetID())
    end)

    tabs[i] = tab
end

-- Position the tabs
tabs[1]:SetPoint("TOPLEFT", MyAddonFrame, "BOTTOMLEFT", 10, 7)
for i = 2, #tabs do
    tabs[i]:SetPoint("LEFT", tabs[i-1], "RIGHT", -15, 0)
end

PanelTemplates_SetNumTabs(MyAddonFrame, #tabs)
PanelTemplates_SetTab(MyAddonFrame, 1)
local tabContents = {}
for i = 1, #tabs do
    local panel = CreateFrame("Frame", nil, MyAddonFrame)
    panel:SetAllPoints(MyAddonFrame)
    panel:Hide()
    tabContents[i] = panel
end

-- Set About tab text
local label = tabContents[2]:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
label:SetPoint("CENTER")
label:SetText(aboutText)

function ShowTabContent(tabID)
    for i, panel in ipairs(tabContents) do
        if i == tabID then
            panel:Show()
        else
            panel:Hide()
        end

    end

end

-- Show the first tab content by default
tabContents[1]:Show()

-- The Buffs tab is filled in by bufftracker.lua.
local BUFFS_TAB = 3
ns.buffPanel = tabContents[BUFFS_TAB]

-- The Kills tab is filled in by killtracker.lua.
local KILLS_TAB = 4
ns.killPanel = tabContents[KILLS_TAB]

local function OpenTab(tabID)
    MyAddonFrame:Show()
    PanelTemplates_SetTab(MyAddonFrame, tabID)
    ShowTabContent(tabID)
end

local function OpenBuffScores()
    OpenTab(BUFFS_TAB)
end

local function OpenKillScores()
    OpenTab(KILLS_TAB)
end
-------------------------------------------------------------------------------

-- Slash command
-------------------------------------------------------------------------------
local slashFrame = CreateFrame("Frame")
slashFrame:RegisterEvent("ADDON_LOADED")
slashFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "TwitchEmotes_Giga" then
        self:UnregisterEvent("ADDON_LOADED")
        if type(Giga_Settings) ~= "table" then
            Giga_Settings = {}
        end

        for _, def in ipairs(SETTING_DEFINITIONS) do
            if type(Giga_Settings[def.key]) ~= type(def.default) then
                Giga_Settings[def.key] = def.default
            end
        end

        if type(Giga_Settings.disabledEmotes) ~= "table" then
            Giga_Settings.disabledEmotes = {}
        end

        SafeCall(judhead_startup)
        SafeCall(RegisterSettingsPage)
    end

end)

SLASH_GIGA1 = "/giga" -- The slash command users will type in chat

-- Function to handle slash command input
SlashCmdList["GIGA"] = function(msg)

    -- Check if a value was provided
    if type(Giga_Settings) ~= "table" then
        Giga_Settings = { minimap = true }
    end

    if msg and msg ~= "" then
        if msg == "errors" then
            if #caughtErrorOrder == 0 then
                print("|cFFFF69B4[GIGA] No errors caught.|r")
            end

            for _, err in ipairs(caughtErrorOrder) do
                print("|cFFFF69B4[GIGA]|r " .. caughtErrors[err] .. "x " .. err)
            end
        elseif msg == "settings" then
            SafeCall(OpenGigaSettings)
        elseif msg == "buffs" then
            SafeCall(OpenBuffScores)
        elseif msg == "kills" then
            SafeCall(OpenKillScores)
        elseif msg == "nsfw" or msg == "wide" then
            local key = (msg == "nsfw") and "hideNSFW" or "hideWide"
            SafeCall(SetGigaSetting, key, not Giga_Settings[key])

            local label = (msg == "nsfw") and "NSFW" or "Wide"
            local state = Giga_Settings[key] and "hidden" or "shown"
            print("|cFFFF69B4[GIGA] " .. label .. " emotes are now " .. state .. " in new messages.|r")
        elseif msg == "minimap" then
            SafeCall(SetGigaSetting, "minimap", not Giga_Settings.minimap)
            local state = Giga_Settings.minimap and "enabled" or "disabled"
            print("|cFFFF69B4[GIGA] Minimap icon is now " .. state .. ".|r")
        end

    else
        print("Usage: /giga settings to open settings, /giga buffs for buff high scores, /giga kills for kill high scores, /giga minimap to toggle minimap icon, /giga nsfw to toggle NSFW emotes, /giga wide to toggle wide emotes, /giga errors to list caught errors")
    end

end

-------------------------------------------------------------------------------

-- Search box frame to attach search box to
-------------------------------------------------------------------------------
local searchBoxFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
searchBoxFrame:SetSize(220, 40)
searchBoxFrame:SetPoint("TOP", tabContents[1], "TOP", 0, -30) -- Position on top of the frame
searchBoxFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    tile = true,
    tileSize = 32,
    edgeSize = 16,
    insets = { left = 5, right = 5, top = 5, bottom = 5 },
})
searchBoxFrame:SetFrameStrata("DIALOG") -- Ensures it's on top of the frame
searchBoxFrame:SetClampedToScreen(true) -- Prevents it from moving offscreen
searchBoxFrame:Hide() -- Initially hidden

 -- Search box
local searchBox = CreateFrame("EditBox", nil, searchBoxFrame, "InputBoxTemplate")
searchBox:SetSize(200, 20)
searchBox:SetPoint("CENTER", 0, 0)
searchBox:SetAutoFocus(false)
searchBox:SetFontObject("ChatFontNormal")
searchBox:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
end)

searchBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
end)

local contentFrame = CreateFrame("Frame", nil, tabContents[1])
contentFrame:SetSize(280, 140)
contentFrame:SetPoint("TOP", 0, -80)
local currentPage = 1
local itemsPerPage = 24
local totalItems = -1
local totalPages = -1
local frameInit = 0
local content = {} -- slot font strings
local slots = {} -- slot frames: hover for the full name, checkbox to enable
local data = {}
local dataNames = {} -- emote name for each entry in data

-- Setup prev button
local prevButton = CreateFrame("Button", nil, tabContents[1], "GameMenuButtonTemplate")
prevButton:SetPoint("BOTTOMLEFT", tabContents[1], "BOTTOMLEFT", 10, 10)
prevButton:SetSize(80, 20)
prevButton:SetText("Previous")
prevButton:SetScript("OnClick", function()
    if currentPage > 1 then
        currentPage = currentPage - 1
        UpdatePageContent()
    end

end)

-- Setup next button
local nextButton = CreateFrame("Button", nil, tabContents[1], "GameMenuButtonTemplate")
nextButton:SetPoint("BOTTOMRIGHT", tabContents[1], "BOTTOMRIGHT", -10, 10)
nextButton:SetSize(80, 20)
nextButton:SetText("Next")
nextButton:SetScript("OnClick", function()
    if currentPage < totalPages then
        currentPage = currentPage + 1
        UpdatePageContent()
    end

end)

-- Pagination text
local pageNumber = tabContents[1]:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
pageNumber:SetPoint("BOTTOM", tabContents[1], "BOTTOM", 0, 10)

function judhead_startup()
    local suggestions = {};
    local i = 1;

    -- Setup minimap icon
    SafeCall(InitMinimapIcon)
    if type(judhead_emotes) ~= "table" then
        return
    end

    local canAddEmotes = TwitchEmotes and TwitchEmotes.AddEmote
    for k, v in pairs(judhead_emotes) do
        if type(v) == "string" then
            local emotePath = v
            if isWoWForever then
                emotePath = emotePath:gsub(":28:28$", ":20:20")
            end

            if canAddEmotes then
                SafeCall(TwitchEmotes.AddEmote, TwitchEmotes, k, k, emotePath)
                registeredEmotes[k] = true
            end

            suggestions[i] = k;
            i = i + 1;
        end
    end

    SafeCall(judhead_initsuggestions, suggestions)
    SafeCall(ApplyEmoteFilters)
end

function GigaTwitchEmotesRenderFrame(emotes)

    -- Sort emotes
    totalItems = 0
    data = {}
    dataNames = {}
    for _, _ in pairs(emotes) do
        totalItems = totalItems + 1
    end

    totalPages = math.ceil(totalItems / itemsPerPage)
    if currentPage > totalPages then
        currentPage = 1
    end

    local keys = {}
    for key in pairs(emotes) do
        table.insert(keys, key)
    end

    table.sort(keys)

    -- Format table of emote strings
    for _, key in ipairs(keys) do
        local s = EmoteTag(emotes, key) .. "   " .. tostring(key)
        table.insert(data, s);
        table.insert(dataNames, key)
    end

    -- Two columns of a checkbox and a SLOT_WIDTH slot, with even margins.
    local SLOT_WIDTH = 250
    local rowoffset = -125
    local coloffset = 1

    -- Two rows of emotes
    if frameInit == 0 then
        frameInit = 1
        for i = 1, itemsPerPage do
            -- Hovering a slot shows the full name, for names cut short.
            local slot = CreateFrame("Frame", nil, contentFrame)
            slot:SetSize(SLOT_WIDTH, 32)
            slot:SetPoint("TOPLEFT", rowoffset, -36 * (coloffset - 1))
            slot:EnableMouse(true)
            slot:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(tostring(self.emoteName))
                GameTooltip:Show()
            end)
            slot:SetScript("OnLeave", GameTooltip_Hide)

            local check = CreateFrame("CheckButton", nil, slot, "UICheckButtonTemplate")
            check:SetSize(22, 22)
            check:SetPoint("RIGHT", slot, "LEFT", -2, 0)
            check:SetScript("OnClick", function(self)
                local name = slot.emoteName
                if not name then
                    return
                end

                Giga_Settings.disabledEmotes[name] = (not self:GetChecked()) or nil
                content[i]:SetAlpha(self:GetChecked() and 1 or 0.5)
                SafeCall(ApplyChatAndSuggestionFilters)
            end)
            check:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Show as an emote in chat")
                GameTooltip:AddLine("Untick to show this emote as plain text in new chat messages.", 1, 1, 1, true)
                GameTooltip:Show()
            end)
            check:SetScript("OnLeave", GameTooltip_Hide)
            slot.check = check

            content[i] = slot:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            content[i]:SetPoint("LEFT")
            -- Long names end in "..." instead of running into the next column.
            content[i]:SetWidth(SLOT_WIDTH)
            content[i]:SetJustifyH("LEFT")
            content[i]:SetWordWrap(false)
            slots[i] = slot
            coloffset = coloffset + 1
            if coloffset > itemsPerPage / 2 then
                coloffset = 1
                rowoffset = 179
            end

        end

    end

    UpdatePageContent()
end

function UpdatePageContent()
    local startIndex = (currentPage - 1) * itemsPerPage + 1
    local endIndex = math.min(startIndex + itemsPerPage - 1, totalItems)
    for i = 1, itemsPerPage do
        local dataIndex = startIndex + i - 1
        if content[i] then
            if dataIndex <= endIndex then
                local name = dataNames[dataIndex]
                content[i]:SetText(data[dataIndex])
                content[i]:SetAlpha(IsEmoteDisabled(name) and 0.5 or 1)
                TwitchEmotesAnimator_UpdateEmoteInFontString(content[i], 0, 0)
                slots[i].emoteName = name
                slots[i].check:SetChecked(not IsEmoteDisabled(name))
                slots[i]:Show()
            else
                content[i]:SetText("")
                slots[i].emoteName = nil
                slots[i]:Hide()
            end
        end

    end

    pageNumber:SetText("Page " .. currentPage .. " / " .. totalPages)
end

-- Function to filter and display data

local function SearchData(query)
    query = string.lower(query) -- Case-insensitive search
    local matches = {}
    for k, v in pairs(GetVisibleEmotes()) do
        -- Plain find: characters like % or [ in the query are not patterns.
        if string.find(string.lower(k), query, 1, true) then
            matches[k] = v
        end

    end

    -- Update results
    GigaTwitchEmotesRenderFrame(matches)
end

function GIGATwitchEmotes_MinimapButton_OnClick(btn)
    MyAddonFrame:Show();
    if IsShiftKeyDown() then
    end

end

-- Main frame on show
tabContents[1]:SetScript("OnShow", function()
    searchBoxFrame:Show()
end)

-- Main frame on hide
tabContents[1]:SetScript("OnHide", function()
    searchBoxFrame:Hide()
end)

-------------------------------------------------------------------------------
-- Clicking an emote in chat adds it to the chat box: at the cursor if a
-- message is being typed, otherwise in a newly opened one.
-------------------------------------------------------------------------------
local function GetActiveChatBox()
    if ChatFrameUtil and ChatFrameUtil.GetActiveWindow then
        return ChatFrameUtil.GetActiveWindow()
    end

    return ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
end

local function InsertIntoChat(name)
    local editBox = GetActiveChatBox()
    if editBox and editBox:IsShown() then
        -- TwitchEmotes only swaps whole words, so keep the name apart from
        -- whatever is right before the cursor.
        local text = editBox:GetText()
        local cursor = editBox:GetCursorPosition()
        local before = ""
        if type(text) == "string" and type(cursor) == "number"
            and not (issecretvalue and (issecretvalue(text) or issecretvalue(cursor)))
        then
            before = text:sub(cursor, cursor)
        end

        local prefix = (before ~= "" and not before:find("%s")) and " " or ""
        editBox:Insert(prefix .. name .. " ")
        editBox:SetFocus()
        return
    end

    if ChatFrameUtil and ChatFrameUtil.OpenChat then
        ChatFrameUtil.OpenChat(name .. " ")
    elseif ChatFrame_OpenChat then
        ChatFrame_OpenChat(name .. " ")
    end
end

-- Emotes in chat are "tel:<name>" links (made by TwitchEmotes, which ignores
-- clicks on them). Called from the chat frames' OnHyperlinkClick hooks.
local function OnChatEmoteClick(link, button)
    if type(Giga_Settings) ~= "table" or Giga_Settings.clickEmotes == false
        or type(link) ~= "string" or (issecretvalue and issecretvalue(link))
        or (button and button ~= "LeftButton")
        or IsModifierKeyDown() -- modified clicks are left to the game
    then
        return
    end

    local name = link:match("^tel:(.+)")
    if not name then
        return
    end

    InsertIntoChat(name)
end

-- Redraw the browser for the current search text and filters.
local function RefreshBrowser()
    local query = searchBox:GetText()
    if query and query ~= "" then
        SearchData(query)
    else
        GigaTwitchEmotesRenderFrame(GetVisibleEmotes())
    end
end

ApplyEmoteFilters = function()
    SafeCall(ApplyChatAndSuggestionFilters)
    SafeCall(RefreshBrowser)
end

-- Update results dynamically as user types
searchBox:SetScript("OnTextChanged", function()
    SafeCall(RefreshBrowser)
end)

-------------------------------------------------------------------------------
-- Native settings page: Options > AddOns > Giga Twitch Emotes.
-------------------------------------------------------------------------------
local settingsCategory = nil -- Settings API category
local legacySettingsPanel = nil -- Interface Options panel on older clients
local nativeSettings = {} -- setting key -> Settings API setting object

local function ApplySetting(key)
    if key == "minimap" then
        SafeCall(UpdateMinimapIcon)
    else
        SafeCall(ApplyEmoteFilters)
    end
end

-- Change a setting from code (slash commands) and keep the page in sync.
SetGigaSetting = function(key, value)
    local setting = nativeSettings[key]
    if setting and setting.SetValue then
        SafeCall(setting.SetValue, setting, value)
    end

    Giga_Settings[key] = value
    ApplySetting(key)
end

local function RegisterBlizzardSettings()
    if not (Settings
        and Settings.RegisterVerticalLayoutCategory
        and Settings.RegisterAddOnSetting
        and Settings.RegisterAddOnCategory)
    then
        return false
    end

    local createCheckbox = Settings.CreateCheckbox or Settings.CreateCheckBox
    if not createCheckbox then
        return false
    end

    local category = Settings.RegisterVerticalLayoutCategory(SETTINGS_CATEGORY_NAME)
    local booleanType = (Settings.VarType and Settings.VarType.Boolean) or "boolean"

    -- The War Within changed RegisterAddOnSetting to store values straight
    -- in a table; RegisterProxySetting was added in the same patch.
    local storesInTable = Settings.RegisterProxySetting ~= nil

    for _, def in ipairs(SETTING_DEFINITIONS) do
        local key = def.key
        local variable = "GigaTwitchEmotes_" .. key
        local setting
        if storesInTable then
            setting = Settings.RegisterAddOnSetting(
                category, variable, key, Giga_Settings, booleanType, def.name, def.default
            )
        else
            setting = Settings.RegisterAddOnSetting(
                category, def.name, variable, booleanType, def.default
            )
            setting:SetValue(Giga_Settings[key] == true)
        end

        local function OnValueChanged()
            Giga_Settings[key] = setting:GetValue() == true
            ApplySetting(key)
        end

        if setting.SetValueChangedCallback then
            setting:SetValueChangedCallback(function()
                SafeCall(OnValueChanged)
            end)
        elseif Settings.SetOnValueChangedCallback then
            Settings.SetOnValueChangedCallback(variable, function()
                SafeCall(OnValueChanged)
            end)
        end

        createCheckbox(category, setting, def.tooltip)
        nativeSettings[key] = setting
    end

    Settings.RegisterAddOnCategory(category)
    settingsCategory = category
    return true
end

-- Clients without the Settings API use the older Interface Options page.
local function RegisterLegacySettings()
    if not InterfaceOptions_AddCategory then
        return
    end

    local panel = CreateFrame("Frame")
    panel.name = SETTINGS_CATEGORY_NAME

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(SETTINGS_CATEGORY_NAME)

    for i, def in ipairs(SETTING_DEFINITIONS) do
        local key = def.key
        local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        check:SetPoint("TOPLEFT", 16, -50 - (i - 1) * 30)
        check.tooltipText = def.name
        check.tooltipRequirement = def.tooltip

        local text = check:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        text:SetPoint("LEFT", check, "RIGHT", 4, 0)
        text:SetText(def.name)

        check:SetScript("OnShow", function(self)
            self:SetChecked(Giga_Settings[key] == true)
        end)
        check:SetScript("OnClick", function(self)
            SafeCall(SetGigaSetting, key, self:GetChecked() and true or false)
        end)
    end

    InterfaceOptions_AddCategory(panel)
    legacySettingsPanel = panel
end

RegisterSettingsPage = function()
    local ok, registered = pcall(RegisterBlizzardSettings)
    if not ok then
        RecordError(registered)
    end

    if not (ok and registered) then
        SafeCall(RegisterLegacySettings)
    end
end

OpenGigaSettings = function()
    -- Opening Blizzard's settings from addon code in combat can taint it.
    if InCombatLockdown and InCombatLockdown() then
        print("|cFFFF69B4[GIGA] Settings can't be opened in combat.|r")
        return
    end

    MyAddonFrame:Hide()
    if settingsCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    elseif legacySettingsPanel and InterfaceOptionsFrame_OpenToCategory then
        -- Called twice: the first call can land on the wrong page.
        InterfaceOptionsFrame_OpenToCategory(legacySettingsPanel)
        InterfaceOptionsFrame_OpenToCategory(legacySettingsPanel)
    else
        print("|cFFFF69B4[GIGA] Use /giga nsfw, /giga wide or /giga minimap to change settings.|r")
    end
end

-- Settings button on the emote browser.
local settingsButton = CreateFrame("Button", nil, tabContents[1], "GameMenuButtonTemplate")
settingsButton:SetPoint("TOPRIGHT", tabContents[1], "TOPRIGHT", -12, -32)
settingsButton:SetSize(80, 20)
settingsButton:SetText("Settings")
settingsButton:SetScript("OnClick", function()
    SafeCall(OpenGigaSettings)
end)

-- update animated emotes
local interval = 0.033 -- Time in seconds
local elapsed = 0
MyAddonFrame:SetScript("OnUpdate", function(self, deltaTime)
    if self:IsShown() then -- Only run while the frame is visible
        elapsed = elapsed + deltaTime
        if elapsed >= interval then
            SafeCall(UpdatePageContent)
            elapsed = 0 -- Reset timer
        end

    end

end)

function InitMinimapIcon()
    if not LDB or not LDBIcon then
        return
    end

    -- NewDataObject returns nil if the name is already registered.
    GigaTwitchIcon = LDB:GetDataObjectByName("GIGATwitchEmotes")
        or LDB:NewDataObject("GIGATwitchEmotes", {
            type = "launcher",
            text = "GIGATwitchEmotes",
            icon = "Interface\\AddOns\\TwitchEmotes_Giga\\emotes\\PEPW.tga",
            OnClick = GIGATwitchEmotes_MinimapButton_OnClick
        })
    if not GigaTwitchIcon then
        return
    end

    UpdateMinimapIcon()

end

-- Show or hide the minimap icon to match the setting, without a reload.
UpdateMinimapIcon = function()
    if not LDBIcon or not GigaTwitchIcon then
        return
    end

    if Giga_Settings.minimap then
        local registered = LDBIcon.IsRegistered and LDBIcon:IsRegistered("GIGATwitchEmotes")
        if not registered then
            LDBIcon:Register("GIGATwitchEmotes", GigaTwitchIcon, Giga_Settings)
        end

        LDBIcon:Show("GIGATwitchEmotes")
    else
        LDBIcon:Hide("GIGATwitchEmotes")
    end
end

function judhead_concat(t1, t2)
    for i=1,#t2 do
        t1[#t1+1] = t2[i]
    end

    return t1
end

-- Ellesmere recalls sent lines on plain Up/Down from its own OnKeyDown hook,
-- which would overwrite the text while our suggestion dropdown is using the
-- arrow keys. Its handler does nothing when the edit box's recall history is
-- empty, so while the dropdown is open we give Ellesmere an empty history and
-- put the real one back when it closes. This only touches Ellesmere's own
-- state (EllesmereUI._chatCFD) and never Blizzard's edit box, so unlike
-- replacing editBox.SetText it cannot taint chat.
local ELLESMERE_HISTORY_LIMIT = 50 -- matches EUI_Chat_EditBox.lua
local hiddenEllesmereHistory = nil -- { editBox, state, history, placeholder }

local function RestoreEllesmereHistory()
    local hidden = hiddenEllesmereHistory
    if not hidden then
        return
    end

    hiddenEllesmereHistory = nil

    -- If Ellesmere replaced the table itself, leave its new one alone.
    if hidden.state.history ~= hidden.placeholder then
        return
    end

    -- Keep any line that was sent while the dropdown was open.
    local history = hidden.history
    for _, line in ipairs(hidden.placeholder) do
        if history[#history] ~= line then
            history[#history + 1] = line
            if #history > ELLESMERE_HISTORY_LIMIT then
                table.remove(history, 1)
            end
        end
    end

    hidden.state.history = history
end

local function HideEllesmereHistory(editBox)
    local getState = EllesmereUI and EllesmereUI._chatCFD
    if type(getState) ~= "function" then
        return
    end

    local state = getState(editBox)
    if type(state) ~= "table" or type(state.history) ~= "table" then
        return
    end

    local placeholder = {}
    hiddenEllesmereHistory = {
        editBox = editBox,
        state = state,
        history = state.history,
        placeholder = placeholder,
    }
    state.history = placeholder
end

local function UpdateEllesmereHistory()
    local dropdown = EditBoxAutoCompleteBox
    local owner = dropdown and dropdown:IsShown() and dropdown.parent or nil
    local hidden = hiddenEllesmereHistory

    if hidden and hidden.editBox == owner then
        return
    end

    RestoreEllesmereHistory()
    if owner then
        HideEllesmereHistory(owner)
    end
end

-- Polled rather than hooking the dropdown so it also follows the dropdown
-- moving between edit boxes. The dropdown opens on typing, so it is always
-- seen at least a frame before an arrow key can reach Ellesmere.
local ellesmereWatcher = nil
local function SetupEllesmereArrowCompatibility()
    if ellesmereWatcher then
        return
    end

    ellesmereWatcher = CreateFrame("Frame")
    ellesmereWatcher:SetScript("OnUpdate", function()
        SafeCall(UpdateEllesmereHistory)
    end)
end

function judhead_initsuggestions(suggestions)
    if AllTwitchEmoteNames ~= nil and Emoticons_Settings ~= nil and Emoticons_RenderSuggestionFN ~= nil and Emoticons_Settings["ENABLE_AUTOCOMPLETE"] and SetupAutoComplete ~= nil then
        judhead_concat(suggestions, AllTwitchEmoteNames);
        table.sort(suggestions);

        -- Keep the full list so filters can be toggled back off.
        allSuggestions = judhead_concat({}, suggestions)
        activeSuggestions = suggestions
        for i=1, (NUM_CHAT_WINDOWS or 0) do
            local frame = _G["ChatFrame"..i]
            local maxButtonCount = 20;
            if frame and frame.editBox then
                SafeCall(SetupAutoComplete, frame.editBox, suggestions, maxButtonCount, {
                    perWord = true,
                    activationChar = ':',
                    closingChar = ':',
                    minChars = 2,
                    fuzzyMatch = true,
                    onSuggestionApplied = function(suggestion)
                        if UpdateEmoteStats ~= nil then
                            UpdateEmoteStats(suggestion, true, false, false);
                        end

                    end,
                    renderSuggestionFN = Emoticons_RenderSuggestionFN,
                    suggestionBiasFN = function(suggestion, text)
                        --Bias the sorting function towards the most autocompleted emotes
                        local stats = TwitchEmoteStatistics and TwitchEmoteStatistics[suggestion]
                        if type(stats) == "table" and tonumber(stats[1]) then
                            return tonumber(stats[1]) * 5
                        end

                        return 0;
                    end,
                    interceptOnEnterPressed = true,
                    addSpace = true,
                    useTabToConfirm = Emoticons_Settings["AUTOCOMPLETE_CONFIRM_WITH_TAB"],
                    useArrowButtons = true,
                });
            end
        end

        if C_AddOns and C_AddOns.IsAddOnLoaded
            and C_AddOns.IsAddOnLoaded("EllesmereUIChat")
        then
            SafeCall(SetupEllesmereArrowCompatibility)
        end

    end

end

function judhead_dump()
    local str = ""
    local i = 0
    for k, v in pairs(judhead_emotes) do
        str = str .. "|Htel:name = " .. k .. "\npath = " .. v .. "|h|T" .. v .. "|t|h "
        i = i + 1
        if i == 8 then
            print(str)
            str = ""
            i = 0
        end

    end

    if i > 0 then
        print(str)
    end

end

local function escpattern(x)
    return (x:gsub('%%', '%%%%')
             :gsub('^%^', '%%^')
             :gsub('%$$', '%%$')
             :gsub('%(', '%%(')
             :gsub('%)', '%%)')
             :gsub('%.', '%%.')
             :gsub('%[', '%%[')
             :gsub('%]', '%%]')
             :gsub('%*', '%%*')
             :gsub('%+', '%%+')
             :gsub('%-', '%%-')
             :gsub('%?', '%%?'))
end

local function UpdateEmoteInFontString(fontstring, widthOverride, heightOverride)
    if not fontstring or not fontstring.GetText then
        return
    end

    if fontstring.IsForbidden and fontstring:IsForbidden() then
        return
    end

    local metadata = TwitchEmotes_animation_metadata
    if type(metadata) ~= "table"
        or not TwitchEmotes_GetCurrentFrameNum
        or not TwitchEmotes_BuildEmoteFrameString
        or not TwitchEmotes_BuildEmoteFrameStringWithDimensions
    then
        return
    end

    local txt = fontstring:GetText()
    if txt == nil then
        return
    end

    -- Avoid accessing protected chat strings.
    if canaccessvalue and not canaccessvalue(txt) then
        return
    end

    if issecretvalue and issecretvalue(txt) then
        return
    end

    if type(txt) ~= "string" then
        return
    end

    for emoteTextureString in txt:gmatch("(|TInterface\\AddOns\\TwitchEmotes.-|t)") do
        local imagepath = emoteTextureString:match("|T([^:]+%.tga)")
        local animdata = imagepath and metadata[imagepath]
        if type(animdata) == "table"
            and type(animdata.frameWidth) == "number"
            and type(animdata.frameHeight) == "number"
            and animdata.frameHeight > 0
        then
            local framenum = TwitchEmotes_GetCurrentFrameNum(animdata)
            local frameString
            if animdata.frameWidth > animdata.frameHeight then

                -- Preserve wide animated emote aspect ratios.
                local displayHeight =
                    (heightOverride and heightOverride > 0)
                    and heightOverride
                    or 28
                local displayWidth = math.floor(
                    displayHeight * animdata.frameWidth / animdata.frameHeight + 0.5
                )
                frameString = TwitchEmotes_BuildEmoteFrameStringWithDimensions(
                    imagepath,
                    animdata,
                    framenum,
                    displayHeight,
                    displayWidth
                )
            elseif widthOverride ~= nil and heightOverride ~= nil then
                frameString = TwitchEmotes_BuildEmoteFrameStringWithDimensions(
                    imagepath,
                    animdata,
                    framenum,
                    heightOverride,
                    widthOverride
                )
            else
                frameString = TwitchEmotes_BuildEmoteFrameString(
                    imagepath,
                    animdata,
                    framenum
                )
            end

            if type(frameString) == "string" then
                -- Function replacement so a % in frameString is not
                -- treated as a capture reference.
                local nTxt = txt:gsub(
                    escpattern(emoteTextureString),
                    function() return frameString end
                )
                if type(fontstring.messageInfo) == "table" then
                    fontstring.messageInfo.message = nTxt
                end

                fontstring:SetText(nTxt)
                txt = nTxt
            end
        end

    end

end

-- Global because the base TwitchEmotes addon calls it for Blizzard chat.
-- Errors are caught so a single bad FontString never raises a Lua error.
function TwitchEmotesAnimator_UpdateEmoteInFontString(fontstring, widthOverride, heightOverride)
    SafeCall(UpdateEmoteInFontString, fontstring, widthOverride, heightOverride)
end

-- Custom chat addon animation and Chattynator tooltip compatibility.

do
    local UPDATE_INTERVAL = 0.033
    local DISCOVERY_INTERVAL = 5
    local TOOLTIP_INTERVAL = 0.05
    local HOVER_PADDING = 4
    local customFrames = {}
    local updateElapsed = 0
    local discoveryElapsed = DISCOVERY_INTERVAL

    -- Chattynator tooltip state.
    local hoveredName = nil
    local hoverX, hoverY = nil, nil
    local hoverWidth, hoverHeight = 28, 28
    local tooltipElapsed = 0

    local function IsBlizzardChatFrame(frame)
        if not CHAT_FRAMES then
            return false
        end

        for _, name in ipairs(CHAT_FRAMES) do
            if frame == _G[name] then
                return true
            end

        end

        return false
    end

    -- Some frames (e.g. aura buttons) are not reported as forbidden but
    -- still error when tainted code calls methods on them, so callers
    -- run this through pcall.
    local function IsCustomChatFrame(frame)
        return not (frame.IsForbidden and frame:IsForbidden())
            and not frame:GetName()
            and not IsBlizzardChatFrame(frame)
    end

    local function DiscoverCustomChatFrames()
        local found = {}
        local frame = EnumerateFrames()

        while frame do
            -- Check the raw field first so we never call methods on
            -- unrelated frames.
            if type(frame) == "table"
                and type(rawget(frame, "visibleLines")) == "table"
            then
                local ok, isChat = pcall(IsCustomChatFrame, frame)
                if ok and isChat then
                    found[#found + 1] = frame
                end
            end

            frame = EnumerateFrames(frame)
        end

        customFrames = found
    end

    local function CanReadFrame(frame)
        return not (frame.IsForbidden and frame:IsForbidden())
    end

    -- Find the displayed dimensions of an emote in Chattynator.

    -- WoW texture tags specify height before width.

    local function GetEmoteDisplaySize(emoteName)
        for _, frame in ipairs(customFrames) do
            if CanReadFrame(frame)
                and frame.pool
                and frame.scrollIndex
                and type(frame.visibleLines) == "table"
            then
                for _, line in ipairs(frame.visibleLines) do
                    local txt = line:GetText()
                    if type(txt) == "string"
                        and (not canaccessvalue or canaccessvalue(txt))
                        and (not issecretvalue or not issecretvalue(txt))
                        and txt:find(emoteName, 1, true)
                    then
                        for tag in txt:gmatch("|T.-|t") do
                            local height, width =
                                tag:match("%.tga:(%d+):(%d+)")
                            if height and width then
                                height = tonumber(height)
                                width = tonumber(width)
                                local path =
                                    tag:match("|T([^:]+%.tga)")
                                local animdata =
                                    path
                                    and TwitchEmotes_animation_metadata
                                    and TwitchEmotes_animation_metadata[path]
                                if animdata
                                    and animdata.frameHeight
                                    and animdata.frameHeight > 0
                                    and animdata.frameWidth
                                then
                                    height = 28
                                    width = math.floor(
                                        height
                                        * animdata.frameWidth
                                        / animdata.frameHeight
                                        + 0.5
                                    )
                                end

                                return width, height
                            end

                        end

                    end

                end

            end

        end

        return 28, 28
    end

    local function AnimateCustomChatFrame(frame)
        if not CanReadFrame(frame)
            or not frame:IsShown()
            or type(frame.visibleLines) ~= "table"
        then
            return
        end

        for _, line in ipairs(frame.visibleLines) do

            -- Avoid skipping Chattynator lines when

            -- both messageInfo and hover reference are nil.
            local isHoverMessage =
                TwitchEmotes_HoverMessageInfo ~= nil
                and type(line) == "table"
                and line.messageInfo == TwitchEmotes_HoverMessageInfo
            if not isHoverMessage then
                TwitchEmotesAnimator_UpdateEmoteInFontString(
                    line,
                    28,
                    28
                )
            end

        end
    end

    -- Animate custom chat FontStrings, including Ellesmere and Chattynator.
    local animator = CreateFrame("Frame")
    animator:SetScript("OnUpdate", function(_, elapsed)
        discoveryElapsed = discoveryElapsed + elapsed
        updateElapsed = updateElapsed + elapsed
        if discoveryElapsed >= DISCOVERY_INTERVAL then
            discoveryElapsed = 0
            SafeCall(DiscoverCustomChatFrames)
        end

        if updateElapsed < UPDATE_INTERVAL then
            return
        end

        updateElapsed = 0

        -- Per-frame so one bad frame does not stop the others animating.
        for _, frame in ipairs(customFrames) do
            SafeCall(AnimateCustomChatFrame, frame)
        end

    end)

    -- Chattynator emote-name tooltip.

    local function ShowEmoteTooltip()
        if not hoveredName then return end
        GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:SetText(hoveredName)
        GameTooltip:Show()
    end

    local function ClearEmoteTooltip()
        if not hoveredName then
            return
        end

        hoveredName = nil
        hoverX, hoverY = nil, nil
        hoverWidth, hoverHeight = 28, 28
        tooltipElapsed = 0
        GameTooltip:Hide()
    end

    local function OnChattynatorHyperlinkEnter(_, link)
        if type(link) ~= "string" then
            return
        end

        local emoteName = link:match("^tel:(.+)")
        if not emoteName then
            return
        end

        hoveredName = emoteName

        -- Calculate dimensions when the emote is hovered,

        -- not during addon initialization.
        local width, height = SafeCall(GetEmoteDisplaySize, emoteName)
        hoverWidth, hoverHeight = width or 28, height or 28

        -- Cursor coordinates are in physical pixels.
        hoverX, hoverY = GetCursorPosition()
        tooltipElapsed = 0
        ShowEmoteTooltip()
    end

    local function HookChattynator()
        if not Chattynator
            or not Chattynator.API
            or not Chattynator.API.GetHyperlinkHandler
        then
            return
        end

        local handler = Chattynator.API.GetHyperlinkHandler()
        if not handler or not handler.HookScript then
            return
        end

        handler:HookScript("OnHyperlinkEnter", function(...)
            SafeCall(OnChattynatorHyperlinkEnter, ...)
        end)
        handler:HookScript("OnHyperlinkClick", function(_, link, _, button)
            SafeCall(OnChatEmoteClick, link, button)
        end)

        -- Do not clear on OnHyperlinkLeave.

        -- Animated SetText() calls can invalidate hover state.
    end

    local loader = CreateFrame("Frame")
    loader:RegisterEvent("PLAYER_LOGIN")
    loader:SetScript("OnEvent", function()
        SafeCall(HookChattynator)
    end)

    -- Keep the tooltip visible through animation updates.
    local function TrackTooltip(elapsed)
        if not hoveredName then
            return
        end

        tooltipElapsed = tooltipElapsed + elapsed
        if tooltipElapsed < TOOLTIP_INTERVAL then
            return
        end

        tooltipElapsed = 0
        local x, y = GetCursorPosition()
        if not hoverX or not hoverY then
            ClearEmoteTooltip()
            return
        end

        local dx = math.abs(x - hoverX)
        local dy = math.abs(y - hoverY)

        -- Convert UI dimensions to cursor-coordinate pixels.
        local scale = UIParent:GetEffectiveScale()
        local maxX =
            hoverWidth * scale / 2 + HOVER_PADDING * scale
        local maxY =
            hoverHeight * scale / 2 + HOVER_PADDING * scale
        if dx > maxX or dy > maxY then
            ClearEmoteTooltip()
            return
        end

        -- Restore the tooltip if an animation frame dismissed it.
        if not GameTooltip:IsShown() then
            ShowEmoteTooltip()
        end

    end

    local tooltipTracker = CreateFrame("Frame")
    tooltipTracker:SetScript("OnUpdate", function(_, elapsed)
        SafeCall(TrackTooltip, elapsed)
    end)

end

-- Blizzard chat: animate hovered emotes while preserving tooltips.

-- Leave static emote tooltips to Blizzard's native handling.

do
    local UPDATE_INTERVAL = 0.033
    local TOOLTIP_INTERVAL = 0.05
    local HOVER_PADDING = 4
    local animationElapsed = 0
    local tooltipElapsed = 0
    local hoveredName = nil
    local hoverX, hoverY = nil, nil
    local hoverWidth, hoverHeight = 28, 28

    local function GetAnimatedEmoteDimensions(name)
        local texture = (judhead_emotes and judhead_emotes[name])
            or (TwitchEmotes_defaultpack and TwitchEmotes_defaultpack[name])
        if type(texture) ~= "string" then return nil end
        local path = texture:match("^(.-%.tga)")
        if not path then return nil end
        local animdata = TwitchEmotes_animation_metadata
            and TwitchEmotes_animation_metadata[path]
        if not animdata then return nil end

        -- Wide animations render at 28px height, preserving aspect ratio.
        if animdata.frameWidth and animdata.frameHeight
            and animdata.frameHeight > 0
            and animdata.frameWidth > animdata.frameHeight
        then
            local height = 28
            local width = math.floor(
                height * animdata.frameWidth / animdata.frameHeight + 0.5
            )
            return width, height
        end

        local width, height = texture:match("%.tga:(%d+):(%d+)")
        return tonumber(width) or 28, tonumber(height) or 28
    end

    local function ClearHover()
        if not hoveredName then return end
        hoveredName = nil
        hoverX, hoverY = nil, nil
        hoverWidth, hoverHeight = 28, 28
        GameTooltip:Hide()
    end

    local function RestoreTooltip()
        if not hoveredName then return end
        GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:SetText(hoveredName, 1, 1, 0)
        GameTooltip:Show()
    end

    local function OnHyperlinkEnter(_, link)
        if type(link) ~= "string" then return end
        local name = link:match("^tel:(.+)")
        if not name then return end
        local width, height = GetAnimatedEmoteDimensions(name)
        if not width then

            -- Static emotes use Blizzard's normal tooltip.
            if hoveredName then
                ClearHover()
            end

            return
        end

        if hoveredName ~= name then
            hoverX, hoverY = GetCursorPosition()
        end

        hoveredName = name
        hoverWidth, hoverHeight = width, height
        tooltipElapsed = 0
    end

    local loader = CreateFrame("Frame")
    loader:RegisterEvent("PLAYER_LOGIN")
    loader:SetScript("OnEvent", function()
        if not CHAT_FRAMES then return end
        for _, frameName in ipairs(CHAT_FRAMES) do
            local frame = _G[frameName]
            if frame and frame.HookScript then
                SafeCall(frame.HookScript, frame, "OnHyperlinkEnter", function(...)
                    SafeCall(OnHyperlinkEnter, ...)
                end)
                SafeCall(frame.HookScript, frame, "OnHyperlinkClick", function(_, link, _, button)
                    SafeCall(OnChatEmoteClick, link, button)
                end)
            end

        end

    end)

    local function AnimateHoveredLines(frame, info, updatedLines)
        if not frame:IsShown() or type(frame.visibleLines) ~= "table" then
            return
        end

        for _, line in ipairs(frame.visibleLines) do
            if type(line) == "table"
                and line.messageInfo == info
                and not updatedLines[line]
            then
                updatedLines[line] = true
                TwitchEmotesAnimator_UpdateEmoteInFontString(
                    line, 28, 28
                )

                -- Restore immediately if this update dismissed

                -- the tooltip for the animated emote.
                if hoveredName and not GameTooltip:IsShown() then
                    RestoreTooltip()
                end

            end

        end
    end

    local function TrackHover()
        if not hoveredName then return end
        if not hoverX or not hoverY then
            ClearHover()
            return
        end

        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        local dx = math.abs(x - hoverX)
        local dy = math.abs(y - hoverY)

        -- Conservative fallback: the entry point is not necessarily

        -- the center of the emote.
        local maxX = (hoverWidth + HOVER_PADDING) * scale
        local maxY = (hoverHeight + HOVER_PADDING) * scale
        if dx > maxX or dy > maxY then
            ClearHover()
            return
        end

        if not GameTooltip:IsShown() then
            RestoreTooltip()
        end
    end

    local tracker = CreateFrame("Frame")
    tracker:SetScript("OnUpdate", function(_, elapsed)
        animationElapsed = animationElapsed + elapsed
        tooltipElapsed = tooltipElapsed + elapsed

        -- Animate only the hovered message that upstream skips.
        if animationElapsed >= UPDATE_INTERVAL then
            animationElapsed = 0
            local info = TwitchEmotes_HoverMessageInfo
            if info and CHAT_FRAMES then
                local updatedLines = {}
                for _, frameName in ipairs(CHAT_FRAMES) do
                    local frame = _G[frameName]
                    if frame then
                        SafeCall(AnimateHoveredLines, frame, info, updatedLines)
                    end

                end

            end

        end

        if tooltipElapsed < TOOLTIP_INTERVAL then
            return
        end

        tooltipElapsed = 0
        SafeCall(TrackHover)
    end)

end

