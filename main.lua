local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")
local iconRegistered = false
 -- Main frame
local MyAddonFrame = CreateFrame("Frame", "MyAddonMainFrame", UIParent, "BasicFrameTemplateWithInset")
MyAddonFrame:SetSize(600, 550) -- Width, Height
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


local aboutText = (
"六四天安門事件 AshenvaleAutonomousZone Emote Pack \n天安門大屠殺 Originally Just " .. "|T" .. judhead_emotes["PEPW"] .. "|t   " .. "\n"..
"反右派鬥爭 Guildies kept contributing 大躍進政策 Grow In Numbers \n文化大革命 Many Emotes 人權 Erotic Role Play \n"..
"民運 Bitcoin Miner \n自由 Horny 獨立 Innuendo 多黨制 Labor of Love\n\n\n"..
"|T" .. TwitchEmotes_defaultpack["moon2CUTE"] .. "|t"
)
local tabs = {}
local tabNames = {"Emotes", "About"}
local panelType = "CharacterFrameTabButtonTemplate"

if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
    panelType = "PanelTabButtonTemplate"
end

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
-------------------------------------------------------------------------------
-- Slash command
-------------------------------------------------------------------------------
local slashFrame = CreateFrame("Frame")
slashFrame:RegisterEvent("ADDON_LOADED")
slashFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "TwitchEmotes_Giga" then
        if Giga_Settings == nil then
            Giga_Settings = {}
            Giga_Settings.minimap = true
        end
        judhead_startup();
    end
end)
SLASH_GIGA1 = "/giga" -- The slash command users will type in chat
-- Function to handle slash command input
SlashCmdList["GIGA"] = function(msg)
    -- Check if a value was provided
    if msg and msg ~= "" then
        if msg == "minimap" then
            if Giga_Settings.minimap then
                Giga_Settings.minimap = false
                print("|cFFFF69B4[GIGA] Minimap icon is now disabled. Please /reload.|r")
            else
                Giga_Settings.minimap = true
                print("|cFFFF69B4[GIGA] Minimap icon is now enabled. Please /reload.|r")
            end
        end
    else
        print("Usage: /giga minimap to toggle minimap icon")
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
local content = {}
local data = {}

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
--

function judhead_startup()
    local suggestions = {};
    local i = 1;
    -- Setup minimap icon
    InitMinimapIcon();

    for k, v in pairs(judhead_emotes) do
        -- Check emote is enabled ?
        TwitchEmotes:AddEmote(k, k, v);

        suggestions[i] = k;
        i = i + 1;
    end

    GigaTwitchEmotesRenderFrame(judhead_emotes);
    judhead_initsuggestions(suggestions);
end

function GigaTwitchEmotesRenderFrame(emotes)
    -- Sort emotes
    totalItems = 0
    -- content = {}
    data = {}
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
        s = "|T" .. judhead_emotes[key] .. "|t   " .. key
        table.insert(data, s);
    end

    local rowoffset = -30
    local coloffset = 1
    -- Two rows of emotes
    if frameInit == 0 then
        frameInit = 1
        for i = 1, itemsPerPage do
            content[i] = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            content[i]:SetPoint("TOPLEFT", rowoffset, -36 * (coloffset - 1))

            coloffset = coloffset + 1

            if coloffset > itemsPerPage / 2 then
                coloffset = 1
                rowoffset = 180
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
        if dataIndex <= endIndex then
            content[i]:SetText(data[dataIndex])
            TwitchEmotesAnimator_UpdateEmoteInFontString(content[i], 0, 0)
        else
            content[i]:SetText("")
        end
    end
    pageNumber:SetText("Page " .. currentPage .. " / " .. totalPages)
end


-- Function to filter and display data
local function SearchData(query)
    query = string.lower(query) -- Case-insensitive search
    local matches = {}

    for k, v in pairs(judhead_emotes) do
        if string.find(string.lower(k), query) then
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

