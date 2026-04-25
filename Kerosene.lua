-- ═══════════════════════════════════════════════
--  Kerosene | V1.41  by Wobble
-- ═══════════════════════════════════════════════

-- ── Menu state ────────────────────────────────
local KERO_VERSION = "v1.41"

local KERO_WHITELIST = {
    url = "https://github.com/rilly321/whitelist/blob/main/whitelist.txt",
    requestTimeout = 15,
}

local keroWhitelistState = {
    started = false,
    pending = false,
    checked = false,
    authorized = false,
    booted = false,
}

local function KeroWhitelistTrim(s)
    return string.Trim(tostring(s or "")):gsub("^%z+", "")
end

local function KeroWhitelistNormalizeID(id)
    local cleaned = KeroWhitelistTrim(id)
    cleaned = cleaned:gsub("^\239\187\191", "")
    return string.upper(cleaned)
end

local function KeroWhitelistResolveURL(url)
    local cleaned = KeroWhitelistTrim(url)
    local owner, repo, branch, path = string.match(cleaned, "^https://github%.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$")
    if owner and repo and branch and path then
        return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo .. "/" .. branch .. "/" .. path
    end
    return cleaned
end

local function KeroWhitelistNotify(text, notifType, duration)
    notifType = notifType or NOTIFY_ERROR
    duration = duration or 8

    MsgN("[Kerosene] " .. text)

    timer.Simple(0, function()
        if GAMEMODE and GAMEMODE.Notify then
            GAMEMODE:Notify(text, notifType, duration)
        elseif notification and notification.AddLegacy then
            notification.AddLegacy(text, notifType, duration)
        elseif chat and chat.AddText then
            chat.AddText(Color(229, 160, 40), "[Kerosene] ", Color(235, 235, 235), text)
        end
    end)
end

local function KeroParseWhitelistBody(body)
    if not body or body == "" then
        return nil, "Whitelist response was empty."
    end

    local allowed = {}
    local trimmedBody = KeroWhitelistTrim(body)

    if string.StartWith(trimmedBody, "{") or string.StartWith(trimmedBody, "[") then
        local parsed = util.JSONToTable(trimmedBody)
        if istable(parsed) then
            local sources = {}
            if istable(parsed.ids) then table.insert(sources, parsed.ids) end
            if istable(parsed.whitelist) then table.insert(sources, parsed.whitelist) end
            if istable(parsed.steamids) then table.insert(sources, parsed.steamids) end
            if #sources == 0 and #parsed > 0 then table.insert(sources, parsed) end

            for _, src in ipairs(sources) do
                for _, entry in pairs(src) do
                    if isstring(entry) then
                        local norm = KeroWhitelistNormalizeID(entry)
                        if norm ~= "" then allowed[norm] = true end
                    elseif istable(entry) then
                        local sid64 = entry.steamid64 or entry.SteamID64
                        local sid = entry.steamid or entry.SteamID
                        if sid64 then allowed[KeroWhitelistNormalizeID(sid64)] = true end
                        if sid then allowed[KeroWhitelistNormalizeID(sid)] = true end
                    end
                end
            end
        end
    end

    if next(allowed) == nil then
        for rawLine in string.gmatch(body, "[^\r\n]+") do
            local line = KeroWhitelistTrim(rawLine)
            line = string.match(line, "^(.-)%s*#") or line
            line = KeroWhitelistTrim(line)
            if line ~= "" and not string.StartWith(line, "//") then
                allowed[KeroWhitelistNormalizeID(line)] = true
            end
        end
    end

    if next(allowed) == nil then
        return nil, "Whitelist did not contain any Steam IDs."
    end

    return allowed
end

local function KeroWhitelistAllowsPlayer(allowed, steamID64, steamID)
    if not allowed then return false end
    return allowed[KeroWhitelistNormalizeID(steamID64)] or allowed[KeroWhitelistNormalizeID(steamID)] or false
end

local function BootKerosene()

local isMenuOpen    = false
local keroFrame = nil
local currentTab    = "Combat"
local lastTab       = "Combat"   -- persisted across sessions
local tabAlpha      = 255        -- content fade alpha (0-255)
local tabFading     = false      -- true while fade-out is running
local tabFadeTarget = nil        -- the tab we are switching TO

