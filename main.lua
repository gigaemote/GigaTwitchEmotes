local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

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

function judhead_startup()
    local suggestions = {};
    local i = 1;

    -- Setup minimap icon
    InitMinimapIcon();
    for k, v in pairs(judhead_emotes) do
        local emotePath = v
        if isWoWForever then
            emotePath = emotePath:gsub(":28:28$", ":20:20")
        end

        TwitchEmotes:AddEmote(k, k, emotePath);
        suggestions[i] = k;
        i = i + 1;
    end

    GigaTwitchEmotesRenderFrame(judhead_emotes);
    judhead_initsuggestions(suggestions);
end

function GigaTwitchEmotesRenderFrame(emotes)

    -- Sort emotes
    totalItems = 0
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

-- Ellesmere's history hook also handles Up/Down. Keep it from replacing
-- autocomplete text while the suggestion dropdown belongs to this edit box.
local function SetupEllesmereArrowCompatibility(editBox)
    if editBox.gigaArrowCompatibility then
        return
    end

    local originalSetText = editBox.SetText

    editBox.SetText = function(self, text, ...)
        local dropdown = EditBoxAutoCompleteBox

        if dropdown
            and dropdown:IsShown()
            and dropdown.parent == self
            and not IsAltKeyDown()
        then
            local stack = debugstack(2, 4, 0)

            if type(stack) == "string"
                and stack:find("EUI_Chat_EditBox.lua", 1, true)
            then
                return
            end
        end

        return originalSetText(self, text, ...)
    end

    editBox.gigaArrowCompatibility = true
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

            if C_AddOns and C_AddOns.IsAddOnLoaded
                and C_AddOns.IsAddOnLoaded("EllesmereUIChat")
            then
                SetupEllesmereArrowCompatibility(frame.editBox)
            end
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

    for emoteTextureString in txt:gmatch("(|TInterface\\AddOns\\TwitchEmotes.-|t)") do
        local imagepath = emoteTextureString:match("|T([^:]+%.tga)")
        local animdata = imagepath and TwitchEmotes_animation_metadata[imagepath]
        if animdata ~= nil then
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

            local nTxt = txt:gsub(
                escpattern(emoteTextureString),
                frameString
            )
            if fontstring.messageInfo ~= nil then
                fontstring.messageInfo.message = nTxt
            end

            fontstring:SetText(nTxt)
            txt = nTxt
        end

    end

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

    local function DiscoverCustomChatFrames()
        local found = {}
        local frame = EnumerateFrames()
        while frame do
            if not frame:GetName()
                and frame.visibleLines
                and not IsBlizzardChatFrame(frame)
            then
                found[#found + 1] = frame
            end

            frame = EnumerateFrames(frame)
        end

        customFrames = found
    end

    -- Find the displayed dimensions of an emote in Chattynator.

    -- WoW texture tags specify height before width.

    local function GetEmoteDisplaySize(emoteName)
        for _, frame in ipairs(customFrames) do
            if frame.pool
                and frame.scrollIndex
                and frame.visibleLines
            then
                for _, line in ipairs(frame.visibleLines) do
                    local txt = line:GetText()
                    if type(txt) == "string"
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

    -- Animate custom chat FontStrings, including Ellesmere and Chattynator.
    local animator = CreateFrame("Frame")
    animator:SetScript("OnUpdate", function(_, elapsed)
        discoveryElapsed = discoveryElapsed + elapsed
        updateElapsed = updateElapsed + elapsed
        if discoveryElapsed >= DISCOVERY_INTERVAL then
            discoveryElapsed = 0
            DiscoverCustomChatFrames()
        end

        if updateElapsed < UPDATE_INTERVAL then
            return
        end

        updateElapsed = 0
        if not TwitchEmotesAnimator_UpdateEmoteInFontString then
            return
        end

        for _, frame in ipairs(customFrames) do
            if frame:IsShown() and frame.visibleLines then
                for _, line in ipairs(frame.visibleLines) do

                    -- Avoid skipping Chattynator lines when

                    -- both messageInfo and hover reference are nil.
                    local isHoverMessage =
                        TwitchEmotes_HoverMessageInfo ~= nil
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

    local loader = CreateFrame("Frame")
    loader:RegisterEvent("PLAYER_LOGIN")
    loader:SetScript("OnEvent", function()
        if not Chattynator
            or not Chattynator.API
            or not Chattynator.API.GetHyperlinkHandler
        then
            return
        end

        local handler = Chattynator.API.GetHyperlinkHandler()
        if not handler then
            return
        end

        handler:HookScript("OnHyperlinkEnter", function(_, link)
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
            hoverWidth, hoverHeight =
                GetEmoteDisplaySize(emoteName)

            -- Cursor coordinates are in physical pixels.
            hoverX, hoverY = GetCursorPosition()
            tooltipElapsed = 0
            ShowEmoteTooltip()
        end)

        -- Do not clear on OnHyperlinkLeave.

        -- Animated SetText() calls can invalidate hover state.
    end)

    -- Keep the tooltip visible through animation updates.
    local tooltipTracker = CreateFrame("Frame")
    tooltipTracker:SetScript("OnUpdate", function(_, elapsed)
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
        if not texture then return nil end
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
            if frame then
                frame:HookScript(
                    "OnHyperlinkEnter", OnHyperlinkEnter
                )
            end

        end

    end)

    local tracker = CreateFrame("Frame")
    tracker:SetScript("OnUpdate", function(_, elapsed)
        animationElapsed = animationElapsed + elapsed
        tooltipElapsed = tooltipElapsed + elapsed

        -- Animate only the hovered message that upstream skips.
        if animationElapsed >= UPDATE_INTERVAL then
            animationElapsed = 0
            local info = TwitchEmotes_HoverMessageInfo
            if info
                and CHAT_FRAMES
                and TwitchEmotesAnimator_UpdateEmoteInFontString
            then
                local updatedLines = {}
                for _, frameName in ipairs(CHAT_FRAMES) do
                    local frame = _G[frameName]
                    if frame
                        and frame:IsShown()
                        and frame.visibleLines
                    then
                        for _, line in ipairs(frame.visibleLines) do
                            if line.messageInfo == info
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

                end

            end

        end

        if tooltipElapsed < TOOLTIP_INTERVAL then
            return
        end

        tooltipElapsed = 0
        if not hoveredName then return end
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

    end)

end