-- Update results dynamically as user types
searchBox:SetScript("OnTextChanged", function(self)
    local query = self:GetText()
    if query and query ~= "" then
        SearchData(query)
    else
        GigaTwitchEmotesRenderFrame(judhead_emotes)
    end
end)

-- update animated emotes
local interval = 0.033 -- Time in seconds
local elapsed = 0
MyAddonFrame:SetScript("OnUpdate", function(self, deltaTime)
    if self:IsShown() then -- Only run while the frame is visible
        elapsed = elapsed + deltaTime
        if elapsed >= interval then
            UpdatePageContent();
            elapsed = 0 -- Reset timer
        end
    end
end)

function InitMinimapIcon()
    GigaTwitchIcon = LDB:NewDataObject("GIGATwitchEmotes", {
        type = "launcher",
        text = "GIGATwitchEmotes",
        icon = "Interface\\AddOns\\TwitchEmotes_Giga\\emotes\\PEPW.tga",
        OnClick = GIGATwitchEmotes_MinimapButton_OnClick
    })
    if Giga_Settings.minimap then
        LDBIcon:Register("GIGATwitchEmotes", GigaTwitchIcon, Giga_Settings)
    else
        LDBIcon:Hide("GIGATwitchEmotes");
    end
end

function judhead_concat(t1, t2)
    for i=1,#t2 do
        t1[#t1+1] = t2[i]
    end
    return t1
end

function judhead_initsuggestions(suggestions)
    if AllTwitchEmoteNames ~= nil and Emoticons_Settings ~= nil and Emoticons_RenderSuggestionFN ~= nil and Emoticons_Settings["ENABLE_AUTOCOMPLETE"] then

        judhead_concat(suggestions, AllTwitchEmoteNames);
        table.sort(suggestions);

        for i=1, NUM_CHAT_WINDOWS do
            local frame = _G["ChatFrame"..i]

            local maxButtonCount = 20;

            SetupAutoComplete(frame.editBox, suggestions, maxButtonCount, {
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
                    if TwitchEmoteStatistics ~= nil and TwitchEmoteStatistics[suggestion] ~= nil then
                        return TwitchEmoteStatistics[suggestion][1] * 5
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

function TwitchEmotesAnimator_UpdateEmoteInFontString(fontstring, widthOverride, heightOverride)
    local txt = fontstring:GetText();
    if (txt ~= nil) then
        for emoteTextureString in txt:gmatch("(|TInterface\\AddOns\\TwitchEmotes.-|t)") do
            local imagepath = emoteTextureString:match("|T(Interface\\AddOns\\TwitchEmotes.-tga).-|t")

            local animdata = TwitchEmotes_animation_metadata[imagepath];
            if (animdata ~= nil) then
                local framenum = TwitchEmotes_GetCurrentFrameNum(animdata);
                local nTxt;
		-- it is not an emote suggestion and it is a wide animated emote
		if (widthOverride ~= 16 and animdata.frameWidth > 32) then
                    nTxt = txt:gsub(escpattern(emoteTextureString),
                                        TwitchEmotes_BuildEmoteFrameStringWithDimensions(
                                        imagepath, animdata, framenum, animdata.frameHeight, animdata.frameWidth))
		elseif (widthOverride ~= nil or heightOverride ~= nil) then
                    nTxt = txt:gsub(escpattern(emoteTextureString),
                                        TwitchEmotes_BuildEmoteFrameStringWithDimensions(
                                        imagepath, animdata, framenum, widthOverride, heightOverride))
                else
                    nTxt = txt:gsub(escpattern(emoteTextureString),
                                      TwitchEmotes_BuildEmoteFrameString(
                                        imagepath, animdata, framenum))
                end

                -- If we're updating a chat message we need to alter the messageInfo as wel
                if (fontstring.messageInfo ~= nil) then
                    fontstring.messageInfo.message = nTxt
                end
                fontstring:SetText(nTxt);
                txt = nTxt;
            end
        end
    end
end