-- ── Menu layout constants (promoted so UpdateContentPanel doesn't upvalue-capture from CreateKeroMenu) ──
local WIN_W, WIN_H  = 620, 340
local SIDEBAR_W     = 108
local HEADER_H      = 36
local FOOTER_H      = 22

-- ── VFX state (promoted for same reason) ──
local _vfxTime   = 0
local _sparks    = {}
local _sparkNext = 0
local _tabFlash  = 0

-- ── Panel refs (set inside CreateKeroMenu, referenced by UpdateContentPanel/BuildSidebar) ──
local buttonPanel  = nil
local contentPanel = nil

-- Menu toggle key (persists across opens)
local menuKey       = KEY_INSERT
local menuKeyName   = "INSERT"
local bindListening = false

-- Panic key — hides all visuals without unloading
local panicKey          = nil          -- unset by default
local panicKeyName      = "NONE"
local panicListening    = false
local panicMode         = false        -- true while visuals are hidden

-- ── Persistent options ────────────────────────
local options = {
    Combat = {},
    Visuals = {},
    Misc    = {},
    Players = {},
    Config  = {}
}

-- ── Tab option labels ─────────────────────────
local optionNames = {
    Combat  = { "Aimbot" },
    Visuals = { "Name", "Boxes", "Money", "Weapon", "Distance", "World ESP", "Suit Name", "Suit Health" },
    Misc    = { "Remove Recoil", "Remove Spread", "Combat Check" },
    Players = {},
    Config  = {}
}

-- ── Visual ESP colour state ───────────────────
local VisualColors = {
    Name      = { color = Color(200, 200, 200, 230), rainbow = false },
    Boxes     = { color = Color(200, 200, 200, 220), rainbow = false },
    Money     = { color = Color(200, 200, 200, 230), rainbow = false },
    Weapon    = { color = Color(200, 200, 200, 230), rainbow = false },
    Distance  = { color = Color(200, 200, 200, 220), rainbow = false },
    WorldESP  = { color = Color(200, 200, 200, 200), rainbow = false },
    SuitName  = { color = Color(200, 200, 200, 230), rainbow = false },
    SuitHealth= { color = Color(200, 200, 200, 230), rainbow = false },
}

-- Misc HUD colour state
local MiscColors = {
    ArmChams    = { color = Color(255, 100, 100, 255), rainbow = false },
    WeaponChams = { color = Color(100, 200, 255, 255), rainbow = false },
    CombatCheck = { color = Color(220, 100,  80, 255), rainbow = false },
}

local PlayerESPColors = {
    Friend = { color = Color(100, 200, 255, 255) },
    Enemy  = { color = Color(255, 110, 110, 255) },
}

-- World ESP entity class filter — list of class strings to show (empty = all)
local worldESPFilters = {}

-- ── ESP Arrangement (2D-box relative) ────────────────────────────────────────
-- Each ESP element is positioned relative to the player's 2D bounding box.
-- anchor: "Above" | "Below" | "Left" | "Right"
-- pad:    pixel gap from the box edge
-- slot:   vertical stacking order (for same-anchor items; 1 = closest to box)
local ESPArrangement = {
    Name      = { anchor = "Above", pad = 4,  slot = 1, bold = false, outline = false },
    Money     = { anchor = "Above", pad = 16, slot = 2, bold = false, outline = false },
    Weapon    = { anchor = "Above", pad = 28, slot = 3, bold = false, outline = false },
    Distance  = { anchor = "Below", pad = 4,  slot = 1, bold = false, outline = false },
    SuitName  = { anchor = "Below", pad = 16, slot = 2, bold = false, outline = false },
    SuitHealth= { anchor = "Below", pad = 28, slot = 3, bold = false, outline = false },
}

-- Compute screen position + text alignments for an ESP label given the 2D box and arrangement entry
-- Returns: x, y, halign, valign
local function ESPLabelPos(boxX1, boxY1, boxX2, boxY2, arr)
    local cx = (boxX1 + boxX2) / 2
    local cy = (boxY1 + boxY2) / 2
    local anchor = arr.anchor
    local pad    = arr.pad or 4
    if anchor == "Above" then
        return cx, boxY1 - pad, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM
    elseif anchor == "Below" then
        return cx, boxY2 + pad, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP
    elseif anchor == "Left" then
        return boxX1 - pad, cy, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER
    elseif anchor == "Right" then
        return boxX2 + pad, cy, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER
    end
    return cx, boxY1 - pad, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM
end

-- Arm/Weapon chams toggles
local miscChams = {
    ArmChams    = false,
    WeaponChams = false,
}

-- Sync miscChams from options (called after load)
local function SyncChamsFromOptions()
    if options.Misc.ArmChams    ~= nil then miscChams.ArmChams    = options.Misc.ArmChams    end
    if options.Misc.WeaponChams ~= nil then miscChams.WeaponChams = options.Misc.WeaponChams end
end

-- ── Combat Check state ────────────────────────
-- combatCheckTargets: list of player nick strings to watch (empty = off)
local combatCheckTargets = {}
local combatCheckTarget  = ""  -- kept for legacy hook compat, set to first target
-- Notification queue: { text, expiry, alpha }
local combatNotifs = {}
-- Track last known state to avoid duplicate alerts
local combatCheckLastHP  = {}
local combatCheckLastShoot = {}
local playerStates = {}
local pendingLegacyWatchNames = {}

local function GetPlayerStateID(ply)
    if not IsValid(ply) then return nil end
    local sid64 = ply:SteamID64()
    if sid64 and sid64 ~= "" and sid64 ~= "0" then return sid64 end
    local sid = ply:SteamID()
    if sid and sid ~= "" then return sid end
    return ply:Nick()
end

local function GetOrCreatePlayerState(id)
    if not id or id == "" then return nil end
    playerStates[id] = playerStates[id] or {}
    return playerStates[id]
end

local function CleanupPlayerState(id)
    local state = playerStates[id]
    if not state then return end
    if not state.friend and not state.enemy and not state.watch then
        playerStates[id] = nil
    end
end

local function RefreshCombatCheckTargets()
    combatCheckTargets = {}
    for _, ply in ipairs(player.GetAll()) do
        local id = GetPlayerStateID(ply)
        local state = id and playerStates[id] or nil
        if state and state.watch then
            table.insert(combatCheckTargets, ply:Nick())
        end
    end
    table.sort(combatCheckTargets, function(a, b)
        return string.lower(a) < string.lower(b)
    end)
    combatCheckTarget = combatCheckTargets[1] or ""
end

local function SetPlayerFlag(id, flag, enabled)
    local state = GetOrCreatePlayerState(id)
    if not state then return end
    if flag == "friend" and enabled then state.enemy = false end
    if flag == "enemy" and enabled then state.friend = false end
    state[flag] = enabled or nil
    CleanupPlayerState(id)
    RefreshCombatCheckTargets()
end

local function PlayerHasFlag(ply, flag)
    local id = GetPlayerStateID(ply)
    local state = id and playerStates[id] or nil
    return state and state[flag] or false
end

local function MigrateLegacyCombatTargets()
    if #pendingLegacyWatchNames == 0 then return end
    local remaining = {}
    for _, wantedName in ipairs(pendingLegacyWatchNames) do
        local matched = false
        for _, ply in ipairs(player.GetAll()) do
            if IsValid(ply) and string.lower(ply:Nick()) == string.lower(wantedName) then
                local id = GetPlayerStateID(ply)
                if id then SetPlayerFlag(id, "watch", true) end
                matched = true
                break
            end
        end
        if not matched then
            table.insert(remaining, wantedName)
        end
    end
    pendingLegacyWatchNames = remaining
end

-- ── Targeted Suits filter ─────────────────────
-- Display names shown in the UI dropdown
local SUIT_DISPLAY = { "Admin Suit V3", "Admin Suit V2", "God Slayer", "Fallen God", "Ultra God" }
-- Actual NW string values for each
local SUIT_ACTUAL  = {
    ["Admin Suit V3"] = "Admin Suit v3",
    ["Admin Suit V2"] = "Admin Suit v2",
    ["God Slayer"]    = "Tier God Slayer",
    ["Fallen God"]    = "Tier Fallen God",
    ["Ultra God"]     = "Tier Ultra God",
}
-- Currently selected filters (table of actual NW strings, empty = show all)
local targetedSuitFilters = {}  -- list of actual NW strings to match, empty = all

-- ── Shared rainbow hue ────────────────────────
local visualHue = 0

-- ── Console flood — defined early so unload can call it ──
local function NukeConsole()
    for i = 1, 1400 do
        MsgN(string.rep(" ", (i % 120) + 1))
    end
end

local function RainbowColor(hue, alpha)
    local h = hue * 6
    local i = math.floor(h) % 6
    local f = h - math.floor(h)
    local q = 1 - f
    local r, g, b
    if     i == 0 then r,g,b = 1,  f,  0
    elseif i == 1 then r,g,b = q,  1,  0
    elseif i == 2 then r,g,b = 0,  1,  f
    elseif i == 3 then r,g,b = 0,  q,  1
    elseif i == 4 then r,g,b = f,  0,  1
    else              r,g,b = 1,  0,  q end
    return Color(r*255, g*255, b*255, alpha or 255)
end

local function GetVisualColor(key, alpha)
    local feat = VisualColors[key]
    if not feat then return Color(200,200,200, alpha or 255) end
    if feat.rainbow then return RainbowColor(visualHue, alpha or feat.color.a) end
    local c = feat.color
    return Color(c.r, c.g, c.b, alpha or c.a)
end

local function GetMiscColor(key, alpha)
    local feat = MiscColors[key]
    if not feat then return Color(200,200,200, alpha or 255) end
    if feat.rainbow then return RainbowColor(visualHue, alpha or feat.color.a) end
    local c = feat.color
    return Color(c.r, c.g, c.b, alpha or c.a)
end

local function GetPlayerESPColor(ply, key)
    local base = GetVisualColor(key)
    if PlayerHasFlag(ply, "friend") then
        local c = PlayerESPColors.Friend.color
        return Color(c.r, c.g, c.b, base.a)
    end
    if PlayerHasFlag(ply, "enemy") then
        local c = PlayerESPColors.Enemy.color
        return Color(c.r, c.g, c.b, base.a)
    end
    return base
end

-- ── UI colour palette ─────────────────────────
--   Kerosene: flat dark slate + amber accent
local COL_BG      = Color(14,  15,  17,  255)   -- near-black slate
local COL_HEADER  = Color(20,  21,  24,  255)   -- slightly lighter slate
local COL_BORDER  = Color(38,  40,  45,  255)   -- subtle edge line
local COL_ACCENT  = Color(229, 160,  40, 255)   -- amber / kerosene flame
local COL_TEXTMUT = Color(90,  94, 102, 255)    -- dim grey label
local COL_TEXTPRI = Color(210, 212, 216, 255)   -- light slate text
local COL_BTN     = Color(26,  28,  32,  255)   -- dark control bg
local COL_BTNHOV  = Color(36,  38,  44,  255)   -- hover state
local COL_GREEN   = Color(75,  195, 120, 255)   -- enabled indicator
local COL_RED     = Color(195,  65,  55, 255)   -- danger / unload

-- ════════════════════════════════════════════════
--  Themed colour picker
-- ════════════════════════════════════════════════
local function OpenColorPicker(getColor, setColor)
    if IsValid(_G._KeroColorPicker) then _G._KeroColorPicker:Remove() end

    local PW, PH = 260, 350
    local scrW, scrH = ScrW(), ScrH()
    local popup = vgui.Create("DFrame")
    popup:SetSize(PW, PH)
    popup:SetPos((scrW - PW) / 2, (scrH - PH) / 2)
    popup:SetTitle("") ; popup:SetDraggable(true)
    popup:ShowCloseButton(false) ; popup:MakePopup() ; popup:SetDeleteOnClose(true)
    _G._KeroColorPicker = popup

    popup.Paint = function(self, w, h)
        draw.RoundedBox(10, 3, 5, w, h, Color(0,0,0,90))
        draw.RoundedBox(8, 0, 0, w, h, COL_BG)
        draw.RoundedBoxEx(8, 0, 0, w, 36, COL_HEADER, true, true, false, false)
        surface.SetDrawColor(COL_BORDER) ; surface.DrawRect(0, 36, w, 1)
        draw.SimpleText("Colour Picker", "DermaDefaultBold", 12, 18, COL_ACCENT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    local SQ = 180
    local sqX, sqY = (PW - SQ) / 2, 46
    local initC = getColor()
    local curH, curS, curV = ColorToHSV(initC)
    local curA = initC.a / 255

    local sq = popup:Add("DPanel")
    sq:SetPos(sqX, sqY) ; sq:SetSize(SQ, SQ)
    sq.Paint = function(self, w, h)
        for col = 0, w - 1 do
            local s = col / (w - 1)
            for row = 0, h - 1 do
                local v  = 1 - (row / (h - 1))
                local rc = HSVToColor(curH, s, v)
                surface.SetDrawColor(rc.r, rc.g, rc.b, 255)
                surface.DrawRect(col, row, 1, 1)
            end
        end
        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, w, h, 1)
        local cx = math.Round(curS * (w - 1))
        local cy = math.Round((1 - curV) * (h - 1))
        surface.SetDrawColor(0,0,0,200)      ; surface.DrawOutlinedRect(cx-5, cy-5, 10, 10, 1)
        surface.SetDrawColor(255,255,255,230) ; surface.DrawOutlinedRect(cx-4, cy-4,  8,  8, 1)
    end
    sq.OnMousePressed  = function(self) self.dragging = true  end
    sq.OnMouseReleased = function(self) self.dragging = false end
    sq.Think = function(self)
        if self.dragging then
            local mx, my = self:CursorPos()
            curS = math.Clamp(mx / (SQ - 1), 0, 1)
            curV = math.Clamp(1 - (my / (SQ - 1)), 0, 1)
        end
    end

    local barY, barH, barX, barW = sqY + SQ + 8, 14, sqX, SQ
    local hueBar = popup:Add("DPanel")
    hueBar:SetPos(barX, barY) ; hueBar:SetSize(barW, barH)
    hueBar.Paint = function(self, w, h)
        for i = 0, w - 1 do
            local c = HSVToColor(360 * (i / (w - 1)), 1, 1)
            surface.SetDrawColor(c.r, c.g, c.b, 255) ; surface.DrawRect(i, 0, 1, h)
        end
        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, w, h, 1)
        local hx = math.Round((curH / 360) * (w - 1))
        surface.SetDrawColor(0,0,0,200)       ; surface.DrawRect(hx-2, 0, 4, h)
        surface.SetDrawColor(255,255,255,220)  ; surface.DrawRect(hx-1, 0, 2, h)
    end
    hueBar.OnMousePressed  = function(self) self.dragging = true  end
    hueBar.OnMouseReleased = function(self) self.dragging = false end
    hueBar.Think = function(self)
        if self.dragging then
            local mx, _ = self:CursorPos()
            curH = math.Clamp(mx / (barW - 1), 0, 1) * 360
        end
    end

    local alpY = barY + barH + 6
    local alpBar = popup:Add("DPanel")
    alpBar:SetPos(barX, alpY) ; alpBar:SetSize(barW, barH)
    alpBar.Paint = function(self, w, h)
        for i = 0, math.floor(w/8) do
            for j = 0, math.floor(h/8) do
                local even = (i+j)%2==0
                surface.SetDrawColor(even and 180 or 120, even and 180 or 120, even and 180 or 120, 255)
                surface.DrawRect(i*8, j*8, 8, 8)
            end
        end
        local rc = HSVToColor(curH, curS, curV)
        for i = 0, w-1 do
            local a = math.Round((i/(w-1))*255)
            surface.SetDrawColor(rc.r, rc.g, rc.b, a) ; surface.DrawRect(i, 0, 1, h)
        end
        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
        local ax = math.Round(curA*(w-1))
        surface.SetDrawColor(0,0,0,200)      ; surface.DrawRect(ax-2,0,4,h)
        surface.SetDrawColor(255,255,255,220) ; surface.DrawRect(ax-1,0,2,h)
    end
    alpBar.OnMousePressed  = function(self) self.dragging = true  end
    alpBar.OnMouseReleased = function(self) self.dragging = false end
    alpBar.Think = function(self)
        if self.dragging then
            local mx, _ = self:CursorPos()
            curA = math.Clamp(mx/(barW-1), 0, 1)
        end
    end

    local previewY = alpY + barH + 8
    local preview = popup:Add("DPanel")
    preview:SetPos(sqX, previewY) ; preview:SetSize(SQ, 22)
    preview.Paint = function(self, w, h)
        local rc = HSVToColor(curH, curS, curV)
        draw.RoundedBox(4, 0, 0, w, h, Color(rc.r, rc.g, rc.b, math.Round(curA*255)))
        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
    end

    local btnY = previewY + 22 + 8
    local applyBtn = popup:Add("DButton")
    applyBtn:SetPos(sqX, btnY) ; applyBtn:SetSize(SQ, 28) ; applyBtn:SetText("")
    applyBtn.Paint = function(self, w, h)
        draw.RoundedBox(6, 0, 0, w, h, self:IsHovered() and COL_BTNHOV or COL_BTN)
        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
        draw.SimpleText("Apply","DermaDefaultBold",w/2,h/2,COL_TEXTPRI,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
    end
    applyBtn.DoClick = function()
        local rc = HSVToColor(curH, curS, curV)
        setColor(Color(rc.r, rc.g, rc.b, math.Round(curA*255)))
        popup:Remove()
    end

    local cancelBtn = popup:Add("DButton")
    cancelBtn:SetPos(PW-30, 5) ; cancelBtn:SetSize(24, 26) ; cancelBtn:SetText("")
    cancelBtn.Paint = function(self, w, h)
        if self:IsHovered() then draw.RoundedBox(5,0,0,w,h,Color(160,50,50,220)) end
        draw.SimpleText("x","DermaDefault",w/2,h/2,self:IsHovered() and color_white or COL_TEXTMUT,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
    end
    cancelBtn.DoClick = function() popup:Remove() end
end

-- ════════════════════════════════════════════════
--  ESP Arrangement popup  (box-relative)
--  Lets the user choose anchor + padding for each
--  ESP label relative to the player's 2D box.
-- ════════════════════════════════════════════════
local function OpenESPArrangementMenu()
    if IsValid(_G._KeroESPArrange) then _G._KeroESPArrange:Remove() end

    local ELEMS   = { "Name", "Money", "Weapon", "Distance", "SuitName", "SuitHealth" }
    local ANCHORS = { "Above", "Below", "Left", "Right" }
    local PW      = 420
    local ROW_H   = 40
    local PH      = 50 + #ELEMS * ROW_H + 10

    local scrW, scrH = ScrW(), ScrH()
    local popup = vgui.Create("DFrame")
    popup:SetSize(PW, PH)
    popup:SetPos((scrW - PW) / 2, (scrH - PH) / 2)
    popup:SetTitle("") ; popup:SetDraggable(true)
    popup:ShowCloseButton(false) ; popup:MakePopup() ; popup:SetDeleteOnClose(true)
    _G._KeroESPArrange = popup

    popup.Paint = function(self, w, h)
        draw.RoundedBox(10, 3, 5, w, h, Color(0,0,0,100))
        draw.RoundedBox(8, 0, 0, w, h, COL_BG)
        draw.RoundedBoxEx(8, 0, 0, w, 36, COL_HEADER, true, true, false, false)
        surface.SetDrawColor(COL_BORDER) ; surface.DrawRect(0, 36, w, 1)
        draw.SimpleText("ESP Placement", "DermaDefaultBold", 12, 18, COL_ACCENT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    -- Close button
    local closeBtn = popup:Add("DButton")
    closeBtn:SetPos(PW - 30, 5) ; closeBtn:SetSize(24, 26) ; closeBtn:SetText("")
    closeBtn.Paint = function(self, w, h)
        if self:IsHovered() then draw.RoundedBox(5,0,0,w,h,Color(160,30,60,220)) end
        draw.SimpleText("x","DermaDefault",w/2,h/2,self:IsHovered() and color_white or COL_TEXTMUT,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
    end
    closeBtn.DoClick = function() popup:Remove() end

    -- Column headers
    local hdrPanel = popup:Add("DPanel")
    hdrPanel:SetPos(0, 38) ; hdrPanel:SetSize(PW, 16)
    hdrPanel.Paint = function(self, w, h)
        draw.SimpleText("Element",  "DermaDefault",  10, h/2, COL_TEXTMUT, TEXT_ALIGN_LEFT,   TEXT_ALIGN_CENTER)
        draw.SimpleText("Anchor",   "DermaDefault", 105, h/2, COL_TEXTMUT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText("Padding",  "DermaDefault", 230, h/2, COL_TEXTMUT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText("Bold",     "DermaDefault", 320, h/2, COL_TEXTMUT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText("Outline",  "DermaDefault", 370, h/2, COL_TEXTMUT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    for idx, elem in ipairs(ELEMS) do
        local rowY = 56 + (idx - 1) * ROW_H
        local arr  = ESPArrangement[elem]

        local row = popup:Add("DPanel")
        row:SetPos(6, rowY) ; row:SetSize(PW - 12, ROW_H - 4)
        row.Paint = function(self, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(22, 12, 22, 200))
            surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
            draw.SimpleText(elem, "DermaDefault", 8, h/2, COL_TEXTPRI, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end

        -- Anchor cycle button
        local anchorBtn = row:Add("DButton")
        anchorBtn:SetPos(72, 6) ; anchorBtn:SetSize(70, 22) ; anchorBtn:SetText("")
        anchorBtn.Paint = function(self, w, h)
            draw.RoundedBox(4, 0, 0, w, h, self:IsHovered() and COL_BTNHOV or COL_BTN)
            surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
            draw.SimpleText(arr.anchor, "DermaDefault", w/2, h/2, COL_ACCENT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        anchorBtn.DoClick = function()
            local cur = 1
            for i, a in ipairs(ANCHORS) do if a == arr.anchor then cur = i ; break end end
            arr.anchor = ANCHORS[(cur % #ANCHORS) + 1]
        end

        -- Pad slider (0-40px)
        local PAD_MIN, PAD_MAX = 0, 60
        local TRACK_W = 70
        local TRACK_H = 4
        local THUMB_R = 5
        local padPanel = row:Add("DPanel")
        padPanel:SetPos(162, 4) ; padPanel:SetSize(TRACK_W, ROW_H - 8)
        padPanel.Paint = function() end
        local padDrag = false
        padPanel.Paint = function(self, w, h)
            local cy = h / 2
            local frac = (arr.pad - PAD_MIN) / (PAD_MAX - PAD_MIN)
            draw.RoundedBox(2, 0, cy - TRACK_H/2, w, TRACK_H, Color(35,18,35,255))
            surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, cy - TRACK_H/2, w, TRACK_H, 1)
            local fillW = math.max(0, math.Round(frac * w))
            if fillW > 0 then draw.RoundedBox(2, 0, cy - TRACK_H/2, fillW, TRACK_H, COL_ACCENT) end
            local tx = math.Round(frac * (w - 1))
            draw.RoundedBox(THUMB_R, tx - THUMB_R, cy - THUMB_R, THUMB_R*2, THUMB_R*2,
                padDrag and COL_ACCENT or COL_TEXTPRI)
            draw.SimpleText(tostring(arr.pad).."px", "DermaDefault", tx, cy - THUMB_R - 2,
                COL_TEXTPRI, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
        end
        local function UpdatePad()
            local mx, _ = padPanel:CursorPos()
            arr.pad = math.Round(math.Clamp(mx / (TRACK_W - 1), 0, 1) * (PAD_MAX - PAD_MIN) + PAD_MIN)
        end
        padPanel.OnMousePressed  = function(self, mb) if mb == MOUSE_LEFT then padDrag = true  ; UpdatePad() end end
        padPanel.OnMouseReleased = function(self, mb) if mb == MOUSE_LEFT then padDrag = false end end
        padPanel.Think = function(self) if padDrag then UpdatePad() end end

        -- Bold toggle button
        local boldBtn = row:Add("DButton")
        boldBtn:SetPos(row:GetWide() - 104, 6) ; boldBtn:SetSize(36, 22) ; boldBtn:SetText("")
        boldBtn.Paint = function(self, w, h)
            local on = arr.bold
            local bg = on and Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 40)
                          or (self:IsHovered() and COL_BTNHOV or COL_BTN)
            draw.RoundedBox(4, 0, 0, w, h, bg)
            surface.SetDrawColor(on and COL_ACCENT or COL_BORDER)
            surface.DrawOutlinedRect(0, 0, w, h, 1)
            draw.SimpleText("B", on and "DermaDefaultBold" or "DermaDefault",
                w/2, h/2, on and COL_ACCENT or COL_TEXTMUT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        boldBtn.DoClick = function() arr.bold = not arr.bold end

        -- Outline toggle button
        local outlineBtn = row:Add("DButton")
        outlineBtn:SetPos(row:GetWide() - 58, 6) ; outlineBtn:SetSize(48, 22) ; outlineBtn:SetText("")
        outlineBtn.Paint = function(self, w, h)
            local on = arr.outline
            local bg = on and Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 40)
                          or (self:IsHovered() and COL_BTNHOV or COL_BTN)
            draw.RoundedBox(4, 0, 0, w, h, bg)
            surface.SetDrawColor(on and COL_ACCENT or COL_BORDER)
            surface.DrawOutlinedRect(0, 0, w, h, 1)
            -- Draw a mini outlined "O" style preview
            local lbl = on and "ON" or "OFF"
            draw.SimpleText(lbl, "DermaDefault",
                w/2, h/2, on and COL_ACCENT or COL_TEXTMUT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        outlineBtn.DoClick = function() arr.outline = not arr.outline end
    end
end

-- ════-- ════════════════════════════════════════════════
--  Themed text entry (matches button style)
-- ════════════════════════════════════════════════
local function MakeThemedEntry(parent, x, y, w, h, placeholder, initialVal)
    h = h or 22
    local entry = parent:Add("DTextEntry")
    entry:SetPos(x, y) ; entry:SetSize(w, h)
    entry:SetPlaceholderText(placeholder or "")
    entry:SetValue(initialVal or "")
    entry:SetTextColor(COL_TEXTPRI)
    entry:SetFont("DermaDefault")
    entry:SetCursorColor(COL_ACCENT)
    -- Override default Derma paint to match our theme
    entry.Paint = function(self, ew, eh)
        draw.RoundedBox(4, 0, 0, ew, eh, self:IsEditing() and COL_BTNHOV or COL_BTN)
        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, ew, eh, 1)
        self:DrawTextEntryText(COL_TEXTPRI, Color(80,140,200,180), COL_TEXTPRI)
        if self:GetValue() == "" and not self:IsEditing() then
            draw.SimpleText(placeholder or "", "DermaDefault", 6, eh/2, COL_TEXTMUT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
    end
    return entry
end

-- ════════════════════════════════════════════════
--  Themed dropdown factory — no green indicator dots
-- ════════════════════════════════════════════════
local function MakeThemedDropdown(parent, x, y, w, choices, currentValue, onChange)
    local h = 22

    local container = parent:Add("DPanel")
    container:SetPos(x, y) ; container:SetSize(w, h)
    container.Paint = function() end

    local displayBtn = container:Add("DButton")
    displayBtn:SetPos(0, 0) ; displayBtn:SetSize(w, h) ; displayBtn:SetText("")

    local selectedVal = currentValue or choices[1] or ""
    local isOpen = false
    local dropPanel = nil

    displayBtn.Paint = function(self, bw, bh)
        draw.RoundedBox(4, 0, 0, bw, bh, self:IsHovered() and COL_BTNHOV or COL_BTN)
        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, bw, bh, 1)
        draw.SimpleText(selectedVal, "DermaDefault", 7, bh/2, COL_TEXTPRI, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        -- small arrow indicator
        local ax = bw - 12
        surface.SetDrawColor(COL_TEXTMUT)
        surface.DrawRect(ax,     bh/2 - 1, 6, 1)
        surface.DrawRect(ax + 1, bh/2 + 1, 4, 1)
        surface.DrawRect(ax + 2, bh/2 + 3, 2, 1)
    end

    local function CloseDropPanel()
        if IsValid(dropPanel) then dropPanel:Remove() end
        dropPanel = nil
        isOpen = false
    end

    displayBtn.DoClick = function()
        if isOpen then CloseDropPanel() ; return end
        isOpen = true

        local itemH = 22
        local totalH = math.max(#choices, 1) * itemH
        local sx, sy = container:LocalToScreen(0, h)

        dropPanel = vgui.Create("DPanel")
        dropPanel:SetPos(sx, sy)
        dropPanel:SetSize(w, totalH)
        dropPanel:MakePopup()
        dropPanel:SetKeyboardInputEnabled(false)
        dropPanel.Paint = function(self, pw, ph)
            draw.RoundedBoxEx(4, 0, 0, pw, ph, COL_BTN, false, false, true, true)
            surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, pw, ph, 1)
        end

        for idx, choice in ipairs(choices) do
            local iy = (idx - 1) * itemH
            local item = dropPanel:Add("DButton")
            item:SetPos(0, iy) ; item:SetSize(w, itemH) ; item:SetText("")
            local isSel = (choice == selectedVal)
            item.Paint = function(self, iw, ih)
                if self:IsHovered() or isSel then
                    draw.RoundedBox(0, 0, 0, iw, ih, COL_BTNHOV)
                end
                -- No green indicator dot — cleaner look
                draw.SimpleText(choice, "DermaDefault", 7, ih/2, isSel and COL_ACCENT or COL_TEXTPRI, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
            item.DoClick = function()
                selectedVal = choice
                CloseDropPanel()
                if onChange then onChange(choice) end
            end
        end

        dropPanel.Think = function(self)
            if not IsValid(displayBtn) then CloseDropPanel() ; return end
            if input.IsMouseDown(MOUSE_LEFT) then
                local mx, my = gui.MousePos()
                local px, py = self:GetPos()
                local pw, ph = self:GetSize()
                if mx < px or mx > px + pw or my < py or my > py + ph then
                    CloseDropPanel()
                end
            end
        end
    end

    container.GetValue    = function() return selectedVal end
    container.SetChosenValue = function(v) selectedVal = v end
    container.Close       = CloseDropPanel

    return container
end

-- ════════════════════════════════════════════════
--  Multi-select dropdown (for Targeted Suits / Combat Check players)
-- ════════════════════════════════════════════════
local function MakeMultiSelectDropdown(parent, x, y, w, choices, selectedTable, onToggle, labelFn)
    -- selectedTable: reference to a lua table (list) that holds selected values
    -- onToggle(val, nowSelected): called when an item is toggled
    -- labelFn(): returns the display label string (optional)
    local h = 22

    local container = parent:Add("DPanel")
    container:SetPos(x, y) ; container:SetSize(w, h)
    container.Paint = function() end

    local isOpen = false
    local dropPanel = nil

    local function GetLabel()
        if labelFn then return labelFn() end
        if #selectedTable == 0 then return "None selected" end
        if #selectedTable == 1 then return selectedTable[1] end
        return selectedTable[1] .. " (+" .. (#selectedTable - 1) .. ")"
    end

    local displayBtn = container:Add("DButton")
    displayBtn:SetPos(0, 0) ; displayBtn:SetSize(w, h) ; displayBtn:SetText("")
    displayBtn.Paint = function(self, bw, bh)
        draw.RoundedBox(4, 0, 0, bw, bh, self:IsHovered() and COL_BTNHOV or COL_BTN)
        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, bw, bh, 1)
        draw.SimpleText(GetLabel(), "DermaDefault", 7, bh/2, COL_TEXTPRI, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        local ax = bw - 12
        surface.SetDrawColor(COL_TEXTMUT)
        surface.DrawRect(ax,     bh/2 - 1, 6, 1)
        surface.DrawRect(ax + 1, bh/2 + 1, 4, 1)
        surface.DrawRect(ax + 2, bh/2 + 3, 2, 1)
    end

    local function CloseDropPanel()
        if IsValid(dropPanel) then dropPanel:Remove() end
        dropPanel = nil ; isOpen = false
    end

    local function IsSelected(val)
        for _, v in ipairs(selectedTable) do
            if v == val then return true end
        end
        return false
    end

    displayBtn.DoClick = function()
        if isOpen then CloseDropPanel() ; return end
        isOpen = true

        local itemH = 22
        local totalH = math.max(#choices, 1) * itemH
        local sx, sy = container:LocalToScreen(0, h)

        dropPanel = vgui.Create("DPanel")
        dropPanel:SetPos(sx, sy) ; dropPanel:SetSize(w, totalH)
        dropPanel:MakePopup() ; dropPanel:SetKeyboardInputEnabled(false)
        dropPanel.Paint = function(self, pw, ph)
            draw.RoundedBoxEx(4, 0, 0, pw, ph, COL_BTN, false, false, true, true)
            surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, pw, ph, 1)
        end

        local itemBtns = {}
        for idx, choice in ipairs(choices) do
            local iy = (idx - 1) * itemH
            local item = dropPanel:Add("DButton")
            item:SetPos(0, iy) ; item:SetSize(w, itemH) ; item:SetText("")
            itemBtns[idx] = item
            item.Paint = function(self, iw, ih)
                local sel = IsSelected(choice)
                if self:IsHovered() or sel then
                    draw.RoundedBox(0, 0, 0, iw, ih, COL_BTNHOV)
                end
                -- checkmark indicator
                if sel then
                    draw.SimpleText("✓", "DermaDefault", iw - 14, ih/2, COL_GREEN, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                end
                draw.SimpleText(choice, "DermaDefault", 7, ih/2, sel and COL_ACCENT or COL_TEXTPRI, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
            item.DoClick = function()
                local sel = IsSelected(choice)
                if sel then
                    -- remove from table
                    for i = #selectedTable, 1, -1 do
                        if selectedTable[i] == choice then table.remove(selectedTable, i) end
                    end
                    if onToggle then onToggle(choice, false) end
                else
                    table.insert(selectedTable, choice)
                    if onToggle then onToggle(choice, true) end
                end
                -- keep panel open — don't close
            end
        end

        dropPanel.Think = function(self)
            if not IsValid(displayBtn) then CloseDropPanel() ; return end
            if input.IsMouseDown(MOUSE_LEFT) then
                local mx, my = gui.MousePos()
                local px, py = self:GetPos()
                local pw, ph = self:GetSize()
                if mx < px or mx > px + pw or my < py or my > py + ph then
                    -- also ignore clicks on the display button itself
                    local bx, by = displayBtn:LocalToScreen(0, 0)
                    local bw, bh = displayBtn:GetSize()
                    if not (mx >= bx and mx <= bx+bw and my >= by and my <= by+bh) then
                        CloseDropPanel()
                    end
                end
            end
        end
    end

    container.Close = CloseDropPanel
    return container
end

-- ════════════════════════════════════════════════
--  Themed searchable dropdown with autocomplete
--  multiSelect=true: clicking adds to selectedTable instead of setting entry value
-- ════════════════════════════════════════════════
local function MakeSearchableEntry(parent, x, y, w, getChoices, placeholder, initialVal, onChange, multiSelect, selectedTable)
    local h = 22
    local container = parent:Add("DPanel")
    container:SetPos(x, y) ; container:SetSize(w, h)
    container.Paint = function() end

    local entry = MakeThemedEntry(container, 0, 0, w, h, placeholder, initialVal)
    local dropPanel = nil
    local isOpen = false
    local suppressOnChange = false

    local function CloseDropPanel()
        if IsValid(dropPanel) then dropPanel:Remove() end
        dropPanel = nil ; isOpen = false
    end

    local function IsSelected(val)
        if not multiSelect or not selectedTable then return false end
        for _, v in ipairs(selectedTable) do if v == val then return true end end
        return false
    end

    local function OpenSuggestions(filter)
        CloseDropPanel()
        local choices = getChoices()
        local filtered = {}
        local fl = string.lower(filter)
        for _, c in ipairs(choices) do
            if fl == "" or string.find(string.lower(c), fl, 1, true) then
                table.insert(filtered, c)
            end
        end
        if #filtered == 0 then return end

        local itemH = 22
        local totalH = math.min(#filtered, 6) * itemH
        local sx, sy = container:LocalToScreen(0, h)

        dropPanel = vgui.Create("DPanel")
        dropPanel:SetPos(sx, sy) ; dropPanel:SetSize(w, totalH)
        dropPanel:MakePopup() ; dropPanel:SetKeyboardInputEnabled(false)
        dropPanel.Paint = function(self, pw, ph)
            draw.RoundedBoxEx(4, 0, 0, pw, ph, COL_BTN, false, false, true, true)
            surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, pw, ph, 1)
        end

        local scroll = dropPanel:Add("DScrollPanel")
        scroll:SetPos(0,0) ; scroll:SetSize(w, totalH)
        scroll:GetVBar():SetWide(4)

        for _, choice in ipairs(filtered) do
            local item = scroll:Add("DButton")
            item:SetSize(w, itemH) ; item:SetText("")
            item.Paint = function(self, iw, ih)
                local sel = IsSelected(choice)
                if self:IsHovered() or sel then draw.RoundedBox(0,0,0,iw,ih,COL_BTNHOV) end
                if sel then
                    draw.SimpleText("✓", "DermaDefault", iw - 14, ih/2, COL_GREEN, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                end
                draw.SimpleText(choice, "DermaDefault", 7, ih/2, sel and COL_ACCENT or COL_TEXTPRI, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
            item.DoClick = function()
                if multiSelect and selectedTable then
                    -- toggle in selectedTable
                    local sel = IsSelected(choice)
                    if sel then
                        for i = #selectedTable, 1, -1 do
                            if selectedTable[i] == choice then table.remove(selectedTable, i) end
                        end
                    else
                        table.insert(selectedTable, choice)
                    end
                    if onChange then onChange(selectedTable) end
                    -- keep open for multi-select
                else
                    suppressOnChange = true
                    entry:SetValue(choice)
                    suppressOnChange = false
                    CloseDropPanel()
                    if onChange then onChange(choice) end
                end
            end
        end

        dropPanel.Think = function(self)
            if not IsValid(entry) then CloseDropPanel() ; return end
            if input.IsMouseDown(MOUSE_LEFT) then
                local mx, my = gui.MousePos()
                local px, py = self:GetPos()
                local pw, ph = self:GetSize()
                if mx < px or mx > px + pw or my < py or my > py + ph then
                    CloseDropPanel()
                end
            end
        end
    end

    entry.OnChange = function(self)
        if suppressOnChange then return end
        local val = self:GetValue()
        OpenSuggestions(val)
        if not multiSelect and onChange then onChange(val) end
    end

    entry.OnGetFocus = function(self)
        OpenSuggestions(self:GetValue())
    end

    container.GetEntry = function() return entry end
    return container
end

-- ════════════════════════════════════════════════
--  Confirm popup (used for Save and Delete)
-- ════════════════════════════════════════════════
local function ShowConfirm(msg, onYes)
    if IsValid(_G._KeroConfirm) then _G._KeroConfirm:Remove() end
    local PW, PH = 240, 100
    local p = vgui.Create("DFrame")
    p:SetSize(PW, PH) ; p:Center()
    p:SetTitle("") ; p:SetDraggable(false)
    p:ShowCloseButton(false) ; p:MakePopup() ; p:SetDeleteOnClose(true)
    _G._KeroConfirm = p

    p.Paint = function(self, w, h)
        draw.RoundedBox(8, 0, 0, w, h, COL_BG)
        draw.RoundedBoxEx(8, 0, 0, w, 32, COL_HEADER, true, true, false, false)
        surface.SetDrawColor(COL_BORDER) ; surface.DrawRect(0, 32, w, 1)
        draw.SimpleText("Confirm", "DermaDefaultBold", 10, 16, COL_ACCENT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        draw.SimpleText(msg, "DermaDefault", w/2, 52, COL_TEXTPRI, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    local yesBtn = p:Add("DButton")
    yesBtn:SetPos(20, 68) ; yesBtn:SetSize(90, 24) ; yesBtn:SetText("")
    yesBtn.Paint = function(self, w, h)
        draw.RoundedBox(6, 0, 0, w, h, self:IsHovered() and Color(210,70,70,255) or COL_RED)
        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
        draw.SimpleText("Confirm", "DermaDefaultBold", w/2, h/2, COL_TEXTPRI, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    yesBtn.DoClick = function() p:Remove() ; onYes() end

    local noBtn = p:Add("DButton")
    noBtn:SetPos(130, 68) ; noBtn:SetSize(90, 24) ; noBtn:SetText("")
    noBtn.Paint = function(self, w, h)
        draw.RoundedBox(6, 0, 0, w, h, self:IsHovered() and COL_BTNHOV or COL_BTN)
        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
        draw.SimpleText("Cancel", "DermaDefaultBold", w/2, h/2, COL_TEXTPRI, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    noBtn.DoClick = function() p:Remove() end
end

-- ════════════════════════════════════════════════
--  Colour swatch button (opens colour picker)
-- ════════════════════════════════════════════════
local function MakeColorButton(parent, x, y, getColor, setColor)
    local btn = parent:Add("DButton")
    btn:SetPos(x, y) ; btn:SetSize(18, 18) ; btn:SetText("")
    btn.Paint = function(self, w, h)
        local c = getColor()
        draw.RoundedBox(3, 0, 0, w, h, c)
        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, w, h, 1)
        if self:IsHovered() then
            surface.SetDrawColor(255, 255, 255, 40) ; surface.DrawRect(0, 0, w, h)
        end
    end
    btn.DoClick = function() OpenColorPicker(getColor, setColor) end
    return btn
end

-- ════════════════════════════════════════════════
--  Rainbow toggle button (small "R" pill)
-- ════════════════════════════════════════════════
local function MakeRainbowButton(parent, x, y, getRainbow, setRainbow)
    local btn = parent:Add("DButton")
    btn:SetPos(x, y) ; btn:SetSize(18, 18) ; btn:SetText("")
    btn.Paint = function(self, w, h)
        local on = getRainbow()
        -- draw mini rainbow gradient if on, plain button if off
        if on then
            for i = 0, w - 1 do
                local c = HSVToColor(360 * (i / (w - 1)), 1, 1)
                surface.SetDrawColor(c.r, c.g, c.b, 255)
                surface.DrawRect(i, 0, 1, h)
            end
        else
            draw.RoundedBox(3, 0, 0, w, h, self:IsHovered() and COL_BTNHOV or COL_BTN)
        end
        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, w, h, 1)
        draw.SimpleText("R", "DermaDefault", w/2, h/2,
            on and color_white or COL_TEXTMUT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    btn.DoClick = function() setRainbow(not getRainbow()) end
    return btn
end

-- ════════════════════════════════════════════════
--  Themed slider (fully custom-painted)
-- ════════════════════════════════════════════════
local function CreateSlider(parent, text, x, y, optionKey, tab, min, max)
    min = min or 0 ; max = max or 100
    local saved = options[tab] and options[tab][optionKey]
    local val   = saved ~= nil and saved or min

    local TRACK_H  = 4
    local THUMB_R  = 7
    local TRACK_PAD = THUMB_R + 1
    local LABEL_W  = 76   -- wider label so thumb never clips over the text
    local TRACK_W  = 120
    local NUM_W    = 36
    local TOTAL_W  = LABEL_W + TRACK_W + NUM_W + 8
    local TOTAL_H  = 20

    local container = parent:Add("DPanel")
    container:SetPos(x, y) ; container:SetSize(TOTAL_W, TOTAL_H)
    container.Paint = function() end

    -- Value label (left side) — white text
    local lbl = container:Add("DLabel")
    lbl:SetPos(0, 0) ; lbl:SetSize(LABEL_W, TOTAL_H)
    lbl:SetText(text) ; lbl:SetTextColor(COL_TEXTPRI) ; lbl:SetFont("DermaDefault")
    lbl:SetContentAlignment(6) -- right-align so it butts up to the track

    -- Drag state
    local dragging = false

    -- Track panel (interactive)
    local track = container:Add("DPanel")
    local TX = LABEL_W + 4
    track:SetPos(TX, (TOTAL_H - TRACK_H) / 2 + 1)
    track:SetSize(TRACK_W, TRACK_H + THUMB_R * 2 + 2)
    -- expand hit area vertically so thumb is always clickable
    track:SetPos(TX, 0) ; track:SetSize(TRACK_W, TOTAL_H)

    track.Paint = function(self, w, h)
        local cy = h / 2
        local trackW = math.max(1, w - TRACK_PAD * 2)
        -- Track background
        draw.RoundedBox(2, TRACK_PAD, cy - TRACK_H/2, trackW, TRACK_H, COL_BTN)
        surface.SetDrawColor(COL_BORDER)
        surface.DrawOutlinedRect(TRACK_PAD, cy - TRACK_H/2, trackW, TRACK_H, 1)
        -- Filled portion
        local frac = (val - min) / (max - min)
        local fillW = math.max(0, math.Round(frac * trackW))
        if fillW > 0 then
            draw.RoundedBox(2, TRACK_PAD, cy - TRACK_H/2, fillW, TRACK_H, COL_ACCENT)
        end
        -- Thumb
        local tx = math.Round(TRACK_PAD + frac * trackW)
        draw.RoundedBox(THUMB_R, tx - THUMB_R, cy - THUMB_R, THUMB_R * 2, THUMB_R * 2,
            dragging and COL_ACCENT or COL_TEXTPRI)
    end

    local function UpdateFromMouse()
        local mx, _ = track:CursorPos()
        local frac  = math.Clamp((mx - TRACK_PAD) / math.max(1, TRACK_W - TRACK_PAD * 2), 0, 1)
        val = math.Round(min + frac * (max - min))
        if options[tab] then options[tab][optionKey] = val end
        if container.OnValueChanged then container.OnValueChanged(container, val) end
    end

    track.OnMousePressed  = function(self, mb)
        if mb == MOUSE_LEFT then dragging = true ; UpdateFromMouse() end
    end
    track.OnMouseReleased = function(self, mb)
        if mb == MOUSE_LEFT then dragging = false end
    end
    track.Think = function(self)
        -- Release drag if mouse button is no longer held globally
        -- (catches the case where the cursor leaves the panel while dragging)
        if dragging and not input.IsMouseDown(MOUSE_LEFT) then
            dragging = false
        end
        if dragging then UpdateFromMouse() end
    end

    -- Numeric readout (right side)
    local numLbl = container:Add("DLabel")
    numLbl:SetPos(TX + TRACK_W + 4, 0) ; numLbl:SetSize(NUM_W, TOTAL_H)
    numLbl:SetFont("DermaDefault") ; numLbl:SetContentAlignment(4)

    -- Update numLbl each frame
    local orig = track.Think
    track.Think = function(self)
        if dragging and not input.IsMouseDown(MOUSE_LEFT) then dragging = false end
        if dragging then UpdateFromMouse() end
        numLbl:SetText(tostring(math.Round(val)))
        numLbl:SetTextColor(COL_TEXTPRI)
    end

    container.SetValue = function(self, v)
        val = math.Clamp(math.Round(v), min, max)
        if options[tab] then options[tab][optionKey] = val end
    end
    container.GetValue = function(self) return val end

    return container
end

local function EmitMenuSparks(screenX, screenY, count, col)
    if not IsValid(keroFrame) then return end

    local fx, fy = keroFrame:GetPos()
    local rx = screenX - fx
    local ry = screenY - fy
    if rx < 0 or ry < 0 or rx > keroFrame:GetWide() or ry > keroFrame:GetTall() then return end

    count = count or 6
    col = col or COL_ACCENT

    for _ = 1, count do
        table.insert(_sparks, {
            x = rx,
            y = ry,
            vx = (math.random() - 0.5) * 90,
            vy = -(14 + math.random() * 36),
            life = 0,
            maxLife = 0.2 + math.random() * 0.25,
            size = 1.2 + math.random() * 1.8,
            col = col,
        })
    end

    while #_sparks > 64 do
        table.remove(_sparks, 1)
    end
end

-- ════════════════════════════════════════════════
--  Uniform toggle button
-- ════════════════════════════════════════════════
local function CreateToggleButton(parent, text, x, y, optionKey, tab)
    local btn = vgui.Create("DButton", parent)
    btn:SetPos(x, y) ; btn:SetSize(140, 22) ; btn:SetText("")
    btn.isChecked = (tab and optionKey and options[tab] and options[tab][optionKey]) or false

    btn.Paint = function(self, w, h)
        -- when enabled: amber-tinted background so it pops clearly
        local bgCol = self.isChecked
            and Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 22)
            or  (self:IsHovered() and COL_BTNHOV or COL_BTN)
        draw.RoundedBox(4, 0, 0, w, h, bgCol)
        -- border: accent colour when on, subtle when off
        surface.SetDrawColor(self.isChecked and COL_ACCENT or COL_BORDER)
        surface.DrawOutlinedRect(0, 0, w, h, 1)
        -- pill toggle indicator
        local pilW, pilH = 28, 14
        local px, py = 5, (h - pilH) / 2
        draw.RoundedBox(pilH/2, px, py, pilW, pilH, self.isChecked and Color(COL_GREEN.r, COL_GREEN.g, COL_GREEN.b, 180) or COL_BTN)
        -- knob — no outline box, just a clean circle
        local knobX = self.isChecked and (px + pilW - pilH + 2) or (px + 2)
        draw.RoundedBox(pilH/2 - 2, knobX, py + 2, pilH - 4, pilH - 4,
            self.isChecked and COL_GREEN or COL_TEXTMUT)
        -- label: slightly brighter when enabled
        local tc = self.isChecked and COL_TEXTPRI or Color(160, 162, 166, 255)
        draw.SimpleText(text, "DermaDefault", px + pilW + 6, h/2, tc, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    btn.DoClick = function(self)
        self.isChecked = not self.isChecked
        if tab and optionKey then options[tab][optionKey] = self.isChecked end
        -- Soft tick sound feedback
        if self.isChecked then
            surface.PlaySound("buttons/button15.wav")
        else
            surface.PlaySound("buttons/button15.wav")
        end
        if self.OnToggled then self:OnToggled(self.isChecked) end
    end

    return btn
end

-- ════════════════════════════════════════════════
--  Aimbot key tracking
--  Supports keyboard keys AND mouse buttons 4 & 5
-- ════════════════════════════════════════════════
local aimbotKeyDown = false

-- Mouse button constants (GMod uses these for MOUSE_4 / MOUSE_5)
local MOUSE_BUTTON4 = MOUSE_4 or 107
local MOUSE_BUTTON5 = MOUSE_5 or 108

local function IsAimbotKeyDown()
    local key = options.Combat.Keybind
    if not key then return false end
    -- Check mouse buttons
    if key == MOUSE_BUTTON4 then return input.IsMouseDown(MOUSE_4) end
    if key == MOUSE_BUTTON5 then return input.IsMouseDown(MOUSE_5) end
    -- Regular keyboard key
    return input.IsKeyDown(key)
end

hook.Add("Think", "KeroAimbotKeyTrack", function()
    aimbotKeyDown = IsAimbotKeyDown()
end)

-- ════════════════════════════════════════════════
--  Serialise helpers
-- ════════════════════════════════════════════════
local function ColourToStr(c)
    return math.floor(c.r)..","..math.floor(c.g)..","..math.floor(c.b)..","..math.floor(c.a)
end

local function StrToColour(s)
    local r,g,b,a = string.match(s, "(%d+),(%d+),(%d+),(%d+)")
    if r then return Color(tonumber(r),tonumber(g),tonumber(b),tonumber(a)) end
end

local function SerialiseOptions()
    local lines = {}
    for tab, tbl in pairs(options) do
        for k, v in pairs(tbl) do
            local t = type(v)
            if t == "number" or t == "boolean" or t == "string" then
                table.insert(lines, "OPT|"..tab.."|"..tostring(k).."|"..tostring(v))
            end
        end
    end
    for key, feat in pairs(VisualColors) do
        table.insert(lines, "VCOL|"..key.."|"..ColourToStr(feat.color).."|"..(feat.rainbow and "1" or "0"))
    end
    for key, feat in pairs(MiscColors) do
        table.insert(lines, "MCOL|"..key.."|"..ColourToStr(feat.color).."|"..(feat.rainbow and "1" or "0"))
    end
    for key, feat in pairs(PlayerESPColors) do
        table.insert(lines, "PCOL|"..key.."|"..ColourToStr(feat.color))
    end
    table.insert(lines, "EXTRA|lastTab|"..(currentTab or "Combat"))
    table.insert(lines, "EXTRA|menuKey|"..tostring(menuKey))
    table.insert(lines, "EXTRA|menuKeyName|"..menuKeyName)
    table.insert(lines, "EXTRA|panicKey|"..tostring(panicKey or "nil"))
    table.insert(lines, "EXTRA|panicKeyName|"..panicKeyName)
    for elem, arr in pairs(ESPArrangement) do
        table.insert(lines, "ESPARR|"..elem.."|"..arr.anchor.."|"..tostring(arr.pad).."|"..tostring(arr.slot).."|"..(arr.bold and "1" or "0").."|"..(arr.outline and "1" or "0"))
    end
    table.insert(lines, "EXTRA|combatCheckTargets|"..table.concat(combatCheckTargets, ";;"))
    local suitStr = {}
    for _, v in ipairs(targetedSuitFilters) do table.insert(suitStr, v) end
    table.insert(lines, "EXTRA|targetedSuitFilters|"..table.concat(suitStr, ";;"))
    local worldStr = {}
    for _, v in ipairs(worldESPFilters) do table.insert(worldStr, v) end
    table.insert(lines, "EXTRA|worldESPFilters|"..table.concat(worldStr, ";;"))
    for id, state in pairs(playerStates) do
        table.insert(lines, "PSTATE|"..id.."|"..(state.friend and "1" or "0").."|"..(state.enemy and "1" or "0").."|"..(state.watch and "1" or "0"))
    end
    return table.concat(lines, "\n")
end

local function DeserialiseOptions(str)
    for line in string.gmatch(str, "[^\n]+") do
        local kind = string.match(line, "^([^|]+)")
        if kind == "OPT" then
            local _, tab, k, v = string.match(line, "^([^|]+)|([^|]+)|([^|]+)|(.+)")
            if tab and k and v and options[tab] then
                if     v == "true"  then options[tab][k] = true
                elseif v == "false" then options[tab][k] = false
                elseif tonumber(v)  then options[tab][k] = tonumber(v)
                else                     options[tab][k] = v end
            end
        elseif kind == "VCOL" then
            local _, key, cs, rb = string.match(line, "^([^|]+)|([^|]+)|([^|]+)|(.+)")
            if key and VisualColors[key] then
                local c = StrToColour(cs)
                if c then VisualColors[key].color = c end
                VisualColors[key].rainbow = (rb == "1")
            end
        elseif kind == "MCOL" then
            local _, key, cs, rb = string.match(line, "^([^|]+)|([^|]+)|([^|]+)|(.+)")
            if key and MiscColors[key] then
                local c = StrToColour(cs)
                if c then MiscColors[key].color = c end
                MiscColors[key].rainbow = (rb == "1")
            end
        elseif kind == "PCOL" then
            local _, key, cs = string.match(line, "^([^|]+)|([^|]+)|(.+)")
            if key and PlayerESPColors[key] then
                local c = StrToColour(cs)
                if c then PlayerESPColors[key].color = c end
            end
        elseif kind == "PSTATE" then
            local _, id, friendFlag, enemyFlag, watchFlag = string.match(line, "^([^|]+)|([^|]+)|([^|]+)|([^|]+)|(.+)")
            if id then
                playerStates[id] = {
                    friend = (friendFlag == "1"),
                    enemy  = (enemyFlag == "1"),
                    watch  = (watchFlag == "1"),
                }
                CleanupPlayerState(id)
            end
        elseif kind == "ESPARR" then
            local _, elem, anchor, pad, slot, bold, outline = string.match(line, "^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|?([^|]*)|?(.*)")
            if elem and ESPArrangement[elem] then
                if anchor and anchor ~= "" then ESPArrangement[elem].anchor  = anchor end
                if pad    and pad    ~= "" then ESPArrangement[elem].pad     = tonumber(pad) or ESPArrangement[elem].pad end
                if slot   and slot   ~= "" then ESPArrangement[elem].slot    = tonumber(slot) or ESPArrangement[elem].slot end
                if bold   and bold   ~= "" then ESPArrangement[elem].bold    = (bold == "1") end
                if outline and outline ~= "" then ESPArrangement[elem].outline = (outline == "1") end
            end
        elseif kind == "EXTRA" then
            local _, k, v = string.match(line, "^([^|]+)|([^|]+)|(.+)")
            if k == "lastTab" and v then currentTab = v end
            if k == "menuKey" then
                local ki = tonumber(v)
                if ki then menuKey = ki ; menuKeyName = input.GetKeyName(ki) or tostring(ki) end
            end
            if k == "menuKeyName" and v then menuKeyName = v end
            if k == "panicKey" then
                local ki = tonumber(v)
                if ki then panicKey = ki ; panicKeyName = input.GetKeyName(ki) or tostring(ki)
                else panicKey = nil ; panicKeyName = "NONE" end
            end
            if k == "panicKeyName" and v then panicKeyName = v end
            if k == "combatCheckTargets" then
                combatCheckTargets = {}
                if v and v ~= "" then
                    for part in string.gmatch(v, "([^;][^;]*)") do
                        table.insert(combatCheckTargets, part)
                    end
                    combatCheckTargets = {}
                    local raw = v
                    for part in (raw..";;"):gmatch("(.-);;" ) do
                        if part ~= "" then table.insert(combatCheckTargets, part) end
                    end
                end
                pendingLegacyWatchNames = table.Copy(combatCheckTargets)
                combatCheckTarget = combatCheckTargets[1] or ""
            end
            if k == "targetedSuitFilters" then
                targetedSuitFilters = {}
                if v and v ~= "" then
                    for part in (v..";;"):gmatch("(.-);;" ) do
                        if part ~= "" then table.insert(targetedSuitFilters, part) end
                    end
                end
            end
            if k == "worldESPFilters" then
                worldESPFilters = {}
                if v and v ~= "" then
                    for part in (v..";;"):gmatch("(.-);;" ) do
                        if part ~= "" then table.insert(worldESPFilters, part) end
                    end
                end
            end
            if k == "combatCheckTarget" and #combatCheckTargets == 0 then
                combatCheckTarget = v or ""
                if v and v ~= "" then pendingLegacyWatchNames = {v} end
            end
            if k == "targetedSuitFilter" and #targetedSuitFilters == 0 then
                if v and v ~= "" then targetedSuitFilters = {v} end
            end
        else
            local tab, k, v = string.match(line, "(.+)|(.+)|(.+)")
            if tab and k and v and options[tab] then
                if     v == "true"  then options[tab][k] = true
                elseif v == "false" then options[tab][k] = false
                elseif tonumber(v)  then options[tab][k] = tonumber(v)
                else                     options[tab][k] = v end
            end
        end
    end
    MigrateLegacyCombatTargets()
    RefreshCombatCheckTargets()
    SyncChamsFromOptions()
end

local function GetSavedConfigs()
    local found = {}
    local files, _ = file.Find("kero_*.txt", "DATA")
    if files then
        for _, fname in ipairs(files) do
            local name = string.match(fname, "^kero_(.+)%.txt$")
            if name then table.insert(found, name) end
        end
    end
    return found
end

-- ════════════════════════════════════════════════
--  Menu builder
-- ════════════════════════════════════════════════
-- ════════════════════════════════════════════════
--  Forward-declare so close button inside CreateKeroMenu can call it
-- ════════════════════════════════════════════════
local ToggleKeroMenu  -- defined fully after CreateKeroMenu

-- Forward-declare module-level tab/sidebar builders (defined after CreateKeroMenu to keep
-- their upvalue count independent from CreateKeroMenu's locals).
local UpdateContentPanel
local BuildSidebar
local WireKeroMenu

local function CreateKeroMenu()
    keroFrame = vgui.Create("DFrame")
    keroFrame:SetSize(620, 340)
    keroFrame:SetTitle("")
    keroFrame:SetVisible(true)
    keroFrame:SetDraggable(true)
    keroFrame:ShowCloseButton(false)
    keroFrame:MakePopup()
    keroFrame:Center()

    keroFrame.lblTitle:SetVisible(false)
    keroFrame.btnMaxim:SetVisible(false)
    keroFrame.btnMinim:SetVisible(false)
    keroFrame.btnClose:SetVisible(false)

    -- Reset VFX state for this open
    _vfxTime   = 0
    _sparks    = {}
    _sparkNext = 0
    _tabFlash  = 0


    keroFrame.Paint = function(self, w, h)
        local t = RealTime()
        _vfxTime = t

        -- Outer shadow
        draw.RoundedBox(10, 2, 4, w, h, Color(0,0,0,120))
        -- Body
        draw.RoundedBox(6, 0, 0, w, h, COL_BG)
        -- Header bar
        draw.RoundedBoxEx(6, 0, 0, w, HEADER_H, COL_HEADER, true, true, false, false)

        -- ── Animated shimmer sweep across header ──────────────────────────
        local shimW  = w * 0.35
        local shimX  = ((t * 0.4) % 1.6 - 0.3) * w  -- sweeps left→right every 2.5s
        local shimAlpha = math.max(0, 1 - math.abs(shimX - w/2) / (w * 0.8)) * 18
        if shimAlpha > 0 then
            for i = 0, math.floor(shimW) - 1 do
                local frac = i / (shimW - 1)
                local a = math.Round(shimAlpha * math.sin(frac * math.pi))
                if a > 0 then
                    surface.SetDrawColor(255, 200, 120, a)
                    surface.DrawRect(math.floor(shimX - shimW/2 + i), 0, 1, HEADER_H)
                end
            end
        end

        -- Header bottom edge — animated amber pulse
        local pulse = 0.55 + 0.45 * math.sin(t * 2.8)
        surface.SetDrawColor(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, math.Round(180 + 75 * pulse))
        surface.DrawRect(0, HEADER_H - 1, w, 1)
        -- Subtle glow line just above footer
        local footGlow = 0.4 + 0.3 * math.sin(t * 1.5 + 1.2)
        surface.SetDrawColor(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, math.Round(25 * footGlow))
        surface.DrawRect(SIDEBAR_W + 1, h - FOOTER_H - 1, w - SIDEBAR_W - 1, 1)

        -- ── Spark particles along the accent line ─────────────────────────
        if t > _sparkNext then
            _sparkNext = t + 0.12 + math.random() * 0.18
            local sx = SIDEBAR_W + math.random() * (w - SIDEBAR_W)
            table.insert(_sparks, {
                x = sx, y = HEADER_H - 1,
                vx = (math.random() - 0.5) * 28,
                vy = -(6 + math.random() * 14),
                life = 0, maxLife = 0.45 + math.random() * 0.35,
                size = 2 + math.random() * 3,
            })
            if #_sparks > 24 then table.remove(_sparks, 1) end
        end

        -- Advance spark physics (draw happens in PaintOver so sparks appear above child panels)
        local dt = FrameTime()
        for i = #_sparks, 1, -1 do
            local sp = _sparks[i]
            sp.life = sp.life + dt
            if sp.life >= sp.maxLife then
                table.remove(_sparks, i)
            else
                sp.x = sp.x + sp.vx * dt
                sp.y = sp.y + sp.vy * dt
                sp.vy = sp.vy + 38 * dt  -- gravity
            end
        end

        -- Title
        surface.SetTextColor(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 255)
        surface.SetFont("DermaDefaultBold")
        surface.SetTextPos(14, 11)
        surface.DrawText("KEROSENE")
        surface.SetTextColor(COL_TEXTMUT.r, COL_TEXTMUT.g, COL_TEXTMUT.b, 255)
        surface.SetFont("DermaDefault")
        surface.SetTextPos(92, 12)
        surface.DrawText(KERO_VERSION)
        -- Sidebar divider
        surface.SetDrawColor(COL_BORDER)
        surface.DrawRect(SIDEBAR_W, HEADER_H, 1, h - HEADER_H - FOOTER_H)

        -- ── Tab-switch flash: diagonal amber gradient top-left → bottom-right ─
        if _tabFlash > 0 then
            _tabFlash = math.max(0, _tabFlash - dt * 4.5)
            local baseAlpha = _tabFlash * _tabFlash * 60
            if baseAlpha > 0.5 then
                local cx = SIDEBAR_W + 1
                local cy = HEADER_H
                local cw = w - SIDEBAR_W - 1
                local ch = h - HEADER_H - FOOTER_H
                -- Draw diagonal band sweep: slice content area into vertical strips
                -- and vary alpha by how far each strip is along the diagonal
                local diagLen = cw + ch  -- length of diagonal in pixels
                local stripW  = 4
                for sx = 0, cw - 1, stripW do
                    -- diagonal progress: top-left corner = 0, bottom-right = 1
                    -- for each column, average with vertical centre
                    local diag = (sx / cw + 0.5) / 2  -- simplified diagonal frac
                    -- The sweep front travels from 0→1 as flash decays
                    local front = 1 - _tabFlash
                    local dist  = math.abs(diag - front)
                    local band  = math.max(0, 1 - dist * 6)
                    local fa    = math.Round(band * baseAlpha)
                    if fa > 0 then
                        surface.SetDrawColor(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, fa)
                        surface.DrawRect(cx + sx, cy, math.min(stripW, cw - sx), ch)
                    end
                end
            end
        end

        -- Footer
        surface.SetDrawColor(COL_HEADER.r, COL_HEADER.g, COL_HEADER.b, 255)
        surface.DrawRect(0, h - FOOTER_H, w, FOOTER_H)
        surface.SetDrawColor(COL_BORDER)
        surface.DrawRect(0, h - FOOTER_H, w, 1)
        draw.SimpleText("by Wobble", "DermaDefault", 10, h - FOOTER_H + 5, COL_TEXTMUT, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end

    -- Draw sparks in PaintOver so they render above all child panels (content, sidebar, etc.)
    keroFrame.PaintOver = function(self, w, h)
        for _, sp in ipairs(_sparks) do
            local frac = 1 - (sp.life / sp.maxLife)
            local a    = math.Round(frac * frac * 200)
            local sz   = math.max(1, math.Round(sp.size * frac))
            local sc   = sp.col or COL_ACCENT
            surface.SetDrawColor(sc.r, sc.g, sc.b, a)
            surface.DrawRect(math.Round(sp.x - sz/2), math.Round(sp.y - sz/2), sz, sz)
        end
    end

    buttonPanel = vgui.Create("DPanel", keroFrame)
    buttonPanel:SetSize(SIDEBAR_W - 1, WIN_H - HEADER_H - FOOTER_H)
    buttonPanel:SetPos(0, HEADER_H)
    buttonPanel.Paint = function() end

    contentPanel = vgui.Create("DPanel", keroFrame)
    contentPanel:SetSize(WIN_W - SIDEBAR_W - 1, WIN_H - HEADER_H - FOOTER_H)
    contentPanel:SetPos(SIDEBAR_W + 1, HEADER_H)
    contentPanel.Paint = function(self, w, h)
        -- content area is just the base bg colour, no extra box
    end

    -- UpdateContentPanel, BuildSidebar, and WireKeroMenu are defined at module level
    -- below CreateKeroMenu to avoid exceeding Lua's 60-upvalue limit on this function.
    UpdateContentPanel(contentPanel)
    WireKeroMenu()
end -- end CreateKeroMenu

-- ════════════════════════════════════════════════
--  Tab content builder  (module-level — avoids >60 upvalue limit)
-- ════════════════════════════════════════════════
local TABS = { "Combat", "Visuals", "Misc", "Players", "Debug", "Config" }

UpdateContentPanel = function(panel)
        panel:Clear()
        local pW = panel:GetWide()
        -- ══ COMBAT ═══════════════════════════════
        if currentTab == "Combat" then

            local aimbotBtn  = CreateToggleButton(panel, "Aimbot",   10,  10, "CombatOption1", "Combat")
            local drawFovBtn = CreateToggleButton(panel, "Draw FOV", 215, 10, "CombatOption4", "Combat")

            -- FOV slider is ALWAYS visible — draw fov only controls whether circle renders
            local fovSizeSlider = CreateSlider(panel, "FOV Size", 183, 38, "CombatOption5", "Combat", 5, 180)

            -- Custom themed FOV colour swatch + rainbow, placed to the right of Draw FOV toggle
            if not options.Combat.FOVColorData then
                options.Combat.FOVColorData = { color = options.Combat.FOVColor or Color(200,200,200,255), rainbow = false }
            end
            local fovColorData = options.Combat.FOVColorData

            local fovColorBtn = MakeColorButton(panel, 408, 13,
                function() return fovColorData.color end,
                function(c) fovColorData.color = c ; options.Combat.FOVColor = c end)

            local fovRainbowBtn = MakeRainbowButton(panel, 434, 13,
                function() return fovColorData.rainbow end,
                function(v) fovColorData.rainbow = v end)

            -- Remove Recoil and Remove Spread sit below Draw FOV + size slider
            local removeRecoilBtn = CreateToggleButton(panel, "Remove Recoil", 215, 66, "MiscOption1", "Misc")
            removeRecoilBtn:SetVisible(true)
            local removeSpreadBtn = CreateToggleButton(panel, "Remove Spread",  215, 96, "MiscOption2", "Misc")
            removeSpreadBtn:SetVisible(true)

            drawFovBtn.OnToggled = function(self, state)
                -- colour/rainbow buttons always visible; nothing to hide
            end

            local hitChanceSlider = CreateSlider(panel, "Hit Chance (%)", 10, 128, "CombatOption2", "Combat")
            hitChanceSlider:SetVisible(aimbotBtn.isChecked and options.Combat.CameraSilentMode == "Silent")

            local smoothingSlider = CreateSlider(panel, "Smoothing", -13, 128, "CombatOption3", "Combat", 0, 100)
            smoothingSlider:SetVisible(aimbotBtn.isChecked and options.Combat.CameraSilentMode == "Camera")

            local methodDD = MakeThemedDropdown(panel, 10, 68, 140,
                {"Camera", "Silent"},
                options.Combat.CameraSilentMode or "Camera",
                function(val)
                    options.Combat.CameraSilentMode = val
                    smoothingSlider:SetVisible(aimbotBtn.isChecked and val == "Camera")
                    hitChanceSlider:SetVisible(aimbotBtn.isChecked and val == "Silent")
                end)
            methodDD:SetVisible(aimbotBtn.isChecked)

            local bodyDD = MakeThemedDropdown(panel, 10, 98, 140,
                {"Lower Torso", "Torso", "Head", "Random"},
                options.Combat.TargetMode or "Torso",
                function(val) options.Combat.TargetMode = val end)
            bodyDD:SetVisible(aimbotBtn.isChecked)

            local function GetKeybindName(key)
                if not key then return "None" end
                if key == MOUSE_BUTTON4 then return "Mouse4" end
                if key == MOUSE_BUTTON5 then return "Mouse5" end
                return input.GetKeyName(key) or tostring(key)
            end

            local function SetKeybind(key)
                options.Combat.Keybind = key
            end

            local aimbotBindListening = false
            local keybindButton = vgui.Create("DButton", panel)
            keybindButton:SetPos(10, 38) ; keybindButton:SetSize(140, 20) ; keybindButton:SetText("")
            keybindButton:SetVisible(aimbotBtn.isChecked)
            keybindButton.Paint = function(self, w, h)
                local bg = aimbotBindListening and Color(130,45,45,255) or (self:IsHovered() and COL_BTNHOV or COL_BTN)
                draw.RoundedBox(4, 0, 0, w, h, bg)
                surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
                local txt = aimbotBindListening and "Press a key..." or GetKeybindName(options.Combat.Keybind)
                local tc  = aimbotBindListening and Color(255,190,190,255) or COL_TEXTPRI
                draw.SimpleText(txt, "DermaDefault", w/2, h/2, tc, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
            keybindButton.DoClick = function()
                if aimbotBindListening then return end
                aimbotBindListening = true
            end

            local kbThink = panel:Add("DPanel")
            kbThink:SetSize(0,0) ; kbThink.Paint = function() end
            local kbIgnore = {
                [KEY_LSHIFT]=true,[KEY_RSHIFT]=true,[KEY_LALT]=true,[KEY_RALT]=true,
                [KEY_LCONTROL]=true,[KEY_RCONTROL]=true,[KEY_LWIN]=true,[KEY_RWIN]=true,
            }
            kbThink.Think = function()
                if not aimbotBindListening then return end
                -- Check mouse buttons first
                if input.IsMouseDown(MOUSE_4) then
                    SetKeybind(MOUSE_BUTTON4) ; aimbotBindListening = false ; return
                end
                if input.IsMouseDown(MOUSE_5) then
                    SetKeybind(MOUSE_BUTTON5) ; aimbotBindListening = false ; return
                end
                -- Then keyboard keys
                for k = 0, 159 do
                    if not kbIgnore[k] and input.IsKeyDown(k) then
                        SetKeybind(k) ; aimbotBindListening = false ; return
                    end
                end
            end

            aimbotBtn.OnToggled = function(self, state)
                methodDD:SetVisible(state) ; bodyDD:SetVisible(state)
                keybindButton:SetVisible(state)
                local mode = options.Combat.CameraSilentMode
                hitChanceSlider:SetVisible(state and mode == "Silent")
                smoothingSlider:SetVisible(state and mode == "Camera")
            end

        -- ══ VISUALS ══════════════════════════════
        elseif currentTab == "Visuals" then

            local colorKeys = { "Name","Boxes","Money","Weapon","Distance","WorldESP","SuitName","SuitHealth" }

            for i, optionName in ipairs(optionNames.Visuals) do
                local optionKey = "VisualsOption" .. i
                options.Visuals[optionKey] = options.Visuals[optionKey] or false
                local yPos = 10 + (i - 1) * 30
                local togBtn = CreateToggleButton(panel, optionName, 10, yPos, optionKey, "Visuals")

                if optionName == "Name" then
                    local nd = MakeThemedDropdown(panel, 160, yPos, 100,
                        {"Steam Name", "In-Game Name"},
                        options.Visuals.NameType or "Steam Name",
                        function(val) options.Visuals.NameType = val end)
                    nd:SetVisible(togBtn.isChecked)
                    togBtn.OnToggled = function(self, state) nd:SetVisible(state) end
                end

                if optionName == "Boxes" then
                    local boxDD = MakeThemedDropdown(panel, 160, yPos, 100,
                        {"2D Boxes", "3D Boxes"},
                        options.Visuals.BoxType or "2D Boxes",
                        function(val) options.Visuals.BoxType = val end)
                    boxDD:SetVisible(togBtn.isChecked)
                    togBtn.OnToggled = function(self, state) boxDD:SetVisible(state) end
                end

                if optionName == "World ESP" then
                    -- Multi-select dropdown of all entity classes currently in the server
                    -- with an inline search bar — same style as the Targeted Suits dropdown.
                    local function GetAllEntityClasses()
                        local seen = {} ; local classes = {}
                        for _, ent in ipairs(ents.GetAll()) do
                            if IsValid(ent) and not ent:IsPlayer() then
                                local cls = ent:GetClass()
                                if not seen[cls] then
                                    seen[cls] = true
                                    table.insert(classes, cls)
                                end
                            end
                        end
                        table.sort(classes)
                        return classes
                    end

                    local function WorldESPLabel()
                        if #worldESPFilters == 0 then return "All entities" end
                        if #worldESPFilters == 1 then return worldESPFilters[1] end
                        return worldESPFilters[1] .. " (+" .. (#worldESPFilters - 1) .. ")"
                    end

                    local wespDD = panel:Add("DPanel")
                    wespDD:SetPos(160, yPos) ; wespDD:SetSize(200, 22)
                    wespDD.Paint = function() end

                    local wespIsOpen    = false
                    local wespDropPanel = nil

                    local wespBtn = wespDD:Add("DButton")
                    wespBtn:SetPos(0, 0) ; wespBtn:SetSize(200, 22) ; wespBtn:SetText("")
                    wespBtn.Paint = function(self, bw, bh)
                        draw.RoundedBox(4, 0, 0, bw, bh, self:IsHovered() and COL_BTNHOV or COL_BTN)
                        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, bw, bh, 1)
                        draw.SimpleText(WorldESPLabel(), "DermaDefault", 7, bh/2, COL_TEXTPRI, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                        local ax = bw - 12
                        surface.SetDrawColor(COL_TEXTMUT)
                        surface.DrawRect(ax,     bh/2 - 1, 6, 1)
                        surface.DrawRect(ax + 1, bh/2 + 1, 4, 1)
                        surface.DrawRect(ax + 2, bh/2 + 3, 2, 1)
                    end

                    local function CloseWESPDrop()
                        if IsValid(wespDropPanel) then wespDropPanel:Remove() end
                        wespDropPanel = nil ; wespIsOpen = false
                    end

                    local function OpenWESPDrop()
                        CloseWESPDrop()
                        wespIsOpen = true

                        local allClasses = GetAllEntityClasses()
                        local SEARCH_H   = 24
                        local ITEM_H     = 22
                        local VISIBLE    = math.min(math.max(#allClasses, 1), 6)
                        local DROP_W     = 200
                        local DROP_H     = SEARCH_H + VISIBLE * ITEM_H
                        local sx, sy     = wespDD:LocalToScreen(0, 22)

                        wespDropPanel = vgui.Create("EditablePanel", nil)
                        wespDropPanel:SetPos(sx, sy) ; wespDropPanel:SetSize(DROP_W, DROP_H)
                        wespDropPanel:SetZPos(32767) ; wespDropPanel:MakePopup()
                        wespDropPanel:SetKeyboardInputEnabled(true)
                        wespDropPanel:SetMouseInputEnabled(true)
                        wespDropPanel:MoveToFront()

                        wespDropPanel.Paint = function(self, pw, ph)
                            draw.RoundedBoxEx(4, 0, 0, pw, ph, COL_BTN, false, false, true, true)
                            surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, pw, ph, 1)
                        end

                        local searchEntry = MakeThemedEntry(wespDropPanel, 2, 2, DROP_W - 4, SEARCH_H - 4, "Search...")
                        searchEntry:SetUpdateOnType(true)
                        timer.Simple(0, function()
                            if IsValid(searchEntry) then searchEntry:RequestFocus() end
                        end)

                        -- Scrollable item list
                        local scroll = wespDropPanel:Add("DScrollPanel")
                        scroll:SetPos(0, SEARCH_H) ; scroll:SetSize(DROP_W, VISIBLE * ITEM_H)
                        local vbar = scroll:GetVBar()
                        vbar:SetWide(4)
                        vbar.Paint = function(s, w, h) draw.RoundedBox(2, 0, 0, w, h, COL_BTN) end
                        vbar.btnGrip.Paint = function(s, w, h) draw.RoundedBox(2, 0, 0, w, h, COL_ACCENT) end

                        local layout = scroll:Add("DListLayout")
                        layout:SetWide(DROP_W)

                        local function RebuildItems(filter)
                            layout:Clear()
                            local fl = string.lower(filter or "")
                            local filtered = {}
                            for _, cls in ipairs(allClasses) do
                                if fl == "" or string.find(string.lower(cls), fl, 1, true) then
                                    table.insert(filtered, cls)
                                end
                            end
                            for _, cls in ipairs(filtered) do
                                local row = layout:Add("DButton")
                                row:SetSize(DROP_W, ITEM_H) ; row:SetText("")
                                row.isSel = false
                                for _, f in ipairs(worldESPFilters) do
                                    if f == cls then row.isSel = true ; break end
                                end
                                row.Paint = function(self, iw, ih)
                                    if self:IsHovered() or self.isSel then
                                        draw.RoundedBox(0, 0, 0, iw, ih, COL_BTNHOV)
                                    end
                                    if self.isSel then
                                        draw.SimpleText("✓", "DermaDefault", iw - 14, ih/2, COL_GREEN, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                                    end
                                    draw.SimpleText(cls, "DermaDefault", 7, ih/2, self.isSel and COL_ACCENT or COL_TEXTPRI, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                                end
                                row.DoClick = function()
                                    local found = false
                                    for i2 = #worldESPFilters, 1, -1 do
                                        if worldESPFilters[i2] == cls then
                                            table.remove(worldESPFilters, i2) ; found = true
                                        end
                                    end
                                    if not found then table.insert(worldESPFilters, cls) end
                                    row.isSel = not found
                                end
                            end
                        end

                        RebuildItems("")
                        local function UpdateWorldESPSearch(self, val)
                            RebuildItems(val or self:GetValue())
                        end
                        searchEntry.OnChange = UpdateWorldESPSearch
                        searchEntry.OnValueChange = UpdateWorldESPSearch

                        wespDropPanel.Think = function(self)
                            if not IsValid(wespBtn) then CloseWESPDrop() ; return end
                            if input.IsMouseDown(MOUSE_LEFT) then
                                local mx, my = gui.MousePos()
                                local px, py = self:GetPos() ; local pw, ph = self:GetSize()
                                if mx < px or mx > px + pw or my < py or my > py + ph then
                                    local bx, by = wespBtn:LocalToScreen(0, 0)
                                    local bw, bh = wespBtn:GetSize()
                                    if not (mx >= bx and mx <= bx+bw and my >= by and my <= by+bh) then
                                        CloseWESPDrop()
                                    end
                                end
                            end
                        end
                    end

                    wespBtn.DoClick = function()
                        if wespIsOpen then CloseWESPDrop() else OpenWESPDrop() end
                    end

                    wespDD:SetVisible(togBtn.isChecked)
                    togBtn.OnToggled = function(self, state)
                        wespDD:SetVisible(state)
                        if not state then CloseWESPDrop() end
                    end
                end

                local ck = colorKeys[i]
                if ck and VisualColors[ck] then
                    MakeRainbowButton(panel, pW - 40, yPos + 4,
                        function() return VisualColors[ck].rainbow end,
                        function(v) VisualColors[ck].rainbow = v  end)
                    MakeColorButton(panel, pW - 66, yPos + 4,
                        function() return VisualColors[ck].color end,
                        function(c) VisualColors[ck].color = c    end)
                end
            end

            -- Bottom controls: ESP Placement below Suit Health (row 8 = y 220+8px gap)
            -- Distance slider sits to the right of the ESP Placement button on same row
            local ESP_BTN_Y = 10 + 8 * 30  -- row after the 8 toggle rows (y=250)
            local espArrBtn = vgui.Create("DButton", panel)
            espArrBtn:SetPos(10, ESP_BTN_Y) ; espArrBtn:SetSize(140, 22) ; espArrBtn:SetText("")
            espArrBtn.Paint = function(self, w, h)
                draw.RoundedBox(4, 0, 0, w, h, self:IsHovered() and COL_BTNHOV or COL_BTN)
                surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, w, h, 1)
                draw.SimpleText("ESP Placement", "DermaDefault", w/2, h/2, COL_TEXTPRI, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
            espArrBtn.DoClick = function() OpenESPArrangementMenu() end

            -- Distance slider to the right of ESP Placement on the same row
            CreateSlider(panel, "Distance", 160, ESP_BTN_Y, "DisplayDistance", "Visuals", 0, 10000)

        -- ══ MISC ═════════════════════════════════
        elseif currentTab == "Misc" then

            local y = 10

            -- ── Arm Chams ───────────────────────
            local armMatDD  -- forward-declare so OnToggled closure can reference it
            local armBtn = CreateToggleButton(panel, "Arm Chams", 10, y, "ArmChams", "Misc")
            armBtn.isChecked = miscChams.ArmChams
            armBtn.OnToggled = function(self, state)
                miscChams.ArmChams = state
                options.Misc.ArmChams = state
                if IsValid(armMatDD) then armMatDD:SetVisible(state) end
            end
            MakeRainbowButton(panel, pW - 40, y + 1,
                function() return MiscColors.ArmChams.rainbow end,
                function(v) MiscColors.ArmChams.rainbow = v  end)
            MakeColorButton(panel, pW - 66, y + 1,
                function() return MiscColors.ArmChams.color end,
                function(c) MiscColors.ArmChams.color = c    end)
            armMatDD = MakeThemedDropdown(panel, 158, y, 100,
                {"Flat", "Normal", "Wireframe"},
                options.Misc.ArmChamsMaterial or "Flat",
                function(val) options.Misc.ArmChamsMaterial = val end)
            armMatDD:SetVisible(miscChams.ArmChams)
            y = y + 30

            -- ── Weapon Chams ────────────────────
            local wepMatDD  -- forward-declare so OnToggled closure can reference it
            local wepBtn = CreateToggleButton(panel, "Weapon Chams", 10, y, "WeaponChams", "Misc")
            wepBtn.isChecked = miscChams.WeaponChams
            wepBtn.OnToggled = function(self, state)
                miscChams.WeaponChams = state
                options.Misc.WeaponChams = state
                if IsValid(wepMatDD) then wepMatDD:SetVisible(state) end
            end
            MakeRainbowButton(panel, pW - 40, y + 1,
                function() return MiscColors.WeaponChams.rainbow end,
                function(v) MiscColors.WeaponChams.rainbow = v  end)
            MakeColorButton(panel, pW - 66, y + 1,
                function() return MiscColors.WeaponChams.color end,
                function(c) MiscColors.WeaponChams.color = c    end)
            wepMatDD = MakeThemedDropdown(panel, 158, y, 100,
                {"Flat", "Normal", "Wireframe"},
                options.Misc.WeaponChamsMaterial or "Flat",
                function(val) options.Misc.WeaponChamsMaterial = val end)
            wepMatDD:SetVisible(miscChams.WeaponChams)
            y = y + 30

            -- ── Hitsound ────────────────────────
            local HITSOUND_OPTIONS = {
                { label = "Bop",    sound = "buttons/button14.wav" },
                { label = "Bubble", sound = "ambient/water/drip1.wav" },
                { label = "Beep",   sound = "buttons/button15.wav" },
                { label = "Ding",   sound = "buttons/button17.wav" },
                { label = "Click",  sound = "buttons/button9.wav" },
            }
            local hitsoundLabels = {}
            for _, o in ipairs(HITSOUND_OPTIONS) do table.insert(hitsoundLabels, o.label) end

            -- Default HitsoundEnabled to false if not set, but preserve existing non-"Off" label
            if options.Misc.HitsoundEnabled == nil then
                options.Misc.HitsoundEnabled = (options.Misc.HitsoundLabel ~= nil and options.Misc.HitsoundLabel ~= "Off")
            end

            local hsToggleBtn = CreateToggleButton(panel, "Hitsound", 10, y, "HitsoundEnabled", "Misc")

            local hsDropdown = MakeThemedDropdown(panel, 158, y, 100,
                hitsoundLabels,
                (options.Misc.HitsoundLabel ~= nil and options.Misc.HitsoundLabel ~= "Off") and options.Misc.HitsoundLabel or hitsoundLabels[1],
                function(val)
                    options.Misc.HitsoundLabel = val
                    for _, o in ipairs(HITSOUND_OPTIONS) do
                        if o.label == val then options.Misc.HitsoundSound = o.sound ; break end
                    end
                end)
            hsDropdown:SetVisible(hsToggleBtn.isChecked)

            hsToggleBtn.OnToggled = function(self, state)
                hsDropdown:SetVisible(state)
                if not state then
                    options.Misc.HitsoundLabel = "Off"
                    options.Misc.HitsoundSound = nil
                else
                    local lbl = options.Misc.HitsoundLabel
                    if not lbl or lbl == "Off" then lbl = hitsoundLabels[1] end
                    options.Misc.HitsoundLabel = lbl
                    for _, o in ipairs(HITSOUND_OPTIONS) do
                        if o.label == lbl then options.Misc.HitsoundSound = o.sound ; break end
                    end
                end
            end
            y = y + 30

            -- ── Remove Camo ─────────────────────
            local fullbrightBtn = CreateToggleButton(panel, "Fullbright", 10, y, "Fullbright", "Misc")
            y = y + 30
            local removeCamoBtn = vgui.Create("DButton", panel)
            removeCamoBtn:SetPos(10, y) ; removeCamoBtn:SetSize(140, 22) ; removeCamoBtn:SetText("")
            removeCamoBtn.Paint = function(self, w, h)
                draw.RoundedBox(4, 0, 0, w, h, self:IsHovered() and COL_BTNHOV or COL_BTN)
                surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0, 0, w, h, 1)
                draw.SimpleText("Remove Camo", "DermaDefault", w/2, h/2, COL_TEXTPRI, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
            removeCamoBtn.DoClick = function()
                hook.Remove("RenderScreenspaceEffects", "ShowCamoEffects")
            end
            y = y + 30

            -- ── Aspect Ratio (stretch slider) ────
            CreateSlider(panel, "Aspect Ratio", -5, y, "AspectStretch", "Misc", 0, 100)
            y = y + 30

            -- ── FOV Changer ─────────────────────
            CreateSlider(panel, "FOV Changer", 0, y, "CustomFOV", "Misc", 60, 120)

        -- ══ CONFIG ═══════════════════════════════
        elseif currentTab == "Players" then

            MigrateLegacyCombatTargets()
            RefreshCombatCheckTargets()

            local friendLbl = vgui.Create("DLabel", panel)
            friendLbl:SetPos(10, 12) ; friendLbl:SetFont("DermaDefaultBold")
            friendLbl:SetText("Friend ESP") ; friendLbl:SetTextColor(COL_TEXTPRI) ; friendLbl:SizeToContents()
            MakeColorButton(panel, 96, 10,
                function() return PlayerESPColors.Friend.color end,
                function(c) PlayerESPColors.Friend.color = c end)

            local enemyLbl = vgui.Create("DLabel", panel)
            enemyLbl:SetPos(136, 12) ; enemyLbl:SetFont("DermaDefaultBold")
            enemyLbl:SetText("Enemy ESP") ; enemyLbl:SetTextColor(COL_TEXTPRI) ; enemyLbl:SizeToContents()
            MakeColorButton(panel, 220, 10,
                function() return PlayerESPColors.Enemy.color end,
                function(c) PlayerESPColors.Enemy.color = c end)

            local infoLbl = vgui.Create("DLabel", panel)
            infoLbl:SetPos(260, 8) ; infoLbl:SetFont("DermaDefault")
            infoLbl:SetText("Friend blocks aimbot, Enemy prioritises.")
            infoLbl:SetTextColor(COL_TEXTMUT) ; infoLbl:SizeToContents()

            local infoLbl2 = vgui.Create("DLabel", panel)
            infoLbl2:SetPos(260, 20) ; infoLbl2:SetFont("DermaDefault")
            infoLbl2:SetText("Watch feeds combat check.")
            infoLbl2:SetTextColor(COL_TEXTMUT) ; infoLbl2:SizeToContents()

            local scroll = panel:Add("DScrollPanel")
            scroll:SetPos(10, 40) ; scroll:SetSize(pW - 20, panel:GetTall() - 50)
            scroll:GetVBar():SetWide(4)

            local players = {}
            for _, ply in ipairs(player.GetAll()) do
                if IsValid(ply) and ply ~= LocalPlayer() then
                    table.insert(players, ply)
                end
            end
            table.sort(players, function(a, b)
                return string.lower(a:Nick()) < string.lower(b:Nick())
            end)

            local function AddStateButton(row, id, flag, text, x)
                local btn = row:Add("DButton")
                btn:SetPos(x, 3) ; btn:SetSize(56, 22) ; btn:SetText("")
                btn.Paint = function(self, w, h)
                    local state = playerStates[id] or {}
                    local enabled = state[flag] or false
                    local bg = enabled and Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 36) or (self:IsHovered() and COL_BTNHOV or COL_BTN)
                    draw.RoundedBox(4, 0, 0, w, h, bg)
                    surface.SetDrawColor(enabled and COL_ACCENT or COL_BORDER)
                    surface.DrawOutlinedRect(0, 0, w, h, 1)
                    draw.SimpleText(text, "DermaDefault", w / 2, h / 2, enabled and COL_ACCENT or COL_TEXTPRI, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                end
                btn.DoClick = function()
                    local state = playerStates[id] or {}
                    SetPlayerFlag(id, flag, not state[flag])
                end
            end

            for _, ply in ipairs(players) do
                local id = GetPlayerStateID(ply)
                local row = scroll:Add("DPanel")
                row:Dock(TOP)
                row:DockMargin(0, 0, 0, 4)
                row:SetTall(28)
                row.Paint = function(self, w, h)
                    draw.RoundedBox(4, 0, 0, w, h, COL_BTN)
                    surface.SetDrawColor(COL_BORDER)
                    surface.DrawOutlinedRect(0, 0, w, h, 1)
                    local nameCol = COL_TEXTPRI
                    if PlayerHasFlag(ply, "friend") then
                        local c = PlayerESPColors.Friend.color
                        nameCol = Color(c.r, c.g, c.b, 255)
                    elseif PlayerHasFlag(ply, "enemy") then
                        local c = PlayerESPColors.Enemy.color
                        nameCol = Color(c.r, c.g, c.b, 255)
                    end
                    -- Show server nickname bold, then (Steam name) muted
                    local nick      = ply:Nick()
                    local steamName = ply.GetFriendName and ply:GetFriendName() or ""
                    if steamName == "" or steamName == nick then
                        steamName = ply:SteamID() or ""
                    end
                    draw.SimpleText(nick, "DermaDefaultBold", 8, h / 2, nameCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                    local nickW = surface.GetTextSize and (function()
                        surface.SetFont("DermaDefaultBold")
                        local tw = select(1, surface.GetTextSize(nick))
                        return tw
                    end)() or (#nick * 7)
                    if steamName ~= "" then
                        draw.SimpleText(" (" .. steamName .. ")", "DermaDefault", 8 + nickW, h / 2, COL_TEXTMUT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                    end
                end
                AddStateButton(row, id, "friend", "Friend", pW - 212)
                AddStateButton(row, id, "enemy", "Enemy", pW - 150)
                AddStateButton(row, id, "watch", "Watch", pW - 88)
            end

        elseif currentTab == "Config" then

            local y = 14

            -- MENU KEYBINDS
            local hdr1 = vgui.Create("DLabel", panel)
            hdr1:SetPos(14, y) ; hdr1:SetFont("DermaDefaultBold")
            hdr1:SetText("MENU KEYBINDS") ; hdr1:SetTextColor(COL_ACCENT) ; hdr1:SizeToContents()
            y = y + 20

            local div1 = vgui.Create("DPanel", panel)
            div1:SetPos(14, y) ; div1:SetSize(pW - 28, 1)
            div1.Paint = function(s,w,h) surface.SetDrawColor(COL_BORDER) ; surface.DrawRect(0,0,w,h) end
            y = y + 10

            -- ── Menu Key row ──────────────────────────────
            local menuLbl = vgui.Create("DLabel", panel)
            menuLbl:SetPos(14, y + 6) ; menuLbl:SetFont("DermaDefault")
            menuLbl:SetText("Menu:") ; menuLbl:SetTextColor(COL_TEXTMUT) ; menuLbl:SizeToContents()

            local bindBtn = vgui.Create("DButton", panel)
            bindBtn:SetPos(56, y) ; bindBtn:SetSize(130, 26) ; bindBtn:SetText("")
            bindBtn.Paint = function(self, w, h)
                local bg = bindListening and Color(130,45,45,255) or (self:IsHovered() and COL_BTNHOV or COL_BTN)
                draw.RoundedBox(6, 0, 0, w, h, bg)
                surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
                local txt = bindListening and "Press any key..." or menuKeyName
                local tc  = bindListening and Color(255,190,190,255) or COL_TEXTPRI
                draw.SimpleText(txt,"DermaDefaultBold",w/2,h/2,tc,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
            end
            bindBtn.DoClick = function() if not bindListening then bindListening = true ; panicListening = false end end

            local thinkPnl = panel:Add("DPanel")
            thinkPnl:SetSize(0,0) ; thinkPnl.Paint = function() end
            thinkPnl.Think = function()
                if not bindListening then return end
                local ignore = {
                    [KEY_LSHIFT]=true,[KEY_RSHIFT]=true,[KEY_LALT]=true,[KEY_RALT]=true,
                    [KEY_LCONTROL]=true,[KEY_RCONTROL]=true,
                }
                for k = 0, 159 do
                    if not ignore[k] and input.IsKeyDown(k) then
                        menuKey = k ; menuKeyName = input.GetKeyName(k) or tostring(k)
                        bindListening = false ; return
                    end
                end
            end

            local resetMenuBtn = vgui.Create("DButton", panel)
            resetMenuBtn:SetPos(194, y) ; resetMenuBtn:SetSize(110, 26) ; resetMenuBtn:SetText("")
            resetMenuBtn.Paint = function(self, w, h)
                draw.RoundedBox(6, 0, 0, w, h, self:IsHovered() and COL_BTNHOV or COL_BTN)
                surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
                draw.SimpleText("Reset to INSERT","DermaDefault",w/2,h/2,COL_TEXTMUT,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
            end
            resetMenuBtn.DoClick = function() menuKey = KEY_INSERT ; menuKeyName = "INSERT" ; bindListening = false end
            y = y + 34

            -- ── Panic Key row ─────────────────────────────
            local panicLbl = vgui.Create("DLabel", panel)
            panicLbl:SetPos(14, y + 6) ; panicLbl:SetFont("DermaDefault")
            panicLbl:SetText("Panic:") ; panicLbl:SetTextColor(COL_TEXTMUT) ; panicLbl:SizeToContents()

            local panicBtn = vgui.Create("DButton", panel)
            panicBtn:SetPos(56, y) ; panicBtn:SetSize(130, 26) ; panicBtn:SetText("")
            panicBtn.Paint = function(self, w, h)
                local bg = panicListening and Color(130,45,45,255) or (self:IsHovered() and COL_BTNHOV or COL_BTN)
                draw.RoundedBox(6, 0, 0, w, h, bg)
                surface.SetDrawColor(panicMode and Color(200,80,30,200) or COL_BORDER)
                surface.DrawOutlinedRect(0,0,w,h,1)
                local txt = panicListening and "Press any key..." or (panicMode and ("PANIC: "..panicKeyName) or panicKeyName)
                local tc  = panicListening and Color(255,190,190,255) or (panicMode and Color(255,160,80,255) or COL_TEXTPRI)
                draw.SimpleText(txt,"DermaDefaultBold",w/2,h/2,tc,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
            end
            panicBtn.DoClick = function() if not panicListening then panicListening = true ; bindListening = false end end

            local panicThinkPnl = panel:Add("DPanel")
            panicThinkPnl:SetSize(0,0) ; panicThinkPnl.Paint = function() end
            panicThinkPnl.Think = function()
                if not panicListening then return end
                local ignore = {
                    [KEY_LSHIFT]=true,[KEY_RSHIFT]=true,[KEY_LALT]=true,[KEY_RALT]=true,
                    [KEY_LCONTROL]=true,[KEY_RCONTROL]=true,
                }
                for k = 0, 159 do
                    if not ignore[k] and input.IsKeyDown(k) then
                        panicKey = k ; panicKeyName = input.GetKeyName(k) or tostring(k)
                        panicListening = false ; return
                    end
                end
            end

            local resetPanicBtn = vgui.Create("DButton", panel)
            resetPanicBtn:SetPos(194, y) ; resetPanicBtn:SetSize(110, 26) ; resetPanicBtn:SetText("")
            resetPanicBtn.Paint = function(self, w, h)
                draw.RoundedBox(6, 0, 0, w, h, self:IsHovered() and COL_BTNHOV or COL_BTN)
                surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
                draw.SimpleText("Clear","DermaDefault",w/2,h/2,COL_TEXTMUT,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
            end
            resetPanicBtn.DoClick = function()
                panicKey = nil ; panicKeyName = "NONE"
                panicListening = false
                -- If currently panicking, restore hooks
                if panicMode then
                    for name, data in pairs(_panicSavedHooks) do
                        hook.Add(data.event, name, data.fn)
                    end
                    _panicSavedHooks = {}
                    panicMode = false
                end
            end

            -- Hint label
            local panicHint = vgui.Create("DLabel", panel)
            panicHint:SetPos(312, y + 6) ; panicHint:SetFont("DermaDefault")
            panicHint:SetText("Hides all visuals without unloading") ; panicHint:SetTextColor(COL_TEXTMUT) ; panicHint:SizeToContents()
            y = y + 34

            -- PROFILES
            local hdr2 = vgui.Create("DLabel", panel)
            hdr2:SetPos(14, y) ; hdr2:SetFont("DermaDefaultBold")
            hdr2:SetText("PROFILES") ; hdr2:SetTextColor(COL_ACCENT) ; hdr2:SizeToContents()
            y = y + 20

            local div2 = vgui.Create("DPanel", panel)
            div2:SetPos(14, y) ; div2:SetSize(pW - 28, 1)
            div2.Paint = function(s,w,h) surface.SetDrawColor(COL_BORDER) ; surface.DrawRect(0,0,w,h) end
            y = y + 10

            -- Themed profile name entry
            local profileEntry = MakeThemedEntry(panel, 14, y, 160, 24, "Profile name...", options.Config.LastProfileName or "default")

            -- Saved configs dropdown
            local savedCfgs = GetSavedConfigs()
            local cfgChoices = {}
            for _, n in ipairs(savedCfgs) do table.insert(cfgChoices, n) end

            local configDropdownY = y

            local configDropdown = MakeThemedDropdown(panel, 182, configDropdownY, 150,
                cfgChoices,
                "Saved configs...",
                function(val) profileEntry:SetValue(val) end)

            y = y + 34

            local function RefreshDropdown()
                if IsValid(configDropdown) then configDropdown:Remove() end
                local newCfgs = GetSavedConfigs()
                local newChoices = {}
                for _, n in ipairs(newCfgs) do table.insert(newChoices, n) end
                configDropdown = MakeThemedDropdown(panel, 182, configDropdownY, 150,
                    newChoices,
                    "Saved configs...",
                    function(val) profileEntry:SetValue(val) end)
            end

            local function MakeProfileBtn(lbl, xOff, bw, col, clk)
                local b = vgui.Create("DButton", panel)
                b:SetPos(14 + xOff, y) ; b:SetSize(bw or 72, 28) ; b:SetText("")
                local baseCol = col or COL_BTN
                b.Paint = function(self, w, h)
                    local bg = self:IsHovered() and Color(
                        math.min(baseCol.r+25,255),
                        math.min(baseCol.g+25,255),
                        math.min(baseCol.b+25,255), 255
                    ) or baseCol
                    draw.RoundedBox(6, 0, 0, w, h, bg)
                    surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
                    draw.SimpleText(lbl,"DermaDefaultBold",w/2,h/2,COL_TEXTPRI,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
                end
                b.DoClick = clk
                return b
            end

            MakeProfileBtn("Create", 0, 72, COL_BTN, function()
                local name = profileEntry:GetValue()
                if name == "" then name = "default" end
                options.Config.LastProfileName = name
                file.Write("kero_" .. name .. ".txt", SerialiseOptions())
                chat.AddText(COL_TEXTPRI, "[Kero] Profile '" .. name .. "' created.")
                RefreshDropdown()
            end)

            -- Save requires confirm
            MakeProfileBtn("Save", 78, 72, COL_BTN, function()
                local name = profileEntry:GetValue()
                if name == "" then name = "default" end
                ShowConfirm("Save '" .. name .. "'?", function()
                    options.Config.LastProfileName = name
                    file.Write("kero_" .. name .. ".txt", SerialiseOptions())
                    chat.AddText(COL_TEXTPRI, "[Kero] Profile '" .. name .. "' saved.")
                    RefreshDropdown()
                end)
            end)

            MakeProfileBtn("Load", 156, 72, COL_BTN, function()
                local name = profileEntry:GetValue()
                if name == "" then name = "default" end
                local data = file.Read("kero_" .. name .. ".txt", "DATA")
                if data then
                    DeserialiseOptions(data)
                    chat.AddText(COL_TEXTPRI, "[Kero] Profile '" .. name .. "' loaded.")
                else
                    chat.AddText(Color(200,100,100), "[Kero] Profile '" .. name .. "' not found.")
                end
            end)

            -- Delete requires confirm
            MakeProfileBtn("Delete", 234, 72, COL_RED, function()
                local name = profileEntry:GetValue()
                if name == "" then return end
                ShowConfirm("Delete '" .. name .. "'?", function()
                    local path = "kero_" .. name .. ".txt"
                    if file.Exists(path, "DATA") then
                        file.Delete(path)
                        chat.AddText(Color(200,100,100), "[Kero] Profile '" .. name .. "' deleted.")
                        profileEntry:SetValue("")
                        RefreshDropdown()
                    else
                        chat.AddText(Color(200,100,100), "[Kero] Profile '" .. name .. "' not found.")
                    end
                end)
            end)

            -- Unload — nukes all hooks, removes menu, script goes dark
            MakeProfileBtn("Unload", 312, 72, Color(100, 40, 40, 255), function()
                ShowConfirm("Unload Kerosene?", function()
                    -- Kill the menu
                    if IsValid(keroFrame) then keroFrame:Remove() end
                    isMenuOpen = false

                    -- Restore any NW strings that were blocked during this session
                    if _G._KeroDebugState then
                        local DS = _G._KeroDebugState
                        for key, blocked in pairs(DS.nwBlocked) do
                            if blocked then
                                for _, ent in ipairs(player.GetAll()) do
                                    if IsValid(ent) then
                                        pcall(function() ent:SetNWString(key, nil) end)
                                    end
                                end
                            end
                        end
                        DS.nwBlocked = {}
                    end

                    -- Remove every hook we registered
                    local hookNames = {
                        "KeroAimbotKeyTrack",
                        "KeroAimbotThink",
                        "ToggleKeroMenu",
                        "KeroFOVCircle",
                        "KeroHueAdvance",
                        "KeroDisplayNames",
                        "KeroDraw2DBoxes",
                        "KeroDrawMoney",
                        "KeroDrawWeapon",
                        "KeroDrawDistance",
                        "KeroDrawWorldESP",
                        "KeroWeaponChams",
                        "KeroArmChams",
                        "KeroNoRecoil",
                        "KeroNoSpread",
                        "KeroCameraAimbot",
                        "KeroCombatCheckShoot",
                        "KeroCombatCheckDamage",
                        "KeroCombatCheckHUD",
                        "KeroCombatCheckHPPoll",
                        "KeroDrawSuitName",
                        "KeroDrawSuitHealth",
                        "KeroHitsound",
                        "KeroFullbrightThink",
                        "KeroFullbright",
                        "KeroFOVChange",
                        "KeroAspectRatio",
                    }
                    for _, name in ipairs(hookNames) do
                        hook.Remove("Think",                    name)
                        hook.Remove("HUDPaint",                 name)
                        hook.Remove("CreateMove",               name)
                        hook.Remove("CalcView",                 name)
                        hook.Remove("PreRender",                name)
                        hook.Remove("PostRender",               name)
                        hook.Remove("EntityFireBullets",        name)
                        hook.Remove("EntityTakeDamage",         name)
                        hook.Remove("PreDrawViewModel",         name)
                        hook.Remove("PostDrawViewModel",        name)
                        hook.Remove("RenderScreenspaceEffects", name)
                    end

                    -- Reset chams so the viewmodel doesn't stay tinted
                    render.SetColorModulation(1, 1, 1)
                    render.SetBlend(1)
                    render.MaterialOverride()
                    -- Reset fullbright inline (ApplyFullbrightState is defined later in scope)
                    RunConsoleCommand("r_shadows", "1")
                    RunConsoleCommand("mat_fullbright", "0")
                    keroFullbrightApplied = false

                    -- Nuke console so Kerosene output is cleared
                    NukeConsole()

                    -- Disarm the menu toggle so INSERT never re-opens it
                    menuKey = nil
                end)
            end)

            y = y + 44

            -- TARGETED SUITS
            local hdr3 = vgui.Create("DLabel", panel)
            hdr3:SetPos(14, y) ; hdr3:SetFont("DermaDefaultBold")
            hdr3:SetText("TARGETED SUITS") ; hdr3:SetTextColor(COL_ACCENT) ; hdr3:SizeToContents()
            y = y + 20

            local div3 = vgui.Create("DPanel", panel)
            div3:SetPos(14, y) ; div3:SetSize(pW - 28, 1)
            div3.Paint = function(s,w,h) surface.SetDrawColor(COL_BORDER) ; surface.DrawRect(0,0,w,h) end
            y = y + 10

            -- Build a selectedDisplayNames table synced to targetedSuitFilters
            local selectedDisplayNames = {}
            for _, actual in ipairs(targetedSuitFilters) do
                for disp, act in pairs(SUIT_ACTUAL) do
                    if act == actual then
                        table.insert(selectedDisplayNames, disp)
                        break
                    end
                end
            end

            local suitChoices = {}
            for _, disp in ipairs(SUIT_DISPLAY) do table.insert(suitChoices, disp) end

            local function SuitLabel()
                if #selectedDisplayNames == 0 then return "All Suits" end
                if #selectedDisplayNames == 1 then return selectedDisplayNames[1] end
                return selectedDisplayNames[1] .. " (+" .. (#selectedDisplayNames - 1) .. ")"
            end

            MakeMultiSelectDropdown(panel, 14, y, 200,
                suitChoices,
                selectedDisplayNames,
                function(val, nowSelected)
                    -- Rebuild targetedSuitFilters from selectedDisplayNames
                    targetedSuitFilters = {}
                    for _, disp in ipairs(selectedDisplayNames) do
                        local actual = SUIT_ACTUAL[disp]
                        if actual then table.insert(targetedSuitFilters, actual) end
                    end
                    -- Ensure PassesSuitFilter uses the updated list immediately
                end,
                SuitLabel)

            local suitHint = vgui.Create("DLabel", panel)
            suitHint:SetPos(222, y + 4) ; suitHint:SetFont("DermaDefault")
            suitHint:SetText("Filter ESP by suit (multi)")
            suitHint:SetTextColor(COL_TEXTMUT) ; suitHint:SizeToContents()

        -- ══ DEBUG ═════════════════════════════════
        elseif currentTab == "Debug" then

            if not _G._KeroDebugState then
                _G._KeroDebugState = {
                    nwLog        = {},
                    nwSeen       = {},
                    nwBlocked    = {},
                    hookScan     = {},
                    hookScanned  = false,
                    removedHooks = {},
                }
            end
            local DS = _G._KeroDebugState

            local function DebugHeader(parent, x, y2, w2, text)
                local lbl = vgui.Create("DLabel", parent)
                lbl:SetPos(x, y2) ; lbl:SetFont("DermaDefaultBold")
                lbl:SetText(text) ; lbl:SetTextColor(COL_ACCENT) ; lbl:SizeToContents()
                local div = vgui.Create("DPanel", parent)
                div:SetPos(x, y2 + 16) ; div:SetSize(w2, 1)
                div.Paint = function(s,w,h) surface.SetDrawColor(COL_BORDER) ; surface.DrawRect(0,0,w,h) end
                return y2 + 22
            end

            local function DebugBtn(parent, x, y2, w, h, text, col, onClick)
                local b = parent:Add("DButton")
                b:SetPos(x, y2) ; b:SetSize(w, h) ; b:SetText("")
                local bc = col or COL_BTN
                b.Paint = function(self, bw, bh)
                    local bg = self:IsHovered() and Color(math.min(bc.r+20,255), math.min(bc.g+20,255), math.min(bc.b+20,255), 255) or bc
                    draw.RoundedBox(4, 0, 0, bw, bh, bg)
                    surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,bw,bh,1)
                    draw.SimpleText(text, "DermaDefault", bw/2, bh/2, COL_TEXTPRI, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                end
                b.DoClick = onClick
                return b
            end

            local FULL_W    = pW - 16
            local SECTION_X = 8
            local PANEL_H   = panel:GetTall()
            local TOP_H     = math.floor((PANEL_H - 16) * 0.52)
            local BOT_Y     = TOP_H + 8
            local BTN_W     = 46
            local BTN_GAP   = 3

            -- ════════════════════════════════════
            --  TOP: NW String Logger
            -- ════════════════════════════════════
            local gy = 4
            gy = DebugHeader(panel, SECTION_X, gy, FULL_W, "NW STRING LOGGER")

            DebugBtn(panel, SECTION_X, gy, 72, 20, "Scan Now", COL_BTN, function()
                DS.nwLog  = {}
                DS.nwSeen = {}
                for _, ply in ipairs(player.GetAll()) do
                    if not IsValid(ply) then continue end
                    local ok, vars = pcall(function() return ply:GetNetworkVars() end)
                    if ok and istable(vars) then
                        for k, v in pairs(vars) do
                            local ukey = ply:SteamID64() .. "." .. tostring(k)
                            if not DS.nwSeen[ukey] then
                                DS.nwSeen[ukey] = true
                                table.insert(DS.nwLog, { key=tostring(k), val=tostring(v), owner=ply:Nick(), time=os.date("%H:%M:%S") })
                            end
                        end
                    end
                    local knownKeys = { "ActiveSuit","SuitHealth","SuitMaxHealth","job","salary","rank","gang","gangrank","group","usergroup","rpname","rpjob","DarkRPVars" }
                    for _, k in ipairs(knownKeys) do
                        local sv = ply:GetNWString(k, "\0")
                        if sv ~= "\0" then
                            local ukey = ply:SteamID64() .. "." .. k
                            if not DS.nwSeen[ukey] then
                                DS.nwSeen[ukey] = true
                                table.insert(DS.nwLog, { key=k, val=sv, owner=ply:Nick(), time=os.date("%H:%M:%S") })
                            end
                        end
                    end
                end
                for _, ent in ipairs(ents.GetAll()) do
                    if not IsValid(ent) or ent:IsPlayer() then continue end
                    local ok2, vars2 = pcall(function() return ent:GetNetworkVars() end)
                    if ok2 and istable(vars2) then
                        for k, v in pairs(vars2) do
                            local ukey = ent:GetClass().."["..ent:EntIndex().."]."..tostring(k)
                            if not DS.nwSeen[ukey] then
                                DS.nwSeen[ukey] = true
                                table.insert(DS.nwLog, { key=tostring(k), val=tostring(v), owner=ent:GetClass().." #"..ent:EntIndex(), time=os.date("%H:%M:%S") })
                            end
                        end
                    end
                end
            end)

            DebugBtn(panel, SECTION_X + 78, gy, 52, 20, "Clear", Color(80,35,35,255), function()
                DS.nwLog  = {}
                DS.nwSeen = {}
            end)

            gy = gy + 26

            local nwScroll = panel:Add("DScrollPanel")
            nwScroll:SetPos(SECTION_X, gy) ; nwScroll:SetSize(FULL_W, TOP_H - gy - 2)
            nwScroll:GetVBar():SetWide(4)
            local nwVbar = nwScroll:GetVBar()
            nwVbar.Paint         = function(s,w,h) draw.RoundedBox(2,0,0,w,h,COL_BTN) end
            nwVbar.btnGrip.Paint = function(s,w,h) draw.RoundedBox(2,0,0,w,h,COL_ACCENT) end
            nwVbar.btnUp.Paint   = function() end
            nwVbar.btnDown.Paint = function() end

            local nwLayout = nwScroll:Add("DListLayout")
            local NW_ROW_W = FULL_W - 6
            nwLayout:SetWide(NW_ROW_W)

            local nwLastCount = -1
            local nwThink = panel:Add("DPanel")
            nwThink:SetSize(0,0) ; nwThink.Paint = function() end
            nwThink.Think = function()
                if #DS.nwLog == nwLastCount then return end
                nwLastCount = #DS.nwLog
                nwLayout:Clear()
                for _, entry in ipairs(DS.nwLog) do
                    local rowH = 36
                    local row  = nwLayout:Add("DPanel")
                    row:SetSize(NW_ROW_W, rowH)
                    local isBlocked = DS.nwBlocked[entry.key] or false

                    row.Paint = function(self, w, h)
                        draw.RoundedBox(4, 0, 0, w, h, isBlocked and Color(50,20,20,200) or Color(20,21,24,200))
                        surface.SetDrawColor(isBlocked and Color(120,40,40,255) or COL_BORDER)
                        surface.DrawOutlinedRect(0,0,w,h,1)
                        draw.SimpleText(entry.key, "DermaDefaultBold", 6, h/2 - 6, isBlocked and Color(180,60,60,255) or COL_ACCENT, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
                        draw.SimpleText(entry.owner .. "  " .. entry.time, "DermaDefault", 6, h/2 + 4, COL_TEXTMUT, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
                        local btnsW = (BTN_W + BTN_GAP) * 3 + 4
                        local maxChars = math.floor((w - 140 - btnsW) / 6)
                        local valStr = tostring(entry.val)
                        if #valStr > maxChars then valStr = string.sub(valStr, 1, maxChars - 3) .. "..." end
                        draw.SimpleText(valStr, "DermaDefault", 140, h/2 - 6, COL_TEXTPRI, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
                    end

                    local bY   = (rowH - 18) / 2
                    local b3X  = NW_ROW_W - BTN_W - 2
                    local b2X  = b3X - BTN_W - BTN_GAP
                    local b1X  = b2X - BTN_W - BTN_GAP

                    local copyBtn = row:Add("DButton")
                    copyBtn:SetPos(b1X, bY) ; copyBtn:SetSize(BTN_W, 18) ; copyBtn:SetText("")
                    copyBtn.Paint = function(self, w, h)
                        draw.RoundedBox(3,0,0,w,h, self:IsHovered() and COL_BTNHOV or COL_BTN)
                        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
                        draw.SimpleText("Copy","DermaDefault",w/2,h/2,COL_TEXTPRI,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
                    end
                    copyBtn.DoClick = function()
                        SetClipboardText(entry.key .. " = " .. entry.val)
                        surface.PlaySound("buttons/button14.wav")
                    end

                    local runBtn = row:Add("DButton")
                    runBtn:SetPos(b2X, bY) ; runBtn:SetSize(BTN_W, 18) ; runBtn:SetText("")
                    runBtn.Paint = function(self, w, h)
                        draw.RoundedBox(3,0,0,w,h, self:IsHovered() and Color(30,60,30,255) or COL_BTN)
                        surface.SetDrawColor(self:IsHovered() and Color(60,140,60,255) or COL_BORDER)
                        surface.DrawOutlinedRect(0,0,w,h,1)
                        draw.SimpleText("Run","DermaDefault",w/2,h/2, self:IsHovered() and Color(120,220,120,255) or COL_TEXTPRI, TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
                    end
                    runBtn.DoClick = function()
                        local fn, err = loadstring(entry.val)
                        if fn then
                            local ok2, runErr = pcall(fn)
                            if not ok2 then
                                chat.AddText(Color(220,80,80), "[Kero Debug] Run error: ", color_white, tostring(runErr))
                            else
                                chat.AddText(Color(80,200,80), "[Kero Debug] Ran: ", color_white, entry.key)
                                surface.PlaySound("buttons/button14.wav")
                            end
                        else
                            chat.AddText(Color(220,80,80), "[Kero Debug] Not runnable: ", color_white, tostring(err or "not valid Lua"))
                        end
                    end

                    local blockBtn = row:Add("DButton")
                    blockBtn:SetPos(b3X, bY) ; blockBtn:SetSize(BTN_W, 18) ; blockBtn:SetText("")
                    blockBtn.Paint = function(self, w, h)
                        local on = DS.nwBlocked[entry.key]
                        draw.RoundedBox(3,0,0,w,h, on and Color(60,20,20,255) or (self:IsHovered() and COL_BTNHOV or COL_BTN))
                        surface.SetDrawColor(on and Color(160,50,50,255) or COL_BORDER)
                        surface.DrawOutlinedRect(0,0,w,h,1)
                        draw.SimpleText(on and "Unblock" or "Block","DermaDefault",w/2,h/2, on and Color(220,100,100,255) or COL_TEXTPRI, TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
                    end
                    blockBtn.DoClick = function()
                        DS.nwBlocked[entry.key] = not DS.nwBlocked[entry.key]
                        isBlocked = DS.nwBlocked[entry.key] or false
                        if DS.nwBlocked[entry.key] then
                            for _, ent in ipairs(player.GetAll()) do
                                if IsValid(ent) then pcall(function() ent:SetNWString(entry.key, "") end) end
                            end
                        else
                            for _, ent in ipairs(player.GetAll()) do
                                if IsValid(ent) then pcall(function() ent:SetNWString(entry.key, entry.val) end) end
                            end
                        end
                        surface.PlaySound("buttons/button15.wav")
                        nwLastCount = -1
                    end
                end
            end

            -- ════════════════════════════════════
            --  BOTTOM: Hook Scanner
            -- ════════════════════════════════════
            local secDiv = panel:Add("DPanel")
            secDiv:SetPos(SECTION_X, BOT_Y - 4) ; secDiv:SetSize(FULL_W, 1)
            secDiv.Paint = function(s,w,h) surface.SetDrawColor(COL_BORDER) ; surface.DrawRect(0,0,w,h) end

            local hy = BOT_Y + 2
            hy = DebugHeader(panel, SECTION_X, hy, FULL_W, "SERVER HOOK SCANNER")

            DebugBtn(panel, SECTION_X, hy, 72, 20, "Scan Hooks", COL_BTN, function()
                DS.hookScan    = {}
                DS.hookScanned = true
                local hooktbl = hook.GetTable()
                local serverIndicators = {
                    "net","net_","ply","player","server","sv_","_sv",
                    "darkrp","drp","pointshop","ps","ulx","ulib",
                    "sam","fadmin","evolve","xadmin","serverguard",
                    "bans","kick","mute","gag","jail",
                    "log","logging","monitor","tracker","detect",
                    "admin","staff","mod","sa","ga",
                }
                local knownKero = {
                    KeroAimbotKeyTrack=true, KeroAimbotThink=true, ToggleKeroMenu=true,
                    KeroPanicKeyThink=true, KeroFOVCircle=true, KeroHueAdvance=true,
                    KeroDisplayNames=true, KeroDraw2DBoxes=true, KeroDrawMoney=true,
                    KeroDrawWeapon=true, KeroDrawDistance=true, KeroDrawWorldESP=true,
                    KeroWeaponChams=true, KeroArmChams=true, KeroNoRecoil=true,
                    KeroNoSpread=true, KeroCameraAimbot=true, KeroCombatCheckShoot=true,
                    KeroCombatCheckDamage=true, KeroCombatCheckHUD=true,
                    KeroCombatCheckHPPoll=true, KeroDrawSuitName=true,
                    KeroDrawSuitHealth=true, KeroHitsound=true, KeroFullbrightThink=true,
                    KeroFullbright=true, KeroFOVChange=true, KeroAspectRatio=true,
                    KeroWhitelistBoot=true,
                }
                for event, hooks in pairs(hooktbl) do
                    for name, fn in pairs(hooks) do
                        if knownKero[name] then continue end
                        local info = debug and debug.getinfo and debug.getinfo(fn, "S")
                        local src  = info and info.source or "?"
                        local short = src:match("([^/\\]+)$") or src
                        local suspicious = false
                        local nameLow = string.lower(tostring(name))
                        local srcLow  = string.lower(short)
                        for _, ind in ipairs(serverIndicators) do
                            if string.find(nameLow, ind, 1, true) or string.find(srcLow, ind, 1, true) then
                                suspicious = true ; break
                            end
                        end
                        table.insert(DS.hookScan, {
                            event=event, name=tostring(name),
                            source=short, suspicious=suspicious, fn=fn,
                        })
                    end
                end
                table.sort(DS.hookScan, function(a, b)
                    if a.suspicious ~= b.suspicious then return a.suspicious end
                    return a.event < b.event
                end)
            end)

            DebugBtn(panel, SECTION_X + 78, hy, 52, 20, "Clear", Color(80,35,35,255), function()
                DS.hookScan    = {}
                DS.hookScanned = false
            end)

            hy = hy + 26

            local hkScroll = panel:Add("DScrollPanel")
            hkScroll:SetPos(SECTION_X, hy) ; hkScroll:SetSize(FULL_W, PANEL_H - hy - 4)
            hkScroll:GetVBar():SetWide(4)
            local hkVbar = hkScroll:GetVBar()
            hkVbar.Paint         = function(s,w,h) draw.RoundedBox(2,0,0,w,h,COL_BTN) end
            hkVbar.btnGrip.Paint = function(s,w,h) draw.RoundedBox(2,0,0,w,h,COL_ACCENT) end
            hkVbar.btnUp.Paint   = function() end
            hkVbar.btnDown.Paint = function() end

            local hkLayout = hkScroll:Add("DListLayout")
            local HK_ROW_W = FULL_W - 6
            hkLayout:SetWide(HK_ROW_W)

            local hkLastCount = -1
            local hkThink = panel:Add("DPanel")
            hkThink:SetSize(0,0) ; hkThink.Paint = function() end
            hkThink.Think = function()
                if #DS.hookScan == hkLastCount then return end
                hkLastCount = #DS.hookScan
                hkLayout:Clear()

                if not DS.hookScanned then
                    local ph = hkLayout:Add("DPanel")
                    ph:SetSize(HK_ROW_W, 30)
                    ph.Paint = function(self,w,h)
                        draw.SimpleText("Press 'Scan Hooks' to analyse all active hooks.", "DermaDefault",
                            w/2, h/2, COL_TEXTMUT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    end
                    return
                end

                for _, entry in ipairs(DS.hookScan) do
                    local rowH = 36
                    local row  = hkLayout:Add("DPanel")
                    row:SetSize(HK_ROW_W, rowH)
                    row.Paint = function(self, w, h)
                        draw.RoundedBox(4, 0, 0, w, h, entry.suspicious and Color(50,25,15,220) or Color(20,21,24,200))
                        surface.SetDrawColor(entry.suspicious and Color(200,100,40,200) or COL_BORDER)
                        surface.DrawOutlinedRect(0,0,w,h,1)
                        if entry.suspicious then
                            draw.RoundedBox(3, 110, (h-14)/2, 50, 14, Color(200,80,30,200))
                            draw.SimpleText("SUSPECT","DermaDefault", 135, h/2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                        end
                        draw.SimpleText(entry.name, "DermaDefaultBold", 6, h/2 - 6, entry.suspicious and Color(230,150,60,255) or COL_TEXTPRI, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
                        local meta = "Event: " .. entry.event .. "   Src: " .. (entry.source or "?")
                        draw.SimpleText(meta, "DermaDefault", 6, h/2 + 4, COL_TEXTMUT, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
                    end

                    local bY2   = (rowH - 18) / 2
                    local hkB2X = HK_ROW_W - BTN_W - 2
                    local hkB1X = hkB2X - BTN_W - BTN_GAP

                    local hkCopy = row:Add("DButton")
                    hkCopy:SetPos(hkB1X, bY2) ; hkCopy:SetSize(BTN_W, 18) ; hkCopy:SetText("")
                    hkCopy.Paint = function(self,w,h)
                        draw.RoundedBox(3,0,0,w,h, self:IsHovered() and COL_BTNHOV or COL_BTN)
                        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
                        draw.SimpleText("Copy","DermaDefault",w/2,h/2,COL_TEXTPRI,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
                    end
                    hkCopy.DoClick = function()
                        SetClipboardText("[Hook] " .. entry.name .. " | " .. entry.event .. " | " .. (entry.source or "?"))
                        surface.PlaySound("buttons/button14.wav")
                    end

                    local hkRemove = row:Add("DButton")
                    hkRemove:SetPos(hkB2X, bY2) ; hkRemove:SetSize(BTN_W, 18) ; hkRemove:SetText("")
                    hkRemove.Paint = function(self,w,h)
                        draw.RoundedBox(3,0,0,w,h, self:IsHovered() and Color(100,35,35,255) or COL_BTN)
                        surface.SetDrawColor(COL_BORDER) ; surface.DrawOutlinedRect(0,0,w,h,1)
                        draw.SimpleText("Remove","DermaDefault",w/2,h/2, self:IsHovered() and Color(255,160,160,255) or COL_TEXTPRI, TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
                    end
                    hkRemove.DoClick = function()
                        table.insert(DS.removedHooks, { event=entry.event, name=entry.name, fn=entry.fn })
                        hook.Remove(entry.event, entry.name)
                        surface.PlaySound("buttons/button15.wav")
                        for i2 = #DS.hookScan, 1, -1 do
                            if DS.hookScan[i2].name == entry.name and DS.hookScan[i2].event == entry.event then
                                table.remove(DS.hookScan, i2)
                            end
                        end
                        hkLastCount = -1
                    end
                end
            end
        end
end -- end UpdateContentPanel

-- ════════════════════════════════════════════════
--  Sidebar builder  (module-level)
-- ════════════════════════════════════════════════
BuildSidebar = function()
    buttonPanel:Clear()
    local bW = SIDEBAR_W - 1
    local bH = 36
    for i, tabName in ipairs(TABS) do
        local by = (i - 1) * (bH + 2) + 8
        local btn = vgui.Create("DButton", buttonPanel)
        btn:SetPos(0, by) ; btn:SetSize(bW, bH) ; btn:SetText("")
        btn.Paint = function(self, w, h)
            local active = (currentTab == tabName)
            local hov    = self:IsHovered()
            if active then
                draw.RoundedBoxEx(4, 0, 0, w, h, COL_BTNHOV, false, false, false, false)
                surface.SetDrawColor(COL_ACCENT)
                surface.DrawRect(0, 0, 2, h)
            elseif hov then
                draw.RoundedBox(4, 0, 0, w, h, COL_BTN)
            end
            local tc = active and COL_TEXTPRI or (hov and COL_TEXTPRI or COL_TEXTMUT)
            draw.SimpleText(tabName, "DermaDefault", 14, h/2, tc, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
        btn.DoClick = function()
            if currentTab == tabName then return end
            surface.PlaySound("buttons/lightswitch2.wav")
            _tabFlash = 1.0
            tabFadeTarget = tabName
            tabFading = true
        end
    end
end

-- ════════════════════════════════════════════════
--  Wire up sidebar + fade driver  (called at end of CreateKeroMenu)
-- ════════════════════════════════════════════════
WireKeroMenu = function()
    BuildSidebar()

    -- Tab-fade Think driver
    local fadeDriver = vgui.Create("DPanel", keroFrame)
    fadeDriver:SetSize(0, 0) ; fadeDriver.Paint = function() end
    local wasLeftMouseDown = false
    fadeDriver.Think = function()
        local mouseDown = input.IsMouseDown(MOUSE_LEFT)
        if mouseDown and not wasLeftMouseDown and IsValid(keroFrame) then
            local mx, my = gui.MousePos()
            local fx, fy = keroFrame:GetPos()
            if mx >= fx and mx <= fx + keroFrame:GetWide() and my >= fy and my <= fy + keroFrame:GetTall() then
                EmitMenuSparks(mx, my, 6, COL_ACCENT)
            end
        end
        wasLeftMouseDown = mouseDown

        if not IsValid(contentPanel) then return end
        if tabFading then
            tabAlpha = math.max(0, tabAlpha - 25)
            contentPanel:SetAlpha(tabAlpha)
            if tabAlpha == 0 and tabFadeTarget then
                currentTab = tabFadeTarget
                tabFadeTarget = nil
                UpdateContentPanel(contentPanel)
                BuildSidebar()
                tabFading = false
            end
        elseif tabAlpha < 255 then
            tabAlpha = math.min(255, tabAlpha + 25)
            contentPanel:SetAlpha(tabAlpha)
        end
    end
end

-- ════════════════════════════════════════════════
--  Menu toggle
-- ════════════════════════════════════════════════
function ToggleKeroMenu()
    if isMenuOpen then
        -- Close any external sub-menus first
        if IsValid(_G._KeroColorPicker) then _G._KeroColorPicker:Remove() end
        if IsValid(_G._KeroESPArrange)  then _G._KeroESPArrange:Remove()  end
        if IsValid(keroFrame) then keroFrame:Remove() end
        isMenuOpen = false
    else
        CreateKeroMenu()
        isMenuOpen = true
    end
end

local wasMenuKeyDown = false
hook.Add("Think", "ToggleKeroMenu", function()
    if not menuKey then return end  -- unloaded
    if bindListening then wasMenuKeyDown = false ; return end
    local down = input.IsKeyDown(menuKey)
    if down and not wasMenuKeyDown then ToggleKeroMenu() end
    wasMenuKeyDown = down
end)

-- Panic key: toggle visual suppression without unloading
local wasPanicKeyDown = false
local PANIC_VISUAL_HOOKS = {
    "KeroDisplayNames", "KeroDraw2DBoxes", "KeroDrawMoney", "KeroDrawWeapon",
    "KeroDrawDistance", "KeroDrawWorldESP", "KeroWeaponChams", "KeroArmChams",
    "KeroNoRecoil", "KeroNoSpread", "KeroDrawSuitName", "KeroDrawSuitHealth",
    "KeroHitsound", "KeroFullbrightThink", "KeroFullbright", "KeroFOVChange",
    "KeroFOVCircle", "KeroHueAdvance", "KeroAspectRatio", "KeroCombatCheckHUD",
}

-- Store original hook functions so we can restore them
local _panicSavedHooks = {}

hook.Add("Think", "KeroPanicKeyThink", function()
    if not panicKey then return end
    if panicListening then wasPanicKeyDown = false ; return end
    local down = input.IsKeyDown(panicKey)
    if not down or wasPanicKeyDown then wasPanicKeyDown = down ; return end
    wasPanicKeyDown = down

    panicMode = not panicMode
    local hooktbl = hook.GetTable()

    if panicMode then
        -- Save and remove all visual hooks
        _panicSavedHooks = {}
        for _, name in ipairs(PANIC_VISUAL_HOOKS) do
            for event, hooks in pairs(hooktbl) do
                if hooks[name] then
                    _panicSavedHooks[name] = { event = event, fn = hooks[name] }
                    hook.Remove(event, name)
                end
            end
        end
        -- Close menu if open so it's not visible
        if isMenuOpen and IsValid(keroFrame) then
            keroFrame:Remove()
            isMenuOpen = false
        end
        -- Reset fullbright/fov
        RunConsoleCommand("mat_fullbright", "0")
        RunConsoleCommand("r_shadows", "1")
        keroFullbrightApplied = false
        render.SetColorModulation(1, 1, 1)
        render.SetBlend(1)
        render.MaterialOverride()
    else
        -- Restore saved visual hooks
        for name, data in pairs(_panicSavedHooks) do
            hook.Add(data.event, name, data.fn)
        end
        _panicSavedHooks = {}
    end
end)


-- ════════════════════════════════════════════════
--  Kerosene ASCII banner
-- ════════════════════════════════════════════════
local KERO_ASCII = [[
  _  __  ___  _ __  ___  ___  ___ _ __   ___ 
 | |/ / / _ \| '__/ _ \/ __/ / _ \ '_ \ / _ \
 | ' < |  __/| | | (_) \__ \|  __/ | | |  __/
 |_|\_\ \___||_|  \___/|___/ \___|_| |_|\___|
                                        v1.01
]]

local function PrintKeroBanner()
    MsgN(string.Replace(KERO_ASCII, "v0.992", KERO_VERSION))
end

local function KeroNotifDRP(text, notifType, duration)
    text = string.Replace(text, "Kerosene v0.992", "Kerosene " .. KERO_VERSION)
    notifType = notifType or NOTIFY_HINT
    duration  = duration  or 5
    if GAMEMODE and GAMEMODE.Notify then
        GAMEMODE:Notify(text, notifType, duration)
    elseif notification and notification.AddLegacy then
        notification.AddLegacy(text, notifType, duration)
    else
        chat.AddText(COL_ACCENT, "[Kerosene] ", COL_TEXTPRI, text)
    end
end

-- ════════════════════════════════════════════════
--  Startup: nuke console → print banner → wait 5s
--  → nuke again, then load config.
-- ════════════════════════════════════════════════
timer.Simple(0.3, function()
    NukeConsole()
    PrintKeroBanner()
    MsgN("  Loading Kerosene " .. KERO_VERSION .. " ...")
    MsgN("")
end)

timer.Simple(5.3, function()
    NukeConsole()
end)

timer.Simple(0.5, function()
    surface.PlaySound("ambient/water/drip1.wav")
    KeroNotifDRP("Kerosene v0.992 loaded — press " .. menuKeyName .. " to open.", NOTIFY_HINT, 6)

    local files, _ = file.Find("kero_*.txt", "DATA")
    if files and #files > 0 then
        local best = nil
        for _, fname in ipairs(files) do
            if fname == "kero_default.txt" then best = fname ; break end
        end
        if not best then best = files[#files] end

        local data = file.Read(best, "DATA")
        if data then
            DeserialiseOptions(data)
            local cfgName = string.match(best, "^kero_(.+)%.txt$") or best
            timer.Simple(0.1, function()
                surface.PlaySound("ambient/water/drip3.wav")
                KeroNotifDRP("Auto-loaded config: " .. cfgName, NOTIFY_HINT, 5)
            end)
        end
    end
end)

-- ════════════════════════════════════════════════
--  FOV circle
-- ════════════════════════════════════════════════
hook.Add("HUDPaint", "KeroFOVCircle", function()
    if not options.Combat.CombatOption4 then return end  -- draw toggle off = no circle drawn
    local fovSize = options.Combat.CombatOption5 or 20
    local fcd = options.Combat.FOVColorData
    local col
    if fcd and fcd.rainbow then
        col = RainbowColor(visualHue, 255)
    elseif fcd then
        col = fcd.color
    else
        col = options.Combat.FOVColor or Color(200,200,200)
    end
    local radius  = fovSize * 3.0
    local cx, cy  = ScrW()/2, ScrH()/2
    surface.SetDrawColor(col)
    local segs, verts = 72, {}
    for i = 0, segs-1 do
        local a = (i/segs)*math.pi*2
        table.insert(verts, { x = cx + radius*math.cos(a), y = cy + radius*math.sin(a) })
    end
    for i = 1, #verts do
        local p1, p2 = verts[i], verts[i % #verts + 1]
        surface.DrawLine(p1.x, p1.y, p2.x, p2.y)
    end
end)

-- ════════════════════════════════════════════════
--  Display-distance helper
-- ════════════════════════════════════════════════
local function IsPlayerWithinDisplayDistance(ply)
    local dist = options.Visuals.DisplayDistance or 5000
    return LocalPlayer():GetPos():Distance(ply:GetPos()) <= dist
end

-- Returns true if the player passes the targeted suit filter
local function PassesSuitFilter(ply)
    if not targetedSuitFilters or #targetedSuitFilters == 0 then return true end
    if not IsValid(ply) then return false end
    local suit = ply:GetNWString("ActiveSuit", "")
    for _, f in ipairs(targetedSuitFilters) do
        if suit == f then return true end
    end
    return false
end

-- ════════════════════════════════════════════════
--  Aimbot v0.90 — Aquarium-derived implementation
--
--  Visibility: multi-point TraceHull check (head,
--    chest, feet, sides) so targets behind walls
--    are correctly ignored.
--
--  Camera mode:
--    Smoothly rotates your view toward the nearest
--    visible target within FOV. Angle is stamped
--    into CreateMove each tick so the server sees it.
--
--  Silent mode (from Aquarium):
--    Tracks real mouse movement via the realAng
--    accumulator so your crosshair never visually
--    moves.  On each tick where MOUSE_LEFT is held
--    AND a visible target is within FOV, the cmd
--    angle is silently redirected to the target.
--    Camera angle is NEVER touched.
-- ════════════════════════════════════════════════

local BONE_MAP = {
    ["Head"]        = "ValveBiped.Bip01_Head1",
    ["Torso"]       = "ValveBiped.Bip01_Spine4",
    ["Lower Torso"] = "ValveBiped.Bip01_Spine",
}
local RANDOM_BONES = {
    "ValveBiped.Bip01_Head1",
    "ValveBiped.Bip01_Spine4",
    "ValveBiped.Bip01_Spine",
    "ValveBiped.Bip01_L_Hand",
    "ValveBiped.Bip01_R_Hand",
}

local function GetAimWorldPos(ply)
    local mode     = options.Combat.TargetMode or "Torso"
    local boneName = (mode == "Random") and RANDOM_BONES[math.random(#RANDOM_BONES)] or BONE_MAP[mode]
    if boneName then
        local bid = ply:LookupBone(boneName)
        if bid then
            local bpos = ply:GetBonePosition(bid)
            if bpos then return bpos end
        end
    end
    return ply:GetPos() + Vector(0, 0, 60)
end

-- ── Bone-based visibility: returns true if ANY bone of the target is visible ──
-- This ensures the aimbot only locks onto players with at least one bone
-- in line-of-sight; a fully-occluded player behind a wall is rejected.
local VISIBILITY_BONES = {
    "ValveBiped.Bip01_Head1",
    "ValveBiped.Bip01_Spine4",
    "ValveBiped.Bip01_Spine",
    "ValveBiped.Bip01_L_Foot",
    "ValveBiped.Bip01_R_Foot",
    "ValveBiped.Bip01_L_Hand",
    "ValveBiped.Bip01_R_Hand",
}

local function IsPlayerVisible(target)
    if not IsValid(target) or not target:IsPlayer() then return false end
    local lp     = LocalPlayer()
    local eyePos = lp:EyePos()
    -- Check each bone; if ANY bone is visible the player is a valid target
    for _, boneName in ipairs(VISIBILITY_BONES) do
        local bid = target:LookupBone(boneName)
        if bid then
            local bpos = target:GetBonePosition(bid)
            if bpos then
                local tr = util.TraceLine({
                    start  = eyePos,
                    endpos = bpos,
                    filter = { lp, target },
                    mask   = MASK_SHOT,
                })
                -- If the trace didn't hit anything solid, the bone is visible
                if not tr.Hit or tr.Entity == target then
                    return true
                end
            end
        end
    end
    -- Fall back to eye position trace as a last resort
    local tr = util.TraceLine({
        start  = eyePos,
        endpos = target:EyePos(),
        filter = { lp, target },
        mask   = MASK_SHOT,
    })
    return (not tr.Hit or tr.Entity == target)
end

-- ── Shared target-picker ────────────────────────────────────────────────
local function GetBestTarget()
    local lp      = LocalPlayer()
    if not IsValid(lp) or not lp:Alive() then return nil end
    local fovPx   = (options.Combat.CombatOption5 or 100) * 3.0
    local maxDist = options.Visuals.DisplayDistance or 5000
    local cx, cy  = ScrW() / 2, ScrH() / 2
    local bestEnemy, bestEnemyDist = nil, math.huge
    local bestNeutral, bestNeutralDist = nil, math.huge

    for _, ply in ipairs(player.GetAll()) do
        if ply == lp                            then continue end
        if not IsValid(ply) or not ply:Alive() then continue end
        if ply:GetMoveType() == MOVETYPE_NOCLIP then continue end
        if PlayerHasFlag(ply, "friend")        then continue end
        if lp:GetPos():Distance(ply:GetPos()) > maxDist then continue end
        if not IsPlayerVisible(ply)             then continue end

        local wpos = GetAimWorldPos(ply)
        local sp   = wpos:ToScreen()
        if not sp.visible then continue end

        local dx   = sp.x - cx
        local dy   = sp.y - cy
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < fovPx then
            if PlayerHasFlag(ply, "enemy") then
                if dist < bestEnemyDist then
                    bestEnemyDist = dist
                    bestEnemy = ply
                end
            elseif dist < bestNeutralDist then
                bestNeutralDist = dist
                bestNeutral = ply
            end
        end
    end
    return bestEnemy or bestNeutral
end

-- ── Camera aimbot state ────────────────────────────────────────────────
local _cam_angle = nil
local _cam_base  = nil

hook.Add("Think", "KeroAimbotThink", function()
    if not options.Combat.CombatOption1
    or not aimbotKeyDown
    or (options.Combat.CameraSilentMode or "Camera") ~= "Camera" then
        _cam_angle = nil
        _cam_base  = nil
        return
    end

    local lp = LocalPlayer()
    if not IsValid(lp) or not lp:Alive() then
        _cam_angle = nil ; _cam_base = nil ; return
    end

    local target = GetBestTarget()
    if not IsValid(target) then
        _cam_angle = nil ; _cam_base = nil ; return
    end

    local wpos       = GetAimWorldPos(target)
    local desiredAng = (wpos - lp:EyePos()):Angle()

    -- Map slider 0-100 → lerp factor 1.0 (instant) down to 0.05 (very smooth)
    local rawSmooth = options.Combat.CombatOption3 or 0
    local factor
    if rawSmooth <= 80 then
        factor = 1.0 - (rawSmooth / 80) * 0.80
    else
        local t = (rawSmooth - 80) / 20
        factor  = 0.20 - t * 0.15
    end
    factor = math.Clamp(factor, 0.05, 1.0)

    local base = _cam_base or lp:EyeAngles()
    local newAng = Angle(
        base.p + math.AngleDifference(desiredAng.p, base.p) * factor,
        base.y + math.AngleDifference(desiredAng.y, base.y) * factor,
        0
    )

    _cam_angle = newAng
    _cam_base  = newAng
    lp:SetEyeAngles(newAng)
end)

-- ── Silent aimbot — Aquarium realAng accumulator ───────────────────────
-- Tracks real mouse movement so the camera never visually snaps.
-- On MOUSE_LEFT, silently redirects the cmd angle to the target.
local _realAng = nil

hook.Add("CreateMove", "KeroCameraAimbot", function(cmd)
    if not options.Combat.CombatOption1 then
        _realAng = nil
        return
    end

    local mode = options.Combat.CameraSilentMode or "Camera"

    if mode == "Camera" then
        -- Stamp the smoothed camera angle into the usercmd
        _realAng = nil
        if aimbotKeyDown and _cam_angle then
            cmd:SetViewAngles(_cam_angle)
        end

    elseif mode == "Silent" then
        -- Accumulate real mouse delta every tick (mirrors what the game would
        -- have done) so we always know where the player *thinks* they are aiming.
        if not _realAng then
            _realAng = cmd:GetViewAngles()
        end

        -- Skip the very first cmd (CommandNumber == 0) — it carries garbled data
        if cmd:CommandNumber() == 0 then
            cmd:SetViewAngles(_realAng)
            return
        end

        _realAng = _realAng + Angle(cmd:GetMouseY() * 0.023, cmd:GetMouseX() * -0.023, 0)
        _realAng.p = math.Clamp(math.NormalizeAngle(_realAng.p), -89, 89)
        _realAng.y = math.NormalizeAngle(_realAng.y)
        _realAng.r = 0

        -- Only redirect when the aimbot key is held and MOUSE_LEFT is firing
        local firing = input.IsMouseDown(MOUSE_LEFT)
        if not (aimbotKeyDown and firing) then
            cmd:SetViewAngles(_realAng)
            return
        end

        -- Hit-chance gate
        local hitChance = options.Combat.CombatOption2 or 100
        if math.random(100) > hitChance then
            cmd:SetViewAngles(_realAng)
            return
        end

        local lp = LocalPlayer()
        if not IsValid(lp) or not lp:Alive() then
            cmd:SetViewAngles(_realAng)
            return
        end

        local target = GetBestTarget()
        if not IsValid(target) then
            cmd:SetViewAngles(_realAng)
            return
        end

        -- Silently aim at the target bone — camera angle unchanged
        local aimPos    = GetAimWorldPos(target)
        local silentAng = (aimPos - lp:EyePos()):Angle()
        silentAng.r     = 0
        cmd:SetViewAngles(silentAng)
        cmd:SetMouseX(0)
        cmd:SetMouseY(0)
    end
end)

-- ════════════════════════════════════════════════
--  Rainbow hue advance
-- ════════════════════════════════════════════════
hook.Add("HUDPaint", "KeroHueAdvance", function()
    visualHue = (visualHue + 0.0008) % 1
end)

-- ════════════════════════════════════════════════
--  ESP: 2D Bounds helper (must be defined before all ESP hooks)
-- ════════════════════════════════════════════════
local function Get2DBounds(ent)
    local org = ent:GetPos()
    local mn, mx = ent:OBBMins(), ent:OBBMaxs()
    local minX, minY =  math.huge,  math.huge
    local maxX, maxY = -math.huge, -math.huge
    local vis = false
    for _, v in ipairs({
        org+Vector(mn.x,mn.y,mn.z), org+Vector(mx.x,mn.y,mn.z),
        org+Vector(mn.x,mx.y,mn.z), org+Vector(mx.x,mx.y,mn.z),
        org+Vector(mn.x,mn.y,mx.z), org+Vector(mx.x,mn.y,mx.z),
        org+Vector(mn.x,mx.y,mx.z), org+Vector(mx.x,mx.y,mx.z),
    }) do
        local sp = v:ToScreen()
        if sp.visible then vis = true end
        if sp.x < minX then minX = sp.x end ; if sp.x > maxX then maxX = sp.x end
        if sp.y < minY then minY = sp.y end ; if sp.y > maxY then maxY = sp.y end
    end
    return minX, minY, maxX, maxY, vis
end

local function DrawBox2D(minX, minY, maxX, maxY, col)
    surface.SetDrawColor(0,0,0,160)
    surface.DrawOutlinedRect(minX-1, minY-1, (maxX-minX)+2, (maxY-minY)+2, 1)
    surface.SetDrawColor(col)
    surface.DrawOutlinedRect(minX, minY, maxX-minX, maxY-minY, 1)
end

local function DrawBox3D(ent, col)
    local mn, mx = ent:OBBMins(), ent:OBBMaxs()
    local org = ent:GetPos()
    local corners = {
        org+Vector(mn.x,mn.y,mn.z), org+Vector(mx.x,mn.y,mn.z),
        org+Vector(mx.x,mx.y,mn.z), org+Vector(mn.x,mx.y,mn.z),
        org+Vector(mn.x,mn.y,mx.z), org+Vector(mx.x,mn.y,mx.z),
        org+Vector(mx.x,mx.y,mx.z), org+Vector(mn.x,mx.y,mx.z),
    }
    local sc = {}
    for i, v in ipairs(corners) do
        local s = v:ToScreen()
        sc[i] = s
        if not s.visible then return end
    end
    surface.SetDrawColor(col)
    -- Bottom face
    for i=1,4 do
        local a, b = sc[i], sc[(i%4)+1]
        surface.DrawLine(a.x,a.y,b.x,b.y)
    end
    -- Top face
    for i=5,8 do
        local a, b = sc[i], sc[(i%4)+5]
        surface.DrawLine(a.x,a.y,b.x,b.y)
    end
    -- Vertical edges
    for i=1,4 do
        surface.DrawLine(sc[i].x,sc[i].y,sc[i+4].x,sc[i+4].y)
    end
end

-- ════════════════════════════════════════════════
--  ESP: Player Names
-- ════════════════════════════════════════════════
hook.Add("HUDPaint", "KeroDisplayNames", function()
    if not options.Visuals.VisualsOption1 then return end
    for _, ply in ipairs(player.GetAll()) do
        if ply:Alive() and ply ~= LocalPlayer() and IsPlayerWithinDisplayDistance(ply) and PassesSuitFilter(ply) then
            local x1,y1,x2,y2,vis = Get2DBounds(ply)
            if not vis then continue end
            local name = (options.Visuals.NameType == "Steam Name") and ply:SteamName() or ply:Nick()
            local lx, ly, ha, va = ESPLabelPos(x1,y1,x2,y2, ESPArrangement.Name)
            local font   = ESPArrangement.Name.bold and "DermaDefaultBold" or "DermaDefault"
            local col    = GetPlayerESPColor(ply, "Name")
            if ESPArrangement.Name.outline then
                draw.SimpleTextOutlined(name, font, lx, ly, col, ha, va, 1, Color(0,0,0,200))
            else
                draw.SimpleText(name, font, lx, ly, col, ha, va)
            end
        end
    end
end)

-- ════════════════════════════════════════════════
--  ESP: Boxes (2D or 3D)
-- ════════════════════════════════════════════════

hook.Add("HUDPaint", "KeroDraw2DBoxes", function()
    if not options.Visuals.VisualsOption2 then return end
    local use3D = (options.Visuals.BoxType == "3D Boxes")
    for _, ply in ipairs(player.GetAll()) do
        if ply:Alive() and ply ~= LocalPlayer() and IsPlayerWithinDisplayDistance(ply) and PassesSuitFilter(ply) then
            if use3D then
                DrawBox3D(ply, GetPlayerESPColor(ply, "Boxes"))
            else
                local x1,y1,x2,y2,vis = Get2DBounds(ply)
                if vis then DrawBox2D(x1,y1,x2,y2, GetPlayerESPColor(ply, "Boxes")) end
            end
        end
    end
end)

-- ════════════════════════════════════════════════
--  Money formatting helper
-- ════════════════════════════════════════════════
local function FormatMoney(n)
    n = tonumber(n) or 0
    if n >= 1000000000 then
        return string.format("$%.1fb", n / 1000000000):gsub("%.0f", "f")
    elseif n >= 1000000 then
        return string.format("$%.1fm", n / 1000000):gsub("%.0m", "m")
    elseif n >= 1000 then
        return string.format("$%.1fk", n / 1000):gsub("%.0k", "k")
    else
        return "$" .. tostring(n)
    end
end

-- ════════════════════════════════════════════════
--  ESP: Money
-- ════════════════════════════════════════════════
hook.Add("HUDPaint", "KeroDrawMoney", function()
    if not options.Visuals.VisualsOption3 then return end
    for _, ply in ipairs(player.GetAll()) do
        if ply:Alive() and ply ~= LocalPlayer() and IsPlayerWithinDisplayDistance(ply) and PassesSuitFilter(ply) then
            local x1,y1,x2,y2,vis = Get2DBounds(ply)
            if not vis then continue end
            local money = ply:getDarkRPVar("money") or 0
            local lx, ly, ha, va = ESPLabelPos(x1,y1,x2,y2, ESPArrangement.Money)
            local font   = ESPArrangement.Money.bold and "DermaDefaultBold" or "DermaDefault"
            local col    = GetPlayerESPColor(ply, "Money")
            if ESPArrangement.Money.outline then
                draw.SimpleTextOutlined(FormatMoney(money), font, lx, ly, col, ha, va, 1, Color(0,0,0,200))
            else
                draw.SimpleText(FormatMoney(money), font, lx, ly, col, ha, va)
            end
        end
    end
end)

-- ════════════════════════════════════════════════
--  ESP: Weapon
-- ════════════════════════════════════════════════
hook.Add("HUDPaint", "KeroDrawWeapon", function()
    if not options.Visuals.VisualsOption4 then return end
    for _, ply in ipairs(player.GetAll()) do
        if ply:Alive() and ply ~= LocalPlayer() and IsPlayerWithinDisplayDistance(ply) and PassesSuitFilter(ply) then
            local x1,y1,x2,y2,vis = Get2DBounds(ply)
            if not vis then continue end
            local wep = ply:GetActiveWeapon()
            local wname = IsValid(wep) and string.gsub(wep:GetClass(),"weapon_","") or "None"
            local lx, ly, ha, va = ESPLabelPos(x1,y1,x2,y2, ESPArrangement.Weapon)
            local font   = ESPArrangement.Weapon.bold and "DermaDefaultBold" or "DermaDefault"
            local col    = GetPlayerESPColor(ply, "Weapon")
            if ESPArrangement.Weapon.outline then
                draw.SimpleTextOutlined(wname, font, lx, ly, col, ha, va, 1, Color(0,0,0,200))
            else
                draw.SimpleText(wname, font, lx, ly, col, ha, va)
            end
        end
    end
end)

-- ════════════════════════════════════════════════
--  ESP: Distance
-- ════════════════════════════════════════════════
hook.Add("HUDPaint", "KeroDrawDistance", function()
    if not options.Visuals.VisualsOption5 then return end
    for _, ply in ipairs(player.GetAll()) do
        if ply:Alive() and ply ~= LocalPlayer() and IsPlayerWithinDisplayDistance(ply) and PassesSuitFilter(ply) then
            local x1,y1,x2,y2,vis = Get2DBounds(ply)
            if not vis then continue end
            local dist = math.Round(LocalPlayer():GetPos():Distance(ply:GetPos()))
            local lx, ly, ha, va = ESPLabelPos(x1,y1,x2,y2, ESPArrangement.Distance)
            local font   = ESPArrangement.Distance.bold and "DermaDefaultBold" or "DermaDefault"
            local col    = GetPlayerESPColor(ply, "Distance")
            if ESPArrangement.Distance.outline then
                draw.SimpleTextOutlined(dist.."m", font, lx, ly, col, ha, va, 1, Color(0,0,0,200))
            else
                draw.SimpleText(dist.."m", font, lx, ly, col, ha, va)
            end
        end
    end
end)

-- ════════════════════════════════════════════════
--  ESP: World ESP
-- ════════════════════════════════════════════════
hook.Add("HUDPaint", "KeroDrawWorldESP", function()
    if not options.Visuals.VisualsOption6 then return end
    for _, ent in ipairs(ents.GetAll()) do
        if not IsValid(ent) or ent:IsPlayer() then continue end
        local cls = ent:GetClass()
        -- Filter: if list is non-empty, entity class must match one entry
        if #worldESPFilters > 0 then
            local found = false
            local clsLow = string.lower(cls)
            for _, f in ipairs(worldESPFilters) do
                if string.lower(f) == clsLow then found = true ; break end
            end
            if not found then continue end
        end
        local x1,y1,x2,y2,vis = Get2DBounds(ent)
        if vis then
            DrawBox2D(x1, y1, x2, y2, GetVisualColor("WorldESP"))
            local sp = ent:GetPos():ToScreen()
            if sp.visible then
                draw.SimpleText(cls,"DermaDefault",sp.x,y1-2,GetVisualColor("WorldESP"),TEXT_ALIGN_CENTER,TEXT_ALIGN_BOTTOM)
            end
        end
    end
end)

-- ════════════════════════════════════════════════
--  Chams
-- ════════════════════════════════════════════════
local chamHue = 0

local CHAMS_MATERIALS = {
    Flat      = Material("models/debug/debugwhite"),
    Wireframe = Material("models/wireframe"),
}

local function ApplyChamsMaterial(matName)
    if matName == "Normal" then
        render.MaterialOverride()  -- no material override; colour modulation still applies
        return
    end
    local mat = CHAMS_MATERIALS[matName] or CHAMS_MATERIALS["Flat"]
    render.MaterialOverride(mat)
end

hook.Add("PreDrawViewModel", "KeroWeaponChams", function(vm, ply, wep)
    if miscChams.WeaponChams then
        local c = MiscColors.WeaponChams.rainbow and RainbowColor(visualHue) or MiscColors.WeaponChams.color
        render.SetColorModulation(c.r/255, c.g/255, c.b/255)
        render.SetBlend(1)
        ApplyChamsMaterial(options.Misc.WeaponChamsMaterial or "Flat")
    end
end)

hook.Add("PostDrawViewModel", "KeroArmChams", function(vm, ply, wep)
    render.MaterialOverride()
    render.SetColorModulation(1, 1, 1)
    render.SetBlend(1)
    if miscChams.ArmChams then
        chamHue = (chamHue + 0.0008) % 1
        local c = MiscColors.ArmChams.rainbow and RainbowColor(visualHue) or MiscColors.ArmChams.color
        render.SetColorModulation(c.r/255, c.g/255, c.b/255)
        render.SetBlend(1)
        ApplyChamsMaterial(options.Misc.ArmChamsMaterial or "Flat")
    end
end)

-- ════════════════════════════════════════════════
--  Remove Recoil
-- ════════════════════════════════════════════════
local recoilBaseAngles = nil

hook.Add("CreateMove", "KeroNoRecoil", function(cmd)
    if not options.Misc.MiscOption1 then recoilBaseAngles = nil ; return end
    if recoilBaseAngles then
        local fixed = Angle(recoilBaseAngles.p, recoilBaseAngles.y, 0)
        cmd:SetViewAngles(fixed)
        LocalPlayer():SetEyeAngles(fixed)
    end
    recoilBaseAngles = Angle(cmd:GetViewAngles().p, cmd:GetViewAngles().y, 0)
end)

-- ════════════════════════════════════════════════
--  Remove Spread
-- ════════════════════════════════════════════════
hook.Add("EntityFireBullets", "KeroNoSpread", function(ent, data)
    if not options.Misc.MiscOption2 then return end
    if not ent:IsPlayer() then return end
    local exactDir  = ent:EyeAngles():Forward()
    data.Src    = ent:GetShootPos()
    data.Dir    = exactDir
    data.Spread = Vector(0, 0, 0)
end)

-- ════════════════════════════════════════════════
--  Hitsound
--  Uses EntityFireBullets with a BulletCallback to
--  detect when our bullets actually hit a player.
-- ════════════════════════════════════════════════
hook.Add("EntityFireBullets", "KeroHitsound", function(ent, data)
    if not IsValid(ent) or ent ~= LocalPlayer() then return end
    if not options.Misc.HitsoundEnabled then return end
    local snd = options.Misc.HitsoundSound
    if not snd then return end
    -- Inject a BulletCallback that plays the sound when a player is hit
    local prevCB = data.Callback
    data.Callback = function(attacker, tr, dmginfo)
        if prevCB then prevCB(attacker, tr, dmginfo) end
        if IsValid(tr.Entity) and tr.Entity:IsPlayer() then
            surface.PlaySound(snd)
        end
    end
end)

-- ════════════════════════════════════════════════
--  FOV Changer
-- ════════════════════════════════════════════════
local keroFullbrightApplied = nil

local function ApplyFullbrightState(enabled)
    RunConsoleCommand("r_shadows", enabled and "0" or "1")
    RunConsoleCommand("mat_fullbright", enabled and "1" or "0")
end

hook.Add("Think", "KeroFullbrightThink", function()
    local enabled = options.Misc.Fullbright or false
    if keroFullbrightApplied == enabled then return end
    ApplyFullbrightState(enabled)
    keroFullbrightApplied = enabled
end)

hook.Add("RenderScreenspaceEffects", "KeroFullbright", function()
    if not options.Misc.Fullbright then return end
    DrawColorModify({
        ["$pp_colour_addr"] = 0,
        ["$pp_colour_addg"] = 0,
        ["$pp_colour_addb"] = 0,
        ["$pp_colour_brightness"] = 0.08,
        ["$pp_colour_contrast"] = 1.1,
        ["$pp_colour_colour"] = 1.25,
        ["$pp_colour_mulr"] = 0,
        ["$pp_colour_mulg"] = 0,
        ["$pp_colour_mulb"] = 0,
    })
end)

hook.Add("CalcView", "KeroFOVChange", function(ply, origin, angles, fov)
    local custom = options.Misc.CustomFOV
    if not custom or custom == 0 then return end
    return { fov = custom }
end)

-- ════════════════════════════════════════════════
--  Aspect Ratio — horizontal stretch simulation
--  Uses a render target: the game view is captured
--  at a narrower logical width then stretched to
--  fill the full screen, simulating a 4:3/5:4
--  "stretched" look that pros use.
--  Slider: 0 = native, 100 = full 4:3 stretch.
-- ════════════════════════════════════════════════
local _arRT      = nil
local _arMat     = nil
local _arPushes  = 0  -- counts how many times we have pushed without popping

local function GetOrCreateARRT()
    if not _arRT then
        _arRT  = GetRenderTarget("kero_ar_rt", ScrW(), ScrH(), false)
        _arMat = CreateMaterial("kero_ar_mat", "UnlitGeneric", {
            ["$basetexture"] = "kero_ar_rt",
            ["$noclamp"]     = "1",
            ["$ignorez"]     = "1",
        })
    end
    return _arRT, _arMat
end

-- Safe pop: only pops if we actually pushed, preventing underflow entirely
local function SafePopAR()
    if _arPushes > 0 then
        _arPushes = _arPushes - 1
        render.PopRenderTarget()
    end
end

hook.Add("PreRender", "KeroAspectRatio", function()
    local stretch = options.Misc.AspectStretch or 0
    if stretch <= 0 then
        -- If a prior push was somehow orphaned, drain it now
        while _arPushes > 0 do
            _arPushes = _arPushes - 1
            render.PopRenderTarget()
        end
        return
    end
    -- Only push once per frame — bail if already pushed
    if _arPushes > 0 then return end
    local rt, _ = GetOrCreateARRT()
    if not rt then return end
    _arPushes = _arPushes + 1
    render.PushRenderTarget(rt)
    render.Clear(0, 0, 0, 255, true, true)
end)

hook.Add("PostRender", "KeroAspectRatio", function()
    -- Nothing was pushed this frame — nothing to draw or pop
    if _arPushes == 0 then return end
    SafePopAR()

    local stretch = options.Misc.AspectStretch or 0
    if stretch <= 0 then return end
    if not _arRT or not _arMat then return end

    local scrW, scrH = ScrW(), ScrH()

    -- stretch factor: 0→no change, 100→fully squish to 4:3 equivalent
    local frac     = stretch / 100
    local native   = scrW / scrH
    local target   = 4/3
    local srcRatio = native + (target - native) * frac
    local srcW     = scrH * srcRatio
    local offX     = (scrW - srcW) / 2

    local u0 = offX / scrW
    local u1 = (offX + srcW) / scrW

    _arMat:SetTexture("$basetexture", _arRT)
    render.SetMaterial(_arMat)
    mesh.Begin(MATERIAL_QUADS, 1)
        mesh.TexCoord(0, u0, 0) ; mesh.Position(Vector(0,     0,    0)) ; mesh.AdvanceVertex()
        mesh.TexCoord(0, u1, 0) ; mesh.Position(Vector(scrW,  0,    0)) ; mesh.AdvanceVertex()
        mesh.TexCoord(0, u1, 1) ; mesh.Position(Vector(scrW,  scrH, 0)) ; mesh.AdvanceVertex()
        mesh.TexCoord(0, u0, 1) ; mesh.Position(Vector(0,     scrH, 0)) ; mesh.AdvanceVertex()
    mesh.End()
end)

-- ════════════════════════════════════════════════
--  Suit Name / Suit Health ESP
--  Displays the player's active suit name and suit
--  health (GetSuitArmor) relative to their 2D box,
--  positioned via ESPArrangement (same as Name etc.)
-- ════════════════════════════════════════════════

hook.Add("HUDPaint", "KeroDrawSuitName", function()
    if not options.Visuals.VisualsOption7 then return end
    for _, ply in ipairs(player.GetAll()) do
        if not ply:Alive() or ply == LocalPlayer() then continue end
        if not IsPlayerWithinDisplayDistance(ply) then continue end
        if not PassesSuitFilter(ply) then continue end
        local x1,y1,x2,y2,vis = Get2DBounds(ply)
        if not vis then continue end
        local suitName = ply:GetNWString("ActiveSuit", "")
        if suitName == "" then continue end  -- hide when no suit equipped
        local arr  = ESPArrangement.SuitName
        local lx, ly, ha, va = ESPLabelPos(x1,y1,x2,y2, arr)
        local font = arr.bold and "DermaDefaultBold" or "DermaDefault"
        local col  = GetPlayerESPColor(ply, "SuitName")
        if arr.outline then
            draw.SimpleTextOutlined(suitName, font, lx, ly, col, ha, va, 1, Color(0,0,0,200))
        else
            draw.SimpleText(suitName, font, lx, ly, col, ha, va)
        end
    end
end)

hook.Add("HUDPaint", "KeroDrawSuitHealth", function()
    if not options.Visuals.VisualsOption8 then return end
    for _, ply in ipairs(player.GetAll()) do
        if not ply:Alive() or ply == LocalPlayer() then continue end
        if not IsPlayerWithinDisplayDistance(ply) then continue end
        if not PassesSuitFilter(ply) then continue end
        local x1,y1,x2,y2,vis = Get2DBounds(ply)
        if not vis then continue end
        -- Hide if no suit is equipped
        local suitName = ply:GetNWString("ActiveSuit", "")
        if suitName == "" then continue end
        -- Try NWFloat first (primary), then NWInt fallback
        local suitCur = ply:GetNWFloat("SuitHealth", -1)
        if suitCur < 0 then suitCur = ply:GetNWInt("SuitHealth", 0) end
        suitCur = math.floor(suitCur)
        local suitMax = ply:GetNWFloat("SuitMaxHealth", -1)
        if suitMax < 0 then suitMax = ply:GetNWInt("SuitMaxHealth", 0) end
        suitMax = math.floor(suitMax)
        -- Hide if both values are 0 (suit not yet initialised)
        if suitCur == 0 and suitMax == 0 then continue end
        local label
        if suitMax > 0 then
            label = suitCur .. "/" .. suitMax
        else
            label = tostring(suitCur)
        end
        local arr  = ESPArrangement.SuitHealth
        local lx, ly, ha, va = ESPLabelPos(x1,y1,x2,y2, arr)
        local font = arr.bold and "DermaDefaultBold" or "DermaDefault"
        local col  = GetPlayerESPColor(ply, "SuitHealth")
        if arr.outline then
            draw.SimpleTextOutlined(label, font, lx, ly, col, ha, va, 1, Color(0,0,0,200))
        else
            draw.SimpleText(label, font, lx, ly, col, ha, va)
        end
    end
end)


-- ════════════════════════════════════════════════
--  Combat Check notification system
--  Max 7 on screen, pushing upward from bottom anchor.
--  Weapon name abbreviation for damage events.
-- ════════════════════════════════════════════════

-- Weapon class → short display name abbreviations
local WEAPON_ABBREV = {
    ["weapon_glock 2"] = "Glock",
    ["ryry_m134"]      = "Mini V2",
}
local function FriendlyWeaponName(cls)
    if not cls then return "Unknown" end
    local lower = string.lower(cls)
    -- Check abbreviation table first (case-insensitive)
    for k, v in pairs(WEAPON_ABBREV) do
        if string.lower(k) == lower then return v end
    end
    -- Strip common prefixes
    local stripped = cls:gsub("^weapon_", ""):gsub("^swep_", ""):gsub("^wep_", "")
    return stripped
end

local function KeroNotify(msg, ntype)
    -- Deduplicate within a short window
    for _, n in ipairs(combatNotifs) do
        if n.text == msg and (CurTime() - n.created) < 1.5 then
            n.expiry = CurTime() + 4
            return
        end
    end
    table.insert(combatNotifs, {
        text    = msg,
        created = CurTime(),
        expiry  = CurTime() + 4,
        ntype   = ntype or "info",
    })
    -- Cap to 7 visible — remove oldest
    if #combatNotifs > 7 then table.remove(combatNotifs, 1) end
end

-- HP polling
local ccLastHP     = {}
local ccLastSuitHP = {}  -- track suit hp drops for combat check
-- Track the last attacker+weapon directed at each watched target.
-- EntityFireBullets fires for ALL players, so we record the most recent
-- shooter who is NOT the watched target — that is the attacker.
local ccAttackerWeapon = {}   -- [targetEntIndex] = { nick, wname }

hook.Add("Think", "KeroCombatCheckHPPoll", function()
    if not options.Misc.MiscOption5 then return end
    MigrateLegacyCombatTargets()
    RefreshCombatCheckTargets()
    if table.Count(playerStates) == 0 then return end

    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) or ply == LocalPlayer() then continue end
        if not PlayerHasFlag(ply, "watch") then continue end

        local nick = ply:Nick()
        local hp = ply:Health()
        local id = ply:EntIndex()

        if ccLastHP[id] ~= nil and hp < ccLastHP[id] and hp > 0 then
            local delta = ccLastHP[id] - hp
            -- Use the last recorded attacker weapon; fall back to "Unknown"
            local atk = ccAttackerWeapon[id]
            local wname = atk and atk.wname or "Unknown"
            KeroNotify(nick .. " -" .. delta .. "hp [" .. wname .. "]", "damage")
        end
        ccLastHP[id] = hp

        -- Suit HP tracking
        local suitHP = ply:GetNWFloat("SuitHealth", -1)
        if suitHP < 0 then suitHP = ply:GetNWInt("SuitHealth", 0) end
        suitHP = math.floor(suitHP)
        if ccLastSuitHP[id] ~= nil and suitHP < ccLastSuitHP[id] and suitHP >= 0 then
            local delta = ccLastSuitHP[id] - suitHP
            local atk = ccAttackerWeapon[id]
            local wname = atk and atk.wname or "Unknown"
            KeroNotify(nick .. " -" .. delta .. " suit [" .. wname .. "]", "suitdmg")
        end
        ccLastSuitHP[id] = suitHP
    end
end)

-- EntityFireBullets fires for EVERY player that shoots.
-- We record the shooter's weapon against each watched target so the HP-poll
-- can attribute incoming damage correctly.
hook.Add("EntityFireBullets", "KeroCombatCheckShoot", function(ent, data)
    if not options.Misc.MiscOption5 then return end
    MigrateLegacyCombatTargets()
    RefreshCombatCheckTargets()
    if table.Count(playerStates) == 0 then return end
    if not IsValid(ent) or not ent:IsPlayer() then return end

    local shooterNick = ent:Nick()
    local wep   = ent:GetActiveWeapon()
    local wname = IsValid(wep) and FriendlyWeaponName(wep:GetClass()) or "Unknown"

    local shooterIsTarget = PlayerHasFlag(ent, "watch")
    if shooterIsTarget then
        KeroNotify(shooterNick .. " fired " .. wname, "shoot")
    end

    if not shooterIsTarget then
        for _, targetPly in ipairs(player.GetAll()) do
            if not IsValid(targetPly) then continue end
            if not PlayerHasFlag(targetPly, "watch") then continue end
            ccAttackerWeapon[targetPly:EntIndex()] = { nick = shooterNick, wname = wname }
        end
    end
end)

-- Draw notifications — max 7, anchored bottom-right, stacking upward
hook.Add("HUDPaint", "KeroCombatCheckHUD", function()
    if not options.Misc.MiscOption5 then return end

    -- Purge expired
    for i = #combatNotifs, 1, -1 do
        if CurTime() > combatNotifs[i].expiry then table.remove(combatNotifs, i) end
    end

    if #combatNotifs == 0 then return end

    local scrW    = ScrW()
    local NOTIF_W = 300
    local NOTIF_H = 34
    local PADDING = 4
    -- Top-right anchor: newest notification sits at top, older ones stack downward.
    -- When count exceeds 7 the oldest entries are off the bottom (pushed down) and
    -- eventually expire — we simply only draw the top 7.
    local TOP_Y   = 16

    local count = #combatNotifs  -- no hard cap on list; just cap rendering

    for i = count, math.max(count - 6, 1), -1 do  -- draw up to 7, newest first
        local notif    = combatNotifs[i]
        local age      = CurTime() - notif.created
        local timeLeft = notif.expiry - CurTime()
        local life     = notif.expiry - notif.created

        local fadeIn   = math.Clamp(age / 0.15, 0, 1)
        local fadeOut  = math.Clamp(timeLeft / 0.4, 0, 1)
        local alpha    = math.min(fadeIn, fadeOut)

        -- slot 0 = newest (top), slot 1 = next, etc.
        local slot = count - i
        local ty   = TOP_Y + slot * (NOTIF_H + PADDING)
        local tx   = scrW - NOTIF_W - 14

        -- Slide in from right
        local slideX  = tx + (1 - alpha) * 40
        local bgAlpha = math.Round(alpha * 150)

        -- Shadow
        draw.RoundedBox(6, slideX + 2, ty + 2, NOTIF_W, NOTIF_H, Color(0, 0, 0, math.Round(alpha * 60)))
        -- Background
        draw.RoundedBox(5, slideX, ty, NOTIF_W, NOTIF_H, Color(12, 13, 16, bgAlpha))

        local accentFull = GetMiscColor("CombatCheck")
        local accentCol  = Color(accentFull.r, accentFull.g, accentFull.b, math.Round(alpha * 230))

        -- Left accent bar
        draw.RoundedBoxEx(4, slideX, ty, 3, NOTIF_H, accentCol, true, false, true, false)
        -- Subtle top highlight
        surface.SetDrawColor(255, 255, 255, math.Round(alpha * 12))
        surface.DrawRect(slideX + 4, ty, NOTIF_W - 4, 1)
        -- Border
        surface.SetDrawColor(accentFull.r, accentFull.g, accentFull.b, math.Round(alpha * 35))
        surface.DrawOutlinedRect(slideX, ty, NOTIF_W, NOTIF_H, 1)

        -- Type label
        local typeLabel = notif.ntype == "shoot" and "FIRE"
                       or notif.ntype == "suitdmg" and "SUIT"
                       or "HIT"
        local typeCol = notif.ntype == "shoot"
            and Color(100, 180, 255, math.Round(alpha * 200))
            or  notif.ntype == "suitdmg"
            and Color(80,  210, 200, math.Round(alpha * 200))
            or  Color(255, 120, 80,  math.Round(alpha * 200))
        draw.SimpleText(typeLabel, "DermaDefault",
            slideX + 10, ty + NOTIF_H / 2,
            typeCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- Divider
        surface.SetDrawColor(accentFull.r, accentFull.g, accentFull.b, math.Round(alpha * 30))
        surface.DrawRect(slideX + 34, ty + 5, 1, NOTIF_H - 10)

        -- Main text
        draw.SimpleText(notif.text, "DermaDefault",
            slideX + 42, ty + NOTIF_H / 2,
            Color(215, 217, 221, math.Round(alpha * 220)), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        -- Progress bar
        local prog = math.Clamp(timeLeft / life, 0, 1)
        local barW = math.Round((NOTIF_W - 6) * prog)
        if barW > 0 then
            draw.RoundedBox(2, slideX + 3, ty + NOTIF_H - 3, NOTIF_W - 6, 2,
                Color(accentFull.r, accentFull.g, accentFull.b, math.Round(alpha * 50)))
            draw.RoundedBox(2, slideX + 3, ty + NOTIF_H - 3, barW, 2, accentCol)
        end
    end
end)

end -- BootKerosene

local function KeroWhitelistStart()
    if keroWhitelistState.booted or keroWhitelistState.pending then return end

    local url = KeroWhitelistResolveURL(KERO_WHITELIST.url)
    if url == "" or string.find(url, "PASTE_RAW_WHITELIST_URL_HERE", 1, true) then
        keroWhitelistState.checked = true
        KeroWhitelistNotify("Whitelist URL is not configured. Edit KERO_WHITELIST.url in v1.lua.", NOTIFY_ERROR, 10)
        hook.Remove("Think", "KeroWhitelistBoot")
        return
    end

    if not HTTP then
        keroWhitelistState.checked = true
        KeroWhitelistNotify("HTTP is unavailable, so the remote whitelist could not be checked.", NOTIFY_ERROR, 10)
        hook.Remove("Think", "KeroWhitelistBoot")
        return
    end

    local lp = LocalPlayer()
    if not IsValid(lp) then return end

    local steamID64 = lp:SteamID64()
    local steamID = lp:SteamID()
    if not steamID64 or steamID64 == "" or steamID64 == "0" then return end

    keroWhitelistState.pending = true

    HTTP({
        url = url,
        method = "get",
        timeout = KERO_WHITELIST.requestTimeout or 15,
        headers = {
            ["Cache-Control"] = "no-cache",
            ["Pragma"] = "no-cache",
        },
        success = function(code, body)
            keroWhitelistState.pending = false
            keroWhitelistState.checked = true

            if code < 200 or code >= 300 then
                KeroWhitelistNotify("Whitelist request failed with HTTP " .. tostring(code) .. ".", NOTIFY_ERROR, 10)
                hook.Remove("Think", "KeroWhitelistBoot")
                return
            end

            local allowed, err = KeroParseWhitelistBody(body)
            if not allowed then
                KeroWhitelistNotify(err or "Whitelist response could not be parsed.", NOTIFY_ERROR, 10)
                hook.Remove("Think", "KeroWhitelistBoot")
                return
            end

            if not KeroWhitelistAllowsPlayer(allowed, steamID64, steamID) then
                KeroWhitelistNotify("Access denied. Your SteamID is not on the remote whitelist.", NOTIFY_ERROR, 10)
                hook.Remove("Think", "KeroWhitelistBoot")
                return
            end

            if not keroWhitelistState.booted then
                keroWhitelistState.authorized = true
                keroWhitelistState.booted = true
                hook.Remove("Think", "KeroWhitelistBoot")
                BootKerosene()
            end
        end,
        failed = function(err)
            keroWhitelistState.pending = false
            keroWhitelistState.checked = true
            KeroWhitelistNotify("Whitelist fetch failed: " .. tostring(err), NOTIFY_ERROR, 10)
            hook.Remove("Think", "KeroWhitelistBoot")
        end
    })
end

hook.Add("Think", "KeroWhitelistBoot", function()
    KeroWhitelistStart()
end)
