-- GudaPlates for WoW 1.12.1
-- Written for Lua 5.0 (Vanilla)

GudaPlates = GudaPlates or {}

-- ============================================
-- ShaguTweaks Compatibility Layer
-- ============================================
-- ShaguTweaks' libnameplate.lua also scans WorldFrame for nameplates and hooks
-- OnShow/OnUpdate scripts. This causes conflicts with GudaPlates because:
-- 1. Both addons try to modify the same nameplate frames
-- 2. Script chaining breaks due to vanilla Lua's `this` global vs `self` parameter
-- 3. Frame structure changes invalidate captured script references
--
-- Solution: Disable ShaguTweaks' nameplate processing when GudaPlates is active.
-- ShaguTweaks nameplate modules check `if ShaguPlates then return end` to avoid
-- conflicts with ShaguPlates. We hook this same pattern.

-- Function to disable ShaguTweaks nameplate handling (called on ADDON_LOADED)
local function DisableShaguTweaksNameplates()
    if ShaguTweaks and ShaguTweaks.libnameplate then
        -- Disable the OnUpdate scanner that looks for new nameplates
        ShaguTweaks.libnameplate:SetScript("OnUpdate", nil)

        -- Clear the callback tables to prevent any registered functions from running
        ShaguTweaks.libnameplate.OnInit = {}
        ShaguTweaks.libnameplate.OnShow = {}
        ShaguTweaks.libnameplate.OnUpdate = {}

        -- Mark as handled so modules know not to register new callbacks
        ShaguTweaks.libnameplate.disabled_by_gudaplates = true

        return true
    end
    return false
end
GudaPlates.DisableShaguTweaksNameplates = DisableShaguTweaksNameplates

-- Try immediately in case ShaguTweaks loaded before us
-- (Also called in main ADDON_LOADED handler for proper timing)
DisableShaguTweaksNameplates()

-- Ensure Settings exists with defaults (fallback if Settings file didn't load)
if not GudaPlates.Settings then
    GudaPlates.Settings = {
        healthbarHeight = 14, healthbarWidth = 115, healthFontSize = 10,
        healthTextPosition = "CENTER", healthTextFormat = 1,
        friendHealthbarHeight = 4, friendHealthbarWidth = 85, friendHealthFontSize = 10,
        friendHealthTextPosition = "CENTER", friendHealthTextFormat = 1,
        showManaBar = false, manaTextFormat = 1, manaTextPosition = "CENTER", manabarHeight = 4,
        friendShowManaBar = false, friendManaTextFormat = 1, friendManaTextPosition = "CENTER", friendManabarHeight = 4,
        castbarHeight = 12, castbarWidth = 115, castbarIndependent = false, showCastbarIcon = true,
        friendCastbarHeight = 6, friendCastbarWidth = 85, friendCastbarIndependent = false, friendShowCastbarIcon = true,
        castbarColor = {1, 0.8, 0, 1},
        levelFontSize = 10, nameFontSize = 10, friendLevelFontSize = 8, friendNameFontSize = 8,
        textFont = "Fonts\\ARIALN.TTF",
        raidIconPosition = "LEFT", swapNameDebuff = true,
        showOnlyMyDebuffs = true, showDebuffTimers = true,
        showTargetGlow = true, targetGlowColor = {0.4, 0.8, 0.9, 0.4},
        debuffIconSize = 16,
        nameColor = {1, 1, 1, 1}, healthTextColor = {1, 1, 1, 1},
        manaTextColor = {1, 1, 1, 1}, levelColor = {1, 1, 0.6, 1},
        useLevelDiffColors = true,
        optionsBgAlpha = 0.9, hideOptionsBorder = false,
        showCritterNameplates = false,
    }
end
if not GudaPlates.Critters then GudaPlates.Critters = {} end
if not GudaPlates.THREAT_COLORS then GudaPlates.THREAT_COLORS = {} end
if not GudaPlates.STUN_EFFECTS then GudaPlates.STUN_EFFECTS = {} end
if not GudaPlates.REMOVE_PENDING_PATTERNS then GudaPlates.REMOVE_PENDING_PATTERNS = {} end

-- ============================================
-- PERFORMANCE: Upvalue frequently used globals
-- Local lookups are faster than global table lookups
-- ============================================

-- Lua functions
local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring
local tonumber = tonumber
local unpack = unpack
local getglobal = getglobal

-- Lua string functions (only upvalue those actually used)
local string_find = string.find
local string_lower = string.lower
local string_format = string.format
local string_gsub = string.gsub
local string_gfind = string.gfind
local string_sub = string.sub
local string_len = string.len

-- Lua math functions
local math_floor = math.floor

-- WoW API functions (client-side)
local GetTime = GetTime
local UnitExists = UnitExists
local UnitName = UnitName
local UnitLevel = UnitLevel
local UnitClass = UnitClass
local UnitIsUnit = UnitIsUnit
local UnitCanAttack = UnitCanAttack
local UnitIsFriend = UnitIsFriend
local UnitIsEnemy = UnitIsEnemy
local UnitInRaid = UnitInRaid
local UnitDebuff = UnitDebuff
local UnitCreatureType = UnitCreatureType
local GetNumPartyMembers = GetNumPartyMembers
local GetNumRaidMembers = GetNumRaidMembers
local CreateFrame = CreateFrame

-- SuperWoW API (may not exist)
local UnitGUID = UnitGUID

-- ============================================

-- Performance: Throttle intervals
local DEBUFF_UPDATE_INTERVAL = 0.1  -- Update debuffs 10 times/sec instead of every frame
GudaPlates.DEBUFF_UPDATE_INTERVAL = DEBUFF_UPDATE_INTERVAL

-- Performance: Cached WorldFrame children to avoid garbage collection
-- Only refresh when child count changes
local cachedWorldChildren = {}
local cachedWorldChildCount = 0

-- Performance: Event lookup tables (from Settings, faster than string.find)
local SPELL_EVENTS = GudaPlates.SPELL_EVENTS
local SPELL_DAMAGE_EVENTS = GudaPlates.SPELL_DAMAGE_EVENTS
local COMBAT_EVENTS = GudaPlates.COMBAT_EVENTS

-- Macro Texture Hover Only
local macroFrame = CreateFrame("Frame")

if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[GudaPlates]|r Loading...")
end

-- Disable pfUI nameplates module
local function DisablePfUINameplates()
    if pfUI then
        -- Disable the module registration
        if pfUI.modules then
            pfUI.modules["nameplates"] = nil
        end
        -- Hide existing pfUI nameplate frame if it exists
        if pfNameplates then
            pfNameplates:Hide()
            pfNameplates:UnregisterAllEvents()
        end
        -- Block pfUI nameplate creation function
        if pfUI.nameplates then
            pfUI.nameplates = nil
        end
        return true
    end
    return false
end

-- Try to disable pfUI nameplates immediately
if DisablePfUINameplates() then
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[GudaPlates]|r Disabled pfUI nameplates module")
    end
end

-- Debug flag for duration tracking
local DEBUG_DURATION = false
GudaPlates.lua_DEBUG_DURATION = DEBUG_DURATION

local function Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[GudaPlates]|r " .. tostring(msg))
    end
end
GudaPlates.Print = Print  -- Expose for Options module

-- HookScript helper - hooks a script handler without replacing existing one
-- Similar to ShaguPlates API implementation
local function HookScript(frame, script, func)
    local prev = frame:GetScript(script)
    frame:SetScript(script, function(a1, a2, a3, a4, a5, a6, a7, a8, a9)
        if prev then prev(a1, a2, a3, a4, a5, a6, a7, a8, a9) end
        func(a1, a2, a3, a4, a5, a6, a7, a8, a9)
    end)
end

local initialized = 0
local parentcount = 0
local platecount = 0
local registry = {}
GudaPlates.registry = registry  -- Expose for Options module

-- Forward declarations for functions used before they're defined
local LoadSettings
local REGION_ORDER = { "border", "glow", "name", "level", "levelicon", "raidicon" }

-- Track combat state per nameplate frame to avoid issues with same-named mobs
local superwow_active = (SpellInfo ~= nil) or (UnitGUID ~= nil) or (SUPERWOW_VERSION ~= nil) -- SuperWoW detection
-- TWThreat detection - checked dynamically since TWT may load after us
local twthreat_active = false  -- Will be updated dynamically

-- Expose for Core module
GudaPlates.superwow_active = superwow_active
GudaPlates.twthreat_active = twthreat_active
GudaPlates.REGION_ORDER = REGION_ORDER

-- Player class for debuff filtering
local _, playerClass = UnitClass("player")
playerClass = playerClass or ""
GudaPlates.playerClass = playerClass

-- Cache for player class lookups by name (cleared on zone change)
GudaPlates.playerClassCache = {}

-- Helper function to get player class by name (scans raid/party roster)
local function GetPlayerClassByName(name)
    if not name then return nil end

    local cache = GudaPlates.playerClassCache

    -- Check cache first
    if cache[name] then
        return cache[name]
    end

    -- Check if it's the player
    local playerName = UnitName("player")
    if name == playerName then
        cache[name] = playerClass
        return playerClass
    end

    -- Scan raid
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do
            local raidName, _, _, _, _, raidClass = GetRaidRosterInfo(i)
            if raidName == name then
                cache[name] = raidClass
                return raidClass
            end
        end
    else
        -- Scan party
        local numParty = GetNumPartyMembers()
        for i = 1, numParty do
            local partyUnit = "party" .. i
            if UnitExists(partyUnit) then
                local partyName = UnitName(partyUnit)
                if partyName == name then
                    local _, partyClass = UnitClass(partyUnit)
                    cache[name] = partyClass
                    return partyClass
                end
            end
        end
    end

    return nil
end
GudaPlates.GetPlayerClassByName = GetPlayerClassByName

-- Cast tracking databases
GudaPlates.castDB = GudaPlates.castDB or {}
GudaPlates.castTracker = GudaPlates.castTracker or {}
GudaPlates.debuffTracker = {}

-- Settings and other variables from GudaPlates_Settings.lua
local Settings = GudaPlates.Settings or {}
local THREAT_COLORS = GudaPlates.THREAT_COLORS or {}
local playerRole = GudaPlates.playerRole or "DPS"

-- Performance: Pre-defined stun effects list (from Settings)
local STUN_EFFECTS = GudaPlates.STUN_EFFECTS or {}
local minimapAngle = GudaPlates.minimapAngle or 220
local nameplateOverlap = GudaPlates.nameplateOverlap
local clickThrough = GudaPlates.nameplateClickThrough

local fontOptions = {
    {value = "Fonts\\ARIALN.TTF", text = "Arial Narrow (Default)"},
    {value = "Fonts\\FRIZQT__.TTF", text = "Friz Quadrata"},
    {value = "Interface\\AddOns\\GudaPlates\\fonts\\BigNoodleTitling.ttf", text = "Big Noodle Titling"},
    {value = "Interface\\AddOns\\GudaPlates\\fonts\\Continuum.ttf", text = "Continuum"},
    {value = "Interface\\AddOns\\GudaPlates\\fonts\\DieDieDie.ttf", text = "DieDieDie"},
    {value = "Interface\\AddOns\\GudaPlates\\fonts\\Expressway.ttf", text = "Expressway"},
    {value = "Interface\\AddOns\\GudaPlates\\fonts\\Homespun.ttf", text = "Homespun"},
    {value = "Interface\\AddOns\\GudaPlates\\fonts\\Hooge.ttf", text = "Hooge"},
    {value = "Interface\\AddOns\\GudaPlates\\fonts\\Myriad-Pro.ttf", text = "Myriad Pro"},
    {value = "Interface\\AddOns\\GudaPlates\\fonts\\PT-Sans-Narrow-Bold.ttf", text = "PT Sans Narrow Bold"},
    {value = "Interface\\AddOns\\GudaPlates\\fonts\\PT-Sans-Narrow-Regular.ttf", text = "PT Sans Narrow"},
    {value = "Interface\\AddOns\\GudaPlates\\fonts\\WarSansTT-Bliz-500.ttf", text = "War Sans (CJK)"},
}
GudaPlates.fontOptions = fontOptions  -- Expose for Options module

-- =============================================================================
-- Threat Module Integration
-- =============================================================================
local GetTWTankModeThreat = GudaPlates_Threat and GudaPlates_Threat.GetTWTankModeThreat
local GetGPThreatData = GudaPlates_Threat and GudaPlates_Threat.GetGPThreatData
local IsInPlayerGroup = GudaPlates_Threat and GudaPlates_Threat.IsInPlayerGroup
local IsPlayerTank = GudaPlates_Threat and GudaPlates_Threat.IsPlayerTank
local BroadcastTankMode = GudaPlates_Threat and GudaPlates_Threat.BroadcastTankMode

-- Load spell database if available
local SpellDB = GudaPlates_SpellDB
local L = setmetatable(GudaPlates_L or {}, {__index = function(t, k) return k end})

if not SpellDB then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[GudaPlates]|r ERROR: SpellDB failed to load!")
end

GudaPlates.recentMeleeCrits = GudaPlates.recentMeleeCrits or {}
GudaPlates.recentMeleeHits = GudaPlates.recentMeleeHits or {}

-- ============================================
-- LOCALE-AWARE COMBAT LOG PATTERNS
-- ============================================
local function GlobalStringToPattern(gs)
    if not gs then return nil end
    local p = string.gsub(gs, "([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = string.gsub(p, "%%%%s", "(.+)")
    p = string.gsub(p, "%%%%d", "(%%d+)")
    return p
end

local LP = {
    AFFLICTED = GlobalStringToPattern(AURAADDEDOTHERHARMFUL) or "(.+) is afflicted by (.+)%.",
    FADES = GlobalStringToPattern(AURAREMOVEDOTHER) or "(.+) fades from (.+)%.",
    PERIODIC_SELF_HIT = GlobalStringToPattern(PERIODICAURADAMAGESELFOTHER),
    PERIODIC_SELF_CRIT = GlobalStringToPattern(PERIODICAURADAMAGECRITSELFOTHER),
    PERIODIC_SUFFER = GlobalStringToPattern(PERIODICAURADAMAGEOTHERSELF),
    SPELL_HIT_SELF = GlobalStringToPattern(SPELLLOGSELFOTHER),
    SPELL_CRIT_SELF = GlobalStringToPattern(SPELLLOGCRITSELFOTHER),
    SPELL_RESIST_SELF = GlobalStringToPattern(SPELLRESISTSELFOTHER),
    SPELL_HIT_OTHER = GlobalStringToPattern(SPELLLOGOTHEROTHER),
    SPELL_CRIT_OTHER = GlobalStringToPattern(SPELLLOGCRITOTHEROTHER),
    SPELL_RESIST_OTHER = GlobalStringToPattern(SPELLRESISTOTHEROTHER),
    MELEE_CRIT_SELF = GlobalStringToPattern(COMBATHITCRITSELFOTHER),
    MELEE_HIT_SELF = GlobalStringToPattern(COMBATHITSELFOTHER),
}

-- ============================================
-- SPELL CAST HOOKS (ShaguTweaks-style)
-- ============================================
local function GetRankNumber(rankStr)
    if not rankStr then return 0 end
    for num in string_gfind(rankStr, "(%d+)") do
        return tonumber(num) or 0
    end
    return 0
end

local function GetSpellInfoFromBook(spellId, bookType)
    local name, rank = GetSpellName(spellId, bookType)
    return name, GetRankNumber(rank)
end

local localizedRankWord = RANK or "Rank"

local function ParseSpellName(spellString)
    if not spellString then return nil, 0 end
    for name, rank in string_gfind(spellString, "^(.+)%(" .. localizedRankWord .. " (%d+)%)$") do
        return name, tonumber(rank) or 0
    end
    if localizedRankWord ~= "Rank" then
        for name, rank in string_gfind(spellString, "^(.+)%(Rank (%d+)%)$") do
            return name, tonumber(rank) or 0
        end
    end
    return spellString, 0
end

local function StripSpellRank(spellString)
    if not spellString then return nil, 0 end
    for name, rank in string_gfind(spellString, "^(.+) %(" .. localizedRankWord .. " (%d+)%)$") do
        return name, tonumber(rank) or 0
    end
    for name, rank in string_gfind(spellString, "^(.+)%(" .. localizedRankWord .. " (%d+)%)$") do
        return name, tonumber(rank) or 0
    end
    if localizedRankWord ~= "Rank" then
        for name, rank in string_gfind(spellString, "^(.+) %(Rank (%d+)%)$") do
            return name, tonumber(rank) or 0
        end
        for name, rank in string_gfind(spellString, "^(.+)%(Rank (%d+)%)$") do
            return name, tonumber(rank) or 0
        end
    end

    for name, rank in string_gfind(spellString, "^(.+) (VI)$") do return name, 6 end
    for name, rank in string_gfind(spellString, "^(.+) (V)$") do return name, 5 end
    for name, rank in string_gfind(spellString, "^(.+) (IV)$") do return name, 4 end
    for name, rank in string_gfind(spellString, "^(.+) (III)$") do return name, 3 end
    for name, rank in string_gfind(spellString, "^(.+) (II)$") do return name, 2 end

    return spellString, 0
end

local Original_CastSpell = CastSpell
CastSpell = function(spellId, bookType)
    if SpellDB and spellId and bookType then
        local spellName, rank = GetSpellName(spellId, bookType)
        local texture = GetSpellTexture(spellId, bookType)
        local englishName = SpellDB:ResolveSpellName(spellName, texture)
        if englishName and UnitExists("target") and UnitCanAttack("player", "target") then
            local targetName = UnitName("target")
            local targetLevel = UnitLevel("target") or 0
            local duration = SpellDB:GetDuration(englishName, rank)
            if duration and duration > 0 then
                SpellDB:AddPending(targetName, targetLevel, englishName, duration)
            end
        end
    end
    return Original_CastSpell(spellId, bookType)
end

local Original_CastSpellByName = CastSpellByName
CastSpellByName = function(spellString, onSelf)
    if SpellDB and spellString then
        local spellName, rank = ParseSpellName(spellString)
        local englishName = SpellDB:ResolveSpellName(spellName, nil)
        if englishName and UnitExists("target") and UnitCanAttack("player", "target") then
            local targetName = UnitName("target")
            local targetLevel = UnitLevel("target") or 0
            local duration = SpellDB:GetDuration(englishName, rank)
            if duration and duration > 0 then
                SpellDB:AddPending(targetName, targetLevel, englishName, duration)
            end
        end
    end
    return Original_CastSpellByName(spellString, onSelf)
end

local Original_UseAction = UseAction
UseAction = function(slot, checkCursor, onSelf)
    if SpellDB and slot then
        local actionTexture = GetActionTexture(slot)
        if GetActionText(slot) == nil and actionTexture ~= nil then
            local spellName, rank = SpellDB:ScanAction(slot)
            if spellName then
                if SpellDB.textureToSpell and not SpellDB.textureToSpell[actionTexture] then
                    SpellDB.textureToSpell[actionTexture] = spellName
                end
                if UnitExists("target") then
                    local targetName = UnitName("target")
                    local targetLevel = UnitLevel("target") or 0
                    local duration = SpellDB:GetDuration(spellName, rank)
                    if duration and duration > 0 then
                        SpellDB:AddPending(targetName, targetLevel, spellName, duration)
                    end
                end
            end
        end
    end
    return Original_UseAction(slot, checkCursor, onSelf)
end

if SpellDB then
    SpellDB:InitScanner()
end

local IsNamePlate = function(frame)
    return GudaPlates_Scanner.IsNamePlate(frame)
end

local DisableObject = GudaPlates_Hide.DisableObject
local HideVisual = GudaPlates_Hide.HideVisual
GudaPlates.DisableObject = DisableObject
GudaPlates.HideVisual = HideVisual
GudaPlates.IsNamePlate = IsNamePlate

GudaPlates.getPlateCount = function() return platecount end
GudaPlates.incPlateCount = function() platecount = platecount + 1; return platecount end

local GudaPlatesEventFrame = CreateFrame("Frame", "GudaPlatesFrame", UIParent)
GudaPlatesEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
GudaPlatesEventFrame:RegisterEvent("ADDON_LOADED")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_BUFF")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_TRADESKILLS")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_OTHER")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_SELF")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_PARTY_BUFF")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_SELF_BUFF")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_COMBAT_PARTY_HITS")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_RANGED_HITS")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_COMBAT_PARTY_RANGED_HITS")
GudaPlatesEventFrame:RegisterEvent("UNIT_CASTEVENT")
GudaPlatesEventFrame:RegisterEvent("SPELLCAST_STOP")
GudaPlatesEventFrame:RegisterEvent("CHAT_MSG_SPELL_FAILED_LOCALPLAYER")
GudaPlatesEventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
GudaPlatesEventFrame:RegisterEvent("UNIT_AURA")
GudaPlatesEventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
GudaPlatesEventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
GudaPlatesEventFrame:RegisterEvent("PLAYER_LEVEL_UP")
GudaPlatesEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
GudaPlatesEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

local playerInCombat = UnitAffectingCombat and UnitAffectingCombat("player") or false
local REMOVE_PENDING_PATTERNS = GudaPlates.REMOVE_PENDING_PATTERNS

-- =============================================================================
-- WoWTranslate Bridge Function
-- Bridges GudaPlates' synchronous draw loop with the async DLL engine
-- =============================================================================
local function GetNameTranslation(name)
    if not name or name == "" then return nil end
    
    -- 1. Check instant glossary
    if WoWTranslateGlossary and WoWTranslateGlossary[name] then
        return WoWTranslateGlossary[name]
    end
    
    -- 2. Check persistent local cache
    if WoWTranslate_CacheGet then
        local cached = WoWTranslate_CacheGet(name)
        if cached then return cached end
    end
    
    -- 3. Background Async Request if not cached yet
    if WoWTranslate_API and WoWTranslate_API.IsAvailable and WoWTranslate_API.IsAvailable() then
        WoWTranslate_API.Translate(name, function(translation, err)
            if translation and translation ~= "" and WoWTranslate_CacheSave then
                WoWTranslate_CacheSave(name, translation)
            end
        end, "zh")
    end
    
    return nil
end

local function UpdateNamePlateDimensions(frame)
    local nameplate = frame.nameplate
    if not nameplate then return end

    local isFriendly = nameplate.cachedIsFriendly
    if isFriendly == nil then
        local r, g, b = nameplate.original.healthbar:GetStatusBarColor()
        local isHostile = r > 0.9 and g < 0.2 and b < 0.2
        local isNeutral = r > 0.9 and g > 0.9 and b < 0.2
        isFriendly = not isHostile and not isNeutral
    end

    local usePlayerDimensions = isFriendly
    if not usePlayerDimensions and GudaPlates_Players and GudaPlates_Players.ShouldUsePlayerDimensions then
        usePlayerDimensions = GudaPlates_Players.ShouldUsePlayerDimensions(nameplate, Settings, isFriendly)
    end

    local hHeight, hWidth, hFontSize, hTextPos, lFontSize, nFontSize
    if usePlayerDimensions then
        hHeight = Settings.friendHealthbarHeight
        hWidth = Settings.friendHealthbarWidth
        hFontSize = Settings.friendHealthFontSize
        hTextPos = Settings.friendHealthTextPosition
        lFontSize = Settings.friendLevelFontSize
        nFontSize = Settings.friendNameFontSize
    else
        hHeight = Settings.healthbarHeight
        hWidth = Settings.healthbarWidth
        hFontSize = Settings.healthFontSize
        hTextPos = Settings.healthTextPosition
        lFontSize = Settings.levelFontSize
        nFontSize = Settings.nameFontSize
    end

    nameplate.health:SetHeight(hHeight)
    nameplate.health:SetWidth(hWidth)

    local cHeight, cIndependent, cWidth
    if usePlayerDimensions then
        cHeight = Settings.friendCastbarHeight
        cIndependent = Settings.friendCastbarIndependent
        cWidth = Settings.friendCastbarWidth
    else
        cHeight = Settings.castbarHeight
        cIndependent = Settings.castbarIndependent
        cWidth = Settings.castbarWidth
    end

    nameplate.castbar:SetHeight(cHeight)
    if cIndependent then
        nameplate.castbar:SetWidth(cWidth)
    else
        nameplate.castbar:SetWidth(hWidth)
    end
    
    local iconSize
    if cIndependent and cWidth > hWidth then
        if nameplate.mana and nameplate.mana:IsShown() then
            iconSize = hHeight + Settings.manabarHeight
        else
            iconSize = hHeight
        end
    else
        if nameplate.mana and nameplate.mana:IsShown() then
            iconSize = hHeight + cHeight + Settings.manabarHeight
        else
            iconSize = hHeight + cHeight
        end
    end
    nameplate.castbar.icon:SetWidth(iconSize)
    nameplate.castbar.icon:SetHeight(iconSize)
    
    if nameplate.mana then
        local mManaHeight, mManaTextPos
        if usePlayerDimensions then
            mManaHeight = Settings.friendManabarHeight
            mManaTextPos = Settings.friendManaTextPosition
        else
            mManaHeight = Settings.manabarHeight
            mManaTextPos = Settings.manaTextPosition
        end
        
        nameplate.mana:SetWidth(hWidth)
        nameplate.mana:SetHeight(mManaHeight)
        
        if nameplate.mana.text then
            nameplate.mana.text:ClearAllPoints()
            if mManaTextPos == "LEFT" then
                nameplate.mana.text:SetPoint("LEFT", nameplate.mana, "LEFT", 2, 0)
                nameplate.mana.text:SetJustifyH("LEFT")
            elseif mManaTextPos == "RIGHT" then
                nameplate.mana.text:SetPoint("RIGHT", nameplate.mana, "RIGHT", -2, 0)
                nameplate.mana.text:SetJustifyH("RIGHT")
            else
                nameplate.mana.text:SetPoint("CENTER", nameplate.mana, "CENTER", 0, 0)
                nameplate.mana.text:SetJustifyH("CENTER")
            end
        end
    end

    local healthFont, _, healthFlags = nameplate.healthtext:GetFont()
    nameplate.healthtext:SetFont(healthFont, hFontSize, healthFlags)
    
    nameplate.healthtext:ClearAllPoints()
    if hTextPos == "LEFT" then
        nameplate.healthtext:SetPoint("LEFT", nameplate.health, "LEFT", 2, 0)
        nameplate.healthtext:SetJustifyH("LEFT")
    elseif hTextPos == "RIGHT" then
        nameplate.healthtext:SetPoint("RIGHT", nameplate.health, "RIGHT", -2, 0)
        nameplate.healthtext:SetJustifyH("RIGHT")
    else
        nameplate.healthtext:SetPoint("CENTER", nameplate.health, "CENTER", 0, 0)
        nameplate.healthtext:SetJustifyH("CENTER")
    end

    nameplate.level:SetFont(Settings.textFont, lFontSize, "OUTLINE")
    nameplate.name:SetFont(Settings.textFont, nFontSize, "OUTLINE")
    nameplate.healthtext:SetFont(Settings.textFont, hFontSize, "OUTLINE")
    if nameplate.mana and nameplate.mana.text then
        nameplate.mana.text:SetFont(Settings.textFont, 7, "OUTLINE")
    end
    if nameplate.castbar then
        nameplate.castbar.text:SetFont(Settings.textFont, 8, "OUTLINE")
        nameplate.castbar.timer:SetFont(Settings.textFont, 8, "OUTLINE")
    end
    if nameplate.debuffs then
        for i = 1, GudaPlates_Debuffs:GetMaxDebuffs() do
            if nameplate.debuffs[i] then
                nameplate.debuffs[i].cd:SetFont(Settings.textFont, 10, "OUTLINE")
                nameplate.debuffs[i].count:SetFont(Settings.textFont, 9, "OUTLINE")
            end
        end
    end

    nameplate.name:SetTextColor(Settings.nameColor[1], Settings.nameColor[2], Settings.nameColor[3], Settings.nameColor[4])
    if GudaPlates_Level then
        local levelText = nameplate.original.level and nameplate.original.level:GetText()
        GudaPlates_Level.ApplyLevelColor(nameplate, levelText)
    end
    nameplate.healthtext:SetTextColor(Settings.healthTextColor[1], Settings.healthTextColor[2], Settings.healthTextColor[3], Settings.healthTextColor[4])
    if nameplate.mana and nameplate.mana.text then
        nameplate.mana.text:SetTextColor(Settings.manaTextColor[1], Settings.manaTextColor[2], Settings.manaTextColor[3], Settings.manaTextColor[4])
    end
    
    if nameplate.castbar then
        nameplate.castbar:SetStatusBarColor(Settings.castbarColor[1], Settings.castbarColor[2], Settings.castbarColor[3], Settings.castbarColor[4])
    end

    if nameplate.original.raidicon then
        nameplate.original.raidicon:ClearAllPoints()
        if Settings.raidIconPosition == "LEFT" then
            nameplate.original.raidicon:SetPoint("RIGHT", nameplate.health, "LEFT", -5, 0)
        else
            nameplate.original.raidicon:SetPoint("LEFT", nameplate.health, "RIGHT", 5, 0)
        end
    end
    if frame.raidicon and frame.raidicon ~= nameplate.original.raidicon then
        frame.raidicon:ClearAllPoints()
        if Settings.raidIconPosition == "LEFT" then
            frame.raidicon:SetPoint("RIGHT", nameplate.health, "LEFT", -5, 0)
        else
            frame.raidicon:SetPoint("LEFT", nameplate.health, "RIGHT", 5, 0)
        end
    end

    nameplate.name:ClearAllPoints()
    
    if nameplate.mana then
        nameplate.mana:ClearAllPoints()
    end
    
    if Settings.swapNameDebuff then
        nameplate.name:SetPoint("BOTTOM", nameplate.health, "TOP", 0, 6)
        if nameplate.mana then
            nameplate.mana:SetPoint("TOP", nameplate.health, "BOTTOM", 0, 0)
        end
        for i = 1, GudaPlates_Debuffs:GetMaxDebuffs() do
            nameplate.debuffs[i]:ClearAllPoints()
            if i == 1 then
                if nameplate.mana and nameplate.mana:IsShown() then
                    nameplate.debuffs[i]:SetPoint("TOPLEFT", nameplate.mana, "BOTTOMLEFT", 0, -1)
                else
                    nameplate.debuffs[i]:SetPoint("TOPLEFT", nameplate.health, "BOTTOMLEFT", 0, -1)
                end
            else
                nameplate.debuffs[i]:SetPoint("LEFT", nameplate.debuffs[i-1], "RIGHT", 1, 0)
            end
        end
        nameplate.castbar:ClearAllPoints()
        if Settings.castbarIndependent and Settings.castbarWidth > Settings.healthbarWidth then
            if Settings.raidIconPosition == "RIGHT" then
                nameplate.castbar:SetPoint("BOTTOMRIGHT", nameplate.health, "TOPRIGHT", 0, 2)
            else
                nameplate.castbar:SetPoint("BOTTOMLEFT", nameplate.health, "TOPLEFT", 0, 2)
            end
        else
            nameplate.castbar:SetPoint("BOTTOM", nameplate.health, "TOP", 0, 2)
        end
        nameplate.level:ClearAllPoints()
        nameplate.level:SetPoint("BOTTOMRIGHT", nameplate.health, "TOPRIGHT", 0, 2)
    else
        nameplate.name:SetPoint("TOP", nameplate.health, "BOTTOM", 0, -6)
        if nameplate.mana then
            nameplate.mana:SetPoint("BOTTOM", nameplate.health, "TOP", 0, 0)
        end
        nameplate.level:ClearAllPoints()
        if nameplate.mana and nameplate.mana:IsShown() then
            nameplate.level:SetPoint("BOTTOMRIGHT", nameplate.mana, "TOPRIGHT", 0, 2)
        else
            nameplate.level:SetPoint("BOTTOMRIGHT", nameplate.health, "TOPRIGHT", 0, 2)
        end
        for i = 1, GudaPlates_Debuffs:GetMaxDebuffs() do
            nameplate.debuffs[i]:ClearAllPoints()
            if i == 1 then
                if nameplate.mana and nameplate.mana:IsShown() then
                    nameplate.debuffs[i]:SetPoint("BOTTOMLEFT", nameplate.mana, "TOPLEFT", 0, 1)
                else
                    nameplate.debuffs[i]:SetPoint("BOTTOMLEFT", nameplate.health, "TOPLEFT", 0, 1)
                end
            else
                nameplate.debuffs[i]:SetPoint("LEFT", nameplate.debuffs[i-1], "RIGHT", 1, 0)
            end
        end
        nameplate.castbar:ClearAllPoints()
        if Settings.castbarIndependent and Settings.castbarWidth > Settings.healthbarWidth then
            if Settings.raidIconPosition == "RIGHT" then
                nameplate.castbar:SetPoint("TOPRIGHT", nameplate.health, "BOTTOMRIGHT", 0, -2)
            else
                nameplate.castbar:SetPoint("TOPLEFT", nameplate.health, "BOTTOMLEFT", 0, -2)
            end
        else
            nameplate.castbar:SetPoint("TOP", nameplate.health, "BOTTOM", 0, -2)
        end
    end

    if not nameplateOverlap then
        local npWidth = Settings.healthbarWidth * UIParent:GetScale()
        local npHeight = (Settings.healthbarHeight + 20) * UIParent:GetScale()
        frame:SetWidth(npWidth)
        frame:SetHeight(npHeight)
        nameplate:SetAllPoints(frame)
    else
        nameplate:ClearAllPoints()
        nameplate:SetPoint("CENTER", frame, "CENTER", 0, 0)
        nameplate:SetWidth(Settings.healthbarWidth)
        nameplate:SetHeight(Settings.healthbarHeight + 20)
    end
end
GudaPlates.UpdateNamePlateDimensions = UpdateNamePlateDimensions

local function NamePlate_OnShow()
    local frame = this
    local nameplate = registry[frame]
    if not nameplate then return end

    local original = nameplate.original
    if not original then return end

    if original.healthbar then
        original.healthbar:SetStatusBarTexture("")
        original.healthbar:SetAlpha(0)
    end

    if original.name then
        if original.name.SetTextColor then original.name:SetTextColor(0, 0, 0, 0) end
        if original.name.SetAlpha then original.name:SetAlpha(0) end
        if original.name.Hide then original.name:Hide() end
    end
    if original.level then
        if original.level.SetTextColor then original.level:SetTextColor(0, 0, 0, 0) end
        if original.level.SetAlpha then original.level:SetAlpha(0) end
        if original.level.Hide then original.level:Hide() end
    end

    local cachedRegions = nameplate.cachedRegions
    local regionsCount = nameplate.cachedRegionsCount or 0
    for i = 1, regionsCount do
        local region = cachedRegions[i]
        if region and region ~= original.raidicon and region ~= frame.raidicon then
            if region.SetAlpha then region:SetAlpha(0) end
            if region.SetTextColor then region:SetTextColor(0, 0, 0, 0) end
            if region.Hide then region:Hide() end
        end
    end

    if frame.new then
        frame.new:SetAlpha(0)
        if frame.new.Hide then frame.new:Hide() end
        local newRegions = nameplate.cachedNewRegions
        if newRegions then
            for i = 1, nameplate.cachedNewRegionsCount or 0 do
                local region = newRegions[i]
                if region then
                    if region.SetTextColor then region:SetTextColor(0, 0, 0, 0) end
                    if region.SetAlpha then region:SetAlpha(0) end
                    if region.Hide then region:Hide() end
                end
            end
        end
    end

    nameplate.overlapApplied = nil

    if GudaPlates_Healthbar and GudaPlates_Healthbar.ResetCache then
        GudaPlates_Healthbar.ResetCache(nameplate)
    end

    if GudaPlates_Players and GudaPlates_Players.ResetCache then
        GudaPlates_Players.ResetCache(nameplate)
    end

    if nameplate.skullIcon then
        nameplate.skullIcon:Hide()
    end
    if nameplate.level then
        local levelText = nil
        if original.level and original.level.GetText then
            levelText = original.level:GetText()
        end
        if levelText and levelText ~= "" and levelText ~= "-1" and levelText ~= "??" then
            nameplate.level:SetText(levelText)
        end
        nameplate.level:Show()
    end

    if GudaPlates_Filter and GudaPlates_Filter.ShouldSkipNameplate then
        if GudaPlates_Filter.ShouldSkipNameplate(frame, nameplate, original, GudaPlates.Settings) then
            nameplate:Hide()
            return
        end
    end

    if not nameplate.showAfter and not nameplate:IsShown() then
        nameplate:Show()
    end

    if GudaPlates.EnableOnUpdate then
        GudaPlates.EnableOnUpdate()
    end
end

local function NamePlate_OnHide()
    local frame = this
    local nameplate = registry[frame]
    if not nameplate then return end

    local original = nameplate.original
    nameplate:Hide()

    nameplate.lastHP = nil
    nameplate.lastHPMax = nil
    nameplate.lastHTextFormat = nil
    nameplate.lastLevelText = nil
    nameplate.lastNameText = nil

    if original then
        if original.name then
            if original.name.SetTextColor then original.name:SetTextColor(0, 0, 0, 0) end
            if original.name.SetAlpha then original.name:SetAlpha(0) end
            if original.name.Hide then original.name:Hide() end
        end
        if original.level then
            if original.level.SetTextColor then original.level:SetTextColor(0, 0, 0, 0) end
            if original.level.SetAlpha then original.level:SetAlpha(0) end
            if original.level.Hide then original.level:Hide() end
        end
    end

    if frame.new then
        if frame.new.SetAlpha then frame.new:SetAlpha(0) end
        if frame.new.Hide then frame.new:Hide() end
    end

    nameplate.showAfter = GetTime() + 0.1
end

local function HandleNamePlate(frame)
    if not frame then return end
    if registry[frame] then return end

    local healthbar = frame.healthbar or frame:GetChildren()
    if healthbar then
        healthbar:SetAlpha(0)
        healthbar:SetStatusBarTexture("")
    end
    local r1, r2, r3, r4, r5, r6 = frame:GetRegions()
    if r1 and r1.SetAlpha then r1:SetAlpha(0) end
    if r2 and r2.SetAlpha then r2:SetAlpha(0) end
    if r3 then
        if r3.SetAlpha then r3:SetAlpha(0) end
        if r3.SetTextColor then r3:SetTextColor(0, 0, 0, 0) end
        if r3.Hide then r3:Hide() end
    end
    if r4 then
        if r4.SetAlpha then r4:SetAlpha(0) end
        if r4.SetTextColor then r4:SetTextColor(0, 0, 0, 0) end
        if r4.Hide then r4:Hide() end
    end
    if r5 and r5.SetAlpha then r5:SetAlpha(0) end

    if frame.new and frame.new.SetAlpha then
        frame.new:SetAlpha(0)
        if frame.new.Hide then frame.new:Hide() end
        local nr1, nr2, nr3, nr4 = frame.new:GetRegions()
        if nr1 and nr1.SetTextColor then nr1:SetTextColor(0, 0, 0, 0) end
        if nr2 and nr2.SetTextColor then nr2:SetTextColor(0, 0, 0, 0) end
        if nr3 and nr3.SetTextColor then nr3:SetTextColor(0, 0, 0, 0) end
        if nr4 and nr4.SetTextColor then nr4:SetTextColor(0, 0, 0, 0) end
    end

    local existingOverlay = nil
    local numChildren = frame:GetNumChildren()
    if numChildren > 1 then
        local children = { frame:GetChildren() }
        for i = 1, numChildren do
            local child = children[i]
            if child and child.platename and string.find(child.platename, "GudaPlate") then
                existingOverlay = child
                break
            end
        end
    end

    if existingOverlay then
        local nameplate = existingOverlay
        nameplate.lastHP = nil
        nameplate.lastHPMax = nil
        nameplate.lastHTextFormat = nil
        nameplate.lastLevelText = nil
        nameplate.lastNameText = nil
        nameplate.showAfter = GetTime() + 0.1
        nameplate:Hide()
        registry[frame] = nameplate
        return
    end

    platecount = platecount + 1
    local platename = "GudaPlate" .. platecount
    local nameplate = CreateFrame("Button", platename, frame)
    nameplate.platename = platename
    nameplate:EnableMouse(false)
    nameplate.parent = frame
    nameplate.original = {}

    nameplate:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    nameplate:SetScript("OnClick", function()
        if arg1 == "LeftButton" then
            this.parent:Click()
        elseif arg1 == "RightButton" then
            this.parent:Click()
        end
    end)

    nameplate.original.healthbar = healthbar

    local regions = {frame:GetRegions()}
    nameplate.cachedRegions = regions
    nameplate.cachedRegionsCount = table.getn(regions)
    nameplate.cachedChildren = {frame:GetChildren()}
    nameplate.cachedChildCount = frame:GetNumChildren()

    for i, region in ipairs(regions) do
        if region and region.GetObjectType then
            local rtype = region:GetObjectType()
            if i == 2 then
                nameplate.original.glow = region
            elseif i == 5 then
                nameplate.original.levelicon = region
            elseif i == 6 then
                nameplate.original.raidicon = region
            elseif rtype == "FontString" then
                local text = region:GetText()
                if text then
                    if tonumber(text) then
                        nameplate.original.level = region
                    else
                        nameplate.original.name = region
                    end
                end
            end
        end
    end

    if frame.new then
        nameplate.cachedNewRegions = {frame.new:GetRegions()}
        nameplate.cachedNewRegionsCount = table.getn(nameplate.cachedNewRegions)
        for i = 1, nameplate.cachedNewRegionsCount do
            local region = nameplate.cachedNewRegions[i]
            if region and region.GetObjectType then
                local rtype = region:GetObjectType()
                if rtype == "FontString" then
                    local text = region:GetText()
                    if text and not tonumber(text) and not nameplate.original.name then
                        nameplate.original.name = region
                    end
                end
            end
        end
    end

    nameplate:SetAllPoints(frame)
    nameplate:SetFrameStrata("BACKGROUND")
    nameplate:SetFrameLevel(frame:GetFrameLevel() + 10)

    nameplate.health = CreateFrame("StatusBar", nil, nameplate)
    nameplate.health:SetFrameLevel(frame:GetFrameLevel() + 11)
    nameplate.health:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    nameplate.health:SetHeight(Settings.healthbarHeight)
    nameplate.health:SetWidth(Settings.healthbarWidth)
    nameplate.health:SetPoint("CENTER", nameplate, "CENTER", 0, 0)

    nameplate.health.bg = nameplate.health:CreateTexture(nil, "BACKGROUND")
    nameplate.health.bg:SetTexture(0, 0, 0, 0.8)
    nameplate.health.bg:SetAllPoints()

    nameplate.health.border = nameplate.health:CreateTexture(nil, "OVERLAY")
    nameplate.health.border:SetTexture(0, 0, 0, 1)
    nameplate.health.border:SetPoint("TOPLEFT", nameplate.health, "TOPLEFT", -1, 1)
    nameplate.health.border:SetPoint("BOTTOMRIGHT", nameplate.health, "BOTTOMRIGHT", 1, -1)
    nameplate.health.border:SetDrawLayer("BACKGROUND", -1)

    if nameplate.original.raidicon then
        nameplate.original.raidicon:SetParent(nameplate.health)
        nameplate.original.raidicon:ClearAllPoints()
        nameplate.original.raidicon:SetPoint("RIGHT", nameplate.health, "LEFT", -5, 0)
        nameplate.original.raidicon:SetWidth(24)
        nameplate.original.raidicon:SetHeight(24)
        nameplate.original.raidicon:SetDrawLayer("OVERLAY")
    end

    if frame.raidicon and frame.raidicon ~= nameplate.original.raidicon then
        frame.raidicon:SetParent(nameplate.health)
        frame.raidicon:ClearAllPoints()
        frame.raidicon:SetPoint("RIGHT", nameplate.health, "LEFT", -5, 0)
        frame.raidicon:SetWidth(24)
        frame.raidicon:SetHeight(24)
        frame.raidicon:SetDrawLayer("OVERLAY")
    end

    nameplate.targetBracket = {}
    
    nameplate.targetBracket.leftVert = nameplate.health:CreateTexture(nil, "OVERLAY")
    nameplate.targetBracket.leftVert:SetTexture(1, 1, 1, 0.5)
    nameplate.targetBracket.leftVert:SetWidth(1)
    nameplate.targetBracket.leftVert:Hide()
    
    nameplate.targetBracket.leftTop = nameplate.health:CreateTexture(nil, "OVERLAY")
    nameplate.targetBracket.leftTop:SetTexture(1, 1, 1, 0.5)
    nameplate.targetBracket.leftTop:SetHeight(1)
    nameplate.targetBracket.leftTop:SetWidth(6)
    nameplate.targetBracket.leftTop:Hide()
    
    nameplate.targetBracket.leftBottom = nameplate.health:CreateTexture(nil, "OVERLAY")
    nameplate.targetBracket.leftBottom:SetTexture(1, 1, 1, 0.5)
    nameplate.targetBracket.leftBottom:SetHeight(1)
    nameplate.targetBracket.leftBottom:SetWidth(6)
    nameplate.targetBracket.leftBottom:Hide()
    
    nameplate.targetBracket.rightVert = nameplate.health:CreateTexture(nil, "OVERLAY")
    nameplate.targetBracket.rightVert:SetTexture(1, 1, 1, 0.5)
    nameplate.targetBracket.rightVert:SetWidth(1)
    nameplate.targetBracket.rightVert:Hide()
    
    nameplate.targetBracket.rightTop = nameplate.health:CreateTexture(nil, "OVERLAY")
    nameplate.targetBracket.rightTop:SetTexture(1, 1, 1, 0.5)
    nameplate.targetBracket.rightTop:SetHeight(1)
    nameplate.targetBracket.rightTop:SetWidth(6)
    nameplate.targetBracket.rightTop:Hide()
    
    nameplate.targetBracket.rightBottom = nameplate.health:CreateTexture(nil, "OVERLAY")
    nameplate.targetBracket.rightBottom:SetTexture(1, 1, 1, 0.5)
    nameplate.targetBracket.rightBottom:SetHeight(1)
    nameplate.targetBracket.rightBottom:SetWidth(6)
    nameplate.targetBracket.rightBottom:Hide()

    nameplate.targetGlowTop = nameplate:CreateTexture(nil, "BACKGROUND")
    nameplate.targetGlowTop:SetTexture("Interface\\AddOns\\-Dragonflight3\\media\\tex\\generic\\nocontrol_glow.blp")
    nameplate.targetGlowTop:SetWidth(Settings.healthbarWidth)
    nameplate.targetGlowTop:SetHeight(20)
    nameplate.targetGlowTop:SetPoint("BOTTOM", nameplate.health, "TOP", 0, 0)
    nameplate.targetGlowTop:SetVertexColor(Settings.targetGlowColor[1], Settings.targetGlowColor[2], Settings.targetGlowColor[3], 0.4)
    nameplate.targetGlowTop:Hide()

    nameplate.targetGlowBottom = nameplate:CreateTexture(nil, "BACKGROUND")
    nameplate.targetGlowBottom:SetTexture("Interface\\AddOns\\-Dragonflight3\\media\\tex\\generic\\nocontrol_glow.blp")
    nameplate.targetGlowBottom:SetTexCoord(0, 1, 1, 0)
    nameplate.targetGlowBottom:SetWidth(Settings.healthbarWidth)
    nameplate.targetGlowBottom:SetHeight(20)
    nameplate.targetGlowBottom:SetPoint("TOP", nameplate.health, "BOTTOM", 0, 0)
    nameplate.targetGlowBottom:SetVertexColor(Settings.targetGlowColor[1], Settings.targetGlowColor[2], Settings.targetGlowColor[3], 0.4)
    nameplate.targetGlowBottom:Hide()

    nameplate.name = nameplate:CreateFontString(nil, "OVERLAY")
    nameplate.name:SetFont(Settings.textFont, 9, "OUTLINE")
    nameplate.name:SetTextColor(Settings.nameColor[1], Settings.nameColor[2], Settings.nameColor[3], Settings.nameColor[4])
    nameplate.name:SetJustifyH("CENTER")

    nameplate.level = nameplate:CreateFontString(nil, "OVERLAY")
    nameplate.level:SetFont(Settings.textFont, 9, "OUTLINE")
    nameplate.level:SetPoint("BOTTOMRIGHT", nameplate.health, "TOPRIGHT", 0, 2)
    if GudaPlates_Level then
        GudaPlates_Level.InitializeLevel(nameplate, nameplate.original)
    else
        nameplate.level:SetTextColor(Settings.levelColor[1], Settings.levelColor[2], Settings.levelColor[3], Settings.levelColor[4])
    end
    nameplate.level:SetJustifyH("RIGHT")

    nameplate.skullIcon = nameplate:CreateTexture(nil, "OVERLAY")
    nameplate.skullIcon:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
    nameplate.skullIcon:SetWidth(14)
    nameplate.skullIcon:SetHeight(14)
    nameplate.skullIcon:SetPoint("BOTTOMRIGHT", nameplate.health, "TOPRIGHT", 2, 2)
    nameplate.skullIcon:Hide()

    nameplate.healthtext = nameplate.health:CreateFontString(nil, "OVERLAY")
    nameplate.healthtext:SetFont(Settings.textFont, 8, "OUTLINE")
    nameplate.healthtext:SetPoint("CENTER", nameplate.health, "CENTER", 0, 0)
    nameplate.healthtext:SetTextColor(Settings.healthTextColor[1], Settings.healthTextColor[2], Settings.healthTextColor[3], Settings.healthTextColor[4])

    nameplate.mana = CreateFrame("StatusBar", nil, nameplate)
    nameplate.mana:SetFrameLevel(frame:GetFrameLevel() + 11)
    nameplate.mana:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    nameplate.mana:SetStatusBarColor(unpack(THREAT_COLORS.MANA_BAR))
    nameplate.mana:SetHeight(Settings.manabarHeight)
    nameplate.mana:SetWidth(Settings.healthbarWidth)
    nameplate.mana:SetPoint("TOP", nameplate.health, "BOTTOM", 0, 0)
    nameplate.mana:Hide()

    nameplate.mana.bg = nameplate.mana:CreateTexture(nil, "BACKGROUND")
    nameplate.mana.bg:SetTexture(0, 0, 0, 0.8)
    nameplate.mana.bg:SetAllPoints()

    nameplate.mana.border = nameplate.mana:CreateTexture(nil, "OVERLAY")
    nameplate.mana.border:SetTexture(0, 0, 0, 1)
    nameplate.mana.border:SetPoint("TOPLEFT", nameplate.mana, "TOPLEFT", -1, 1)
    nameplate.mana.border:SetPoint("BOTTOMRIGHT", nameplate.mana, "BOTTOMRIGHT", 1, -1)
    nameplate.mana.border:SetDrawLayer("BACKGROUND", -1)

    nameplate.mana.text = nameplate.mana:CreateFontString(nil, "OVERLAY")
    nameplate.mana.text:SetFont(Settings.textFont, 7, "OUTLINE")
    nameplate.mana.text:SetTextColor(Settings.manaTextColor[1], Settings.manaTextColor[2], Settings.manaTextColor[3], Settings.manaTextColor[4])

    local cbHeight = Settings.castbarHeight or 12
    local cbColor = Settings.castbarColor or {1, 0.8, 0, 1}
    local textFont = Settings.textFont or "Fonts\\ARIALN.TTF"
    local hbHeight = Settings.healthbarHeight or 14

    nameplate.castbar = CreateFrame("StatusBar", nil, nameplate)
    nameplate.castbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    nameplate.castbar:SetHeight(cbHeight)
    nameplate.castbar:SetStatusBarColor(cbColor[1], cbColor[2], cbColor[3], cbColor[4] or 1)
    nameplate.castbar:Hide()

    nameplate.castbar.bg = nameplate.castbar:CreateTexture(nil, "BACKGROUND")
    nameplate.castbar.bg:SetTexture(0, 0, 0, 1.0)
    nameplate.castbar.bg:SetAllPoints()

    nameplate.castbar.border = nameplate.castbar:CreateTexture(nil, "OVERLAY")
    nameplate.castbar.border:SetTexture(0, 0, 0, 1)
    nameplate.castbar.border:SetPoint("TOPLEFT", nameplate.castbar, "TOPLEFT", -1, 1)
    nameplate.castbar.border:SetPoint("BOTTOMRIGHT", nameplate.castbar, "BOTTOMRIGHT", 1, -1)
    nameplate.castbar.border:SetDrawLayer("BACKGROUND", -1)

    nameplate.castbar.text = nameplate.castbar:CreateFontString(nil, "OVERLAY")
    nameplate.castbar.text:SetFont(textFont, 8, "OUTLINE")
    nameplate.castbar.text:SetPoint("LEFT", nameplate.castbar, "LEFT", 2, 0)
    nameplate.castbar.text:SetTextColor(1, 1, 1, 1)
    nameplate.castbar.text:SetJustifyH("LEFT")

    nameplate.castbar.timer = nameplate.castbar:CreateFontString(nil, "OVERLAY")
    nameplate.castbar.timer:SetFont(textFont, 8, "OUTLINE")
    nameplate.castbar.timer:SetPoint("RIGHT", nameplate.castbar, "RIGHT", -2, 0)
    nameplate.castbar.timer:SetTextColor(1, 1, 1, 1)
    nameplate.castbar.timer:SetJustifyH("RIGHT")

    nameplate.castbar.icon = nameplate.castbar:CreateTexture(nil, "OVERLAY")
    nameplate.castbar.icon:SetWidth(hbHeight + cbHeight)
    nameplate.castbar.icon:SetHeight(hbHeight + cbHeight)
    nameplate.castbar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    nameplate.castbar.icon.border = nameplate.castbar:CreateTexture(nil, "BACKGROUND")
    nameplate.castbar.icon.border:SetTexture(0, 0, 0, 1)
    nameplate.castbar.icon.border:SetPoint("TOPLEFT", nameplate.castbar.icon, "TOPLEFT", -1, 1)
    nameplate.castbar.icon.border:SetPoint("BOTTOMRIGHT", nameplate.castbar.icon, "BOTTOMRIGHT", 1, -1)

    if GudaPlates_Debuffs then
        GudaPlates_Debuffs:CreateDebuffFrames(nameplate)
    end

    if GudaPlates_ComboPoints and GudaPlates_ComboPoints:CanUseComboPoints() then
        GudaPlates_ComboPoints:CreateComboPointFrames(nameplate)
    end

    UpdateNamePlateDimensions(frame)

    frame.nameplate = nameplate
    registry[frame] = nameplate

    nameplate.showAfter = GetTime() + 0.15
    nameplate:Hide()

    HookScript(frame, "OnShow", NamePlate_OnShow)
    HookScript(frame, "OnHide", NamePlate_OnHide)

    if frame:IsShown() then
        local oldThis = this
        this = frame
        NamePlate_OnShow()
        this = oldThis
    end
end

local function UpdateNamePlate(frame)
    local nameplate = frame.nameplate
    if not nameplate then return end

    local original = nameplate.original
    if not original.healthbar then return end

    if GudaPlates_Filter and GudaPlates_Filter.ShouldSkipNameplate then
        if GudaPlates_Filter.ShouldSkipNameplate(frame, nameplate, original, Settings) then
            nameplate:Hide()
            return
        end
    end

    if superwow_active and GudaPlates_Players and frame.GetName then
        local unitstr = frame:GetName(1)
        if unitstr and unitstr ~= "" then
            local prevPvP = nameplate.cachedIsEnemyPlayerPvP
            GudaPlates_Players.DetectEnemyPlayer(frame, nameplate, unitstr)
            if prevPvP ~= nameplate.cachedIsEnemyPlayerPvP then
                UpdateNamePlateDimensions(frame)
            end
        end
    end

    local waitingForDelay = false
    if nameplate.showAfter then
        if GetTime() < nameplate.showAfter then
            waitingForDelay = true
        else
            nameplate.showAfter = nil
        end
    end

    if not waitingForDelay and not nameplate:IsShown() then
        nameplate:Show()
    end

    original.healthbar:SetStatusBarTexture("")
    original.healthbar:SetAlpha(0)

    local cachedRegions = nameplate.cachedRegions
    local regionsCount = nameplate.cachedRegionsCount or 0
    for i = 1, regionsCount do
        local region = cachedRegions[i]
        if region and region.GetObjectType then
            local otype = region:GetObjectType()
            if otype == "Texture" then
                if region ~= nameplate.original.raidicon and region ~= frame.raidicon then
                    region:SetAlpha(0)
                end
            elseif otype == "FontString" then
                region:SetAlpha(0)
            end
        end
    end

    local childCount = frame:GetNumChildren()
    if childCount ~= nameplate.cachedChildCount then
        nameplate.cachedChildCount = childCount
        nameplate.cachedChildren = {frame:GetChildren()}
    end
    local children = nameplate.cachedChildren
    if children then
        for i = 1, childCount do
            local child = children[i]
            if child and child ~= nameplate and child ~= original.healthbar then
                if child.SetAlpha then child:SetAlpha(0) end
                if child.Hide then child:Hide() end
            end
        end
    end

    if frame.new then
        frame.new:SetAlpha(0)
        local cachedNewRegions = nameplate.cachedNewRegions
        local newRegionsCount = nameplate.cachedNewRegionsCount or 0
        for i = 1, newRegionsCount do
            local region = cachedNewRegions[i]
            if region and region ~= frame.raidicon then
                if region.SetTexture then region:SetTexture("") end
                if region.SetAlpha then region:SetAlpha(0) end
                if region.SetWidth and region.GetObjectType and region:GetObjectType() == "FontString" then
                    region:SetWidth(0.001)
                end
            end
        end
    end

    local hp = original.healthbar:GetValue() or 0
    local hpmin, hpmax = original.healthbar:GetMinMaxValues()
    hpmin = hpmin or 0
    if not hpmax or hpmax == 0 then hpmax = 1 end
    if hp < 0 then hp = 0 end
    if hp > hpmax then hp = hpmax end

    nameplate.health:SetMinMaxValues(hpmin, hpmax)
    nameplate.health:SetValue(hp)

    local isHostile, isNeutral, isFriendly, r, g, b
    if GudaPlates_Healthbar and GudaPlates_Healthbar.DetectUnitType then
        isHostile, isNeutral, isFriendly, r, g, b = GudaPlates_Healthbar.DetectUnitType(nameplate, original)
    else
        r, g, b = original.healthbar:GetStatusBarColor()
        isHostile = r > 0.9 and g < 0.2 and b < 0.2
        isNeutral = r > 0.9 and g > 0.9 and b < 0.2
        isFriendly = not isHostile and not isNeutral
    end

    local hTextFormat
    if isFriendly then
        hTextFormat = Settings.friendHealthTextFormat
    else
        hTextFormat = Settings.healthTextFormat
    end

    if hp ~= nameplate.lastHP or hpmax ~= nameplate.lastHPMax or hTextFormat ~= nameplate.lastHTextFormat then
        nameplate.lastHP = hp
        nameplate.lastHPMax = hpmax
        nameplate.lastHTextFormat = hTextFormat

        local hpText = ""
        if hTextFormat ~= 0 and hpmax and hpmax > 0 then
            local perc = (hp / hpmax) * 100
            local format = hTextFormat
            local name = ""
            if original.name and original.name.GetText then
                name = original.name:GetText() or ""

                -- ============================================
                -- WOW-TRANSLATE INTERCEPT (HEALTH FORMATS)
                -- ============================================
                if name ~= "" then
                    local trans = GetNameTranslation(name)
                    if trans and trans ~= "" and trans ~= name then
                        name = trans .. " [" .. name .. "]"
                    end
                end
                -- ============================================
            end

            if format == 1 then
                hpText = string_format("%.0f%%", perc)
            elseif format == 2 then
                if hp > 1000 then
                    hpText = string_format("%.1fK", hp / 1000)
                else
                    hpText = string_format("%d", hp)
                end
            elseif format == 3 then
                if hp > 1000 then
                    hpText = string_format("%.1fK (%.0f%%)", hp / 1000, perc)
                else
                    hpText = string_format("%d (%.0f%%)", hp, perc)
                end
            elseif format == 4 then
                if hpmax > 1000 then
                    hpText = string_format("%.1fK - %.1fK", hp / 1000, hpmax / 1000)
                else
                    hpText = string_format("%d - %d", hp, hpmax)
                end
            elseif format == 5 then
                if hpmax > 1000 then
                    hpText = string_format("%.1fK - %.1fK (%.0f%%)", hp / 1000, hpmax / 1000, perc)
                else
                    hpText = string_format("%d - %d (%.0f%%)", hp, hpmax, perc)
                end
            elseif format == 6 then
                hpText = string_format("%s - %.0f%%", name, perc)
            elseif format == 7 then
                local hpStr
                if hp > 1000 then
                    hpStr = string_format("%.1fK", hp / 1000)
                else
                    hpStr = string_format("%d", hp)
                end
                hpText = string_format("%s - %s (%.0f%%)", name, hpStr, perc)
            elseif format == 8 then
                hpText = name
            end
        end
        nameplate.healthtext:SetText(hpText)
    end

    local nameColor = Settings.nameColor or {1, 1, 1, 1}
    local healthTextColor = Settings.healthTextColor or {1, 1, 1, 1}
    if hTextFormat and hTextFormat >= 6 then
        nameplate.healthtext:SetTextColor(nameColor[1], nameColor[2], nameColor[3], nameColor[4])
    else
        nameplate.healthtext:SetTextColor(healthTextColor[1], healthTextColor[2], healthTextColor[3], healthTextColor[4])
    end

    if hTextFormat and hTextFormat >= 6 then
        nameplate.name:Hide()
    else
        nameplate.name:Show()
    end

    if GudaPlates_Level then
        GudaPlates_Level.UpdateLevel(nameplate, original, frame, superwow_active)
    end

    local unitstr = nil
    local plateName = nil
    if original.name and original.name.GetText then
        plateName = original.name:GetText()
    end

    if GudaPlates_Healthbar and GudaPlates_Healthbar.CheckUnitChange then
        GudaPlates_Healthbar.CheckUnitChange(nameplate, plateName, isNeutral)
    end

    if superwow_active and frame and frame.GetName then
        unitstr = frame:GetName(1)
    end

    if GudaPlates_Marks and GudaPlates_Marks.UpdateNameplateIcon then
        GudaPlates_Marks.UpdateNameplateIcon(nameplate, frame, unitstr)
    end

    local isAttackingPlayer = false
    local hasValidGUID = unitstr and unitstr ~= ""

    local hasAggroGlow = false
    if original.glow and original.glow.IsShown and original.glow:IsShown() then
        hasAggroGlow = true
    end

    local mobTarget
    if hasValidGUID then
        if nameplate.cachedUnitStr ~= unitstr then
            nameplate.cachedUnitStr = unitstr
            nameplate.cachedMobTarget = unitstr .. "target"
        end
        mobTarget = nameplate.cachedMobTarget
        if UnitIsUnit(mobTarget, "player") then
            isAttackingPlayer = true
            nameplate.isAttackingPlayer = true
            nameplate.lastAttackTime = GetTime()
        elseif UnitExists(mobTarget) then
            isAttackingPlayer = false
            nameplate.isAttackingPlayer = false
        else
            isAttackingPlayer = false
            nameplate.isAttackingPlayer = false
        end
    else
        if plateName then
            if hasAggroGlow then
                isAttackingPlayer = true
                nameplate.isAttackingPlayer = true
            end

            if UnitExists("target") and UnitName("target") == plateName then
                if frame:GetAlpha() > 0.9 then
                    if UnitExists("targettarget") and UnitIsUnit("targettarget", "player") then
                        isAttackingPlayer = true
                        nameplate.isAttackingPlayer = true
                    elseif UnitExists("targettarget") then
                        isAttackingPlayer = false
                        nameplate.isAttackingPlayer = false
                    end
                end
            end
        end
    end

    local hasTWThreatData = false
    local playerHasAggro = false
    local threatHolderName = nil
    local highestOtherPct = 0
    local playerThreatPct = 0

    if isHostile then
        local mobGUID = nil
        if unitstr and superwow_active then
            local len = string_len(unitstr)
            if len >= 4 then
                local lowPart = string_sub(unitstr, len - 3, len)
                local num = tonumber(lowPart, 16)
                if num then
                    mobGUID = tostring(num)
                end
            end
        end

        hasTWThreatData, playerHasAggro, threatHolderName, _ = GetTWTankModeThreat(mobGUID, plateName)

        local isCurrentTarget = false
        if plateName and UnitExists("target") and UnitName("target") == plateName then
            if frame:GetAlpha() > 0.9 then
                isCurrentTarget = true
            end
        end

        if not hasTWThreatData and isCurrentTarget then
            local gpHasData, gpPlayerAggro, gpPlayerPct, gpHighestOther, gpThreatHolder = GetGPThreatData()
            if gpHasData then
                hasTWThreatData = true
                playerHasAggro = gpPlayerAggro
                playerThreatPct = gpPlayerPct
                highestOtherPct = gpHighestOther
                threatHolderName = gpThreatHolder
            end
        elseif hasTWThreatData and isCurrentTarget then
            local _, _, gpPlayerPct, gpHighestOther, gpThreatHolder = GetGPThreatData()
            playerThreatPct = gpPlayerPct or 0
            highestOtherPct = gpHighestOther or 0
            if not threatHolderName then
                threatHolderName = gpThreatHolder
            end
        end
    end

    if isFriendly then
        local isPlayer = false
        local friendlyClass = nil

        if hasValidGUID and UnitIsPlayer then
            isPlayer = UnitIsPlayer(unitstr)
            if isPlayer then
                local _, classToken = UnitClass(unitstr)
                friendlyClass = classToken
            end
        end

        if not isPlayer and plateName then
            friendlyClass = GetPlayerClassByName(plateName)
            if friendlyClass then
                isPlayer = true
            end
        end

        if isPlayer and friendlyClass and RAID_CLASS_COLORS and RAID_CLASS_COLORS[friendlyClass] then
            local classColor = RAID_CLASS_COLORS[friendlyClass]
            nameplate.health:SetStatusBarColor(classColor.r, classColor.g, classColor.b, 1)
        elseif (r < 0.2 and g > 0.9 and b < 0.2) or (r < 0.2 and g < 0.2 and b > 0.9) then
            nameplate.health:SetStatusBarColor(0.27, 0.63, 0.27, 1)
        else
            nameplate.health:SetStatusBarColor(r, g, b, 1)
        end
    else
        if hasValidGUID and GudaPlates_Players and GudaPlates_Players.DetectEnemyPlayer then
            GudaPlates_Players.DetectEnemyPlayer(frame, nameplate, unitstr)
        end

        local isEnemyPlayer = GudaPlates_Players and GudaPlates_Players.IsEnemyPlayer(nameplate)

        if isEnemyPlayer then
            local pr, pg, pb, pa = GudaPlates_Players.GetEnemyPlayerColor(nameplate, Settings)
            if pr then
                nameplate.health:SetStatusBarColor(pr, pg, pb, pa)
            else
                nameplate.health:SetStatusBarColor(0.85, 0.2, 0.2, 1)
            end
        else
            local mobInCombat = false
            local mobTargetUnit = nil

            if hasValidGUID then
                mobTargetUnit = unitstr .. "target"
                mobInCombat = UnitExists(mobTargetUnit)
            else
                mobInCombat = isAttackingPlayer or (twthreat_active and threatPct > 0) or hasAggroGlow
                if plateName and UnitExists("target") and UnitName("target") == plateName and frame:GetAlpha() > 0.9 then
                    mobTargetUnit = "targettarget"
                end
            end

            local isTappedByOthers = false

            if r > 0.4 and r < 0.6 and g > 0.4 and g < 0.6 and b > 0.4 and b < 0.6 then
                isTappedByOthers = true
            end

            local unitForAPI = nil
            if hasValidGUID then
                unitForAPI = unitstr
            elseif UnitExists("target") and UnitName("target") == plateName and frame:GetAlpha() > 0.9 then
                unitForAPI = "target"
            end

            if not isTappedByOthers and unitForAPI then
                if UnitIsTapped(unitForAPI) and not UnitIsTappedByPlayer(unitForAPI) then
                    local isMobTargetingGroupMate = false
                    local apiTarget = unitForAPI .. "target"
                    if UnitExists(apiTarget) and not UnitIsUnit(apiTarget, "player") then
                        isMobTargetingGroupMate = IsInPlayerGroup(apiTarget)
                    end

                    if not isMobTargetingGroupMate then
                        isTappedByOthers = true
                    end
                end
            end

            local originalIsGray = (r > 0.4 and r < 0.6 and g > 0.4 and g < 0.6 and b > 0.4 and b < 0.6)
            if not isTappedByOthers and mobInCombat and (originalIsGray or (r < 0.1 and g < 0.1 and b < 0.1)) then
                local isMobTargetingGroupMate = false

                if mobTargetUnit and UnitExists(mobTargetUnit) and not UnitIsUnit(mobTargetUnit, "player") then
                    isMobTargetingGroupMate = IsInPlayerGroup(mobTargetUnit)
                end

                local isMobTargetingGroup = isMobTargetingGroupMate or isAttackingPlayer or hasAggroGlow
                isTappedByOthers = not isMobTargetingGroup
            end

            local isStunned = false
            if GudaPlates_Debuffs and GudaPlates_Debuffs.timers then
                for _, stunName in ipairs(STUN_EFFECTS) do
                    local hasStun = false
                    if hasValidGUID and unitstr then
                        hasStun = GudaPlates_Debuffs.timers[unitstr .. "_" .. stunName]
                    end
                    if not hasStun and plateName then
                        hasStun = GudaPlates_Debuffs.timers[plateName .. "_" .. stunName]
                    end
                    if hasStun then
                        isStunned = true
                        break
                    end
                end
            end

            if isTappedByOthers and hp < hpmax then
                nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.TAPPED))
            elseif isStunned then
                nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.STUN))
            elseif GudaPlates_Healthbar.ShouldShowNeutral(nameplate, isNeutral, isAttackingPlayer) then
                GudaPlates_Healthbar.ApplyNeutralColor(nameplate)
            elseif not mobInCombat then
                nameplate.health:SetStatusBarColor(0.85, 0.2, 0.2, 1)
            elseif hasTWThreatData then
                if GudaPlates_Healthbar.WasNeutral(nameplate) and not isAttackingPlayer then
                    GudaPlates_Healthbar.ApplyNeutralColor(nameplate)
                elseif playerRole == "TANK" then
                    if playerHasAggro then
                        if highestOtherPct > 80 then
                            nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.TANK.LOSING_AGGRO))
                        else
                            nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.TANK.AGGRO))
                        end
                    else
                        if IsPlayerTank(threatHolderName) then
                            nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.TANK.OTHER_TANK))
                        else
                            nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.TANK.NO_AGGRO))
                        end
                    end
                else
                    if playerHasAggro then
                        nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.DPS.AGGRO))
                    elseif playerThreatPct > 80 then
                        nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.DPS.HIGH_THREAT))
                    else
                        nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.DPS.NO_AGGRO))
                    end
                end
            elseif hasValidGUID then
                if GudaPlates_Healthbar.WasNeutral(nameplate) and not isAttackingPlayer then
                    GudaPlates_Healthbar.ApplyNeutralColor(nameplate)
                elseif playerRole == "TANK" then
                    if isAttackingPlayer then
                        nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.TANK.AGGRO))
                    elseif mobTargetUnit and UnitExists(mobTargetUnit) and not UnitIsUnit(mobTargetUnit, "player") then
                        local targetName = UnitName(mobTargetUnit)
                        if IsPlayerTank(targetName) then
                            nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.TANK.OTHER_TANK))
                        else
                            nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.TANK.NO_AGGRO))
                        end
                    else
                        nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.TANK.NO_AGGRO))
                    end
                else
                    if isAttackingPlayer then
                        nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.DPS.AGGRO))
                    else
                        nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.DPS.NO_AGGRO))
                    end
                end
            else
                if GudaPlates_Healthbar.WasNeutral(nameplate) and not isAttackingPlayer then
                    GudaPlates_Healthbar.ApplyNeutralColor(nameplate)
                elseif playerRole == "TANK" then
                    if isAttackingPlayer then
                        nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.TANK.AGGRO))
                    else
                        local otherTankHasAggro = false
                        if plateName and UnitExists("target") and UnitName("target") == plateName then
                            if frame:GetAlpha() > 0.9 and UnitExists("targettarget") then
                                otherTankHasAggro = IsPlayerTank(UnitName("targettarget"))
                            end
                        end
                        if otherTankHasAggro then
                            nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.TANK.OTHER_TANK))
                        else
                            nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.TANK.NO_AGGRO))
                        end
                    end
                else
                    if isAttackingPlayer then
                        nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.DPS.AGGRO))
                    else
                        nameplate.health:SetStatusBarColor(unpack(THREAT_COLORS.DPS.NO_AGGRO))
                    end
                end
            end
        end
    end

    -- Update name from original
    if original.name and original.name.GetText then
        local name = original.name:GetText()
        -- FIX: Only run if the name has actually changed since the last frame tick
        if name and name ~= nameplate.lastNameText then
            nameplate.lastNameText = name -- Lock the current raw name into cache

            -- ============================================
            -- WOW-TRANSLATE INTERCEPT (STANDALONE NAME)
            -- ============================================
            local trans = GetNameTranslation(name)
            if trans and trans ~= "" and trans ~= name then
                name = trans .. " [" .. name .. "]"
            end
            -- ============================================

            nameplate.name:SetText(name)
            local nColor = Settings.nameColor or {1, 1, 1, 1}
            nameplate.name:SetTextColor(nColor[1], nColor[2], nColor[3], nColor[4])
        end
    end

    local mShowManaBar, mManaTextFormat
    if isFriendly then
        mShowManaBar = Settings.friendShowManaBar
        mManaTextFormat = Settings.friendManaTextFormat
    else
        mShowManaBar = Settings.showManaBar
        mManaTextFormat = Settings.manaTextFormat
    end

    if mShowManaBar and superwow_active and hasValidGUID then
        local mana = UnitMana(unitstr) or 0
        local manaMax = UnitManaMax(unitstr) or 0
        local powerType = UnitPowerType and UnitPowerType(unitstr) or 0
        
        if manaMax > 0 and powerType == 0 then
            nameplate.mana:SetMinMaxValues(0, manaMax)
            nameplate.mana:SetValue(mana)
            nameplate.mana:SetStatusBarColor(unpack(THREAT_COLORS.MANA_BAR))
            
            local manaText = ""
            if mManaTextFormat ~= 0 then
                local manaPerc = (mana / manaMax) * 100
                if mManaTextFormat == 1 then
                    manaText = string_format("%.0f%%", manaPerc)
                elseif mManaTextFormat == 2 then
                    if mana > 1000 then
                        manaText = string_format("%.1fK", mana / 1000)
                    else
                        manaText = string_format("%d", mana)
                    end
                elseif mManaTextFormat == 3 then
                    local manaStr
                    if mana > 1000 then
                        manaStr = string_format("%.1fK", mana / 1000)
                    else
                        manaStr = string_format("%d", mana)
                    end
                    manaText = string_format("%s (%.0f%%)", manaStr, manaPerc)
                end
            end
            if nameplate.mana.text then
                nameplate.mana.text:SetText(manaText)
            end
            
            nameplate.mana:Show()
        else
            nameplate.mana:Hide()
        end
    else
        if nameplate.mana then
            nameplate.mana:Hide()
        end
    end

    local isTarget = false
    if UnitExists("target") and plateName then
        local targetName = UnitName("target")
        if targetName and targetName == plateName then
            if frame:GetAlpha() == 1 then
                isTarget = true
            end
        end
    end

    if isTarget then
        local topAnchor = nameplate.health
        local bottomAnchor = nameplate.health
        local bracketHeight = Settings.healthbarHeight
        
        if nameplate.mana and nameplate.mana:IsShown() then
            if Settings.swapNameDebuff then
                topAnchor = nameplate.health
                bottomAnchor = nameplate.mana
                bracketHeight = Settings.healthbarHeight + 4
            else
                topAnchor = nameplate.mana
                bottomAnchor = nameplate.health
                bracketHeight = Settings.healthbarHeight + 4
            end
        end
        
        nameplate.targetBracket.leftVert:ClearAllPoints()
        nameplate.targetBracket.leftVert:SetPoint("TOPRIGHT", topAnchor, "TOPLEFT", -1, 2)
        nameplate.targetBracket.leftVert:SetPoint("BOTTOMRIGHT", bottomAnchor, "BOTTOMLEFT", -1, -2)
        nameplate.targetBracket.leftVert:Show()
        
        nameplate.targetBracket.leftTop:ClearAllPoints()
        nameplate.targetBracket.leftTop:SetPoint("TOPLEFT", nameplate.targetBracket.leftVert, "TOPRIGHT", 0, 0)
        nameplate.targetBracket.leftTop:Show()
        
        nameplate.targetBracket.leftBottom:ClearAllPoints()
        nameplate.targetBracket.leftBottom:SetPoint("BOTTOMLEFT", nameplate.targetBracket.leftVert, "BOTTOMRIGHT", 0, 0)
        nameplate.targetBracket.leftBottom:Show()
        
        nameplate.targetBracket.rightVert:ClearAllPoints()
        nameplate.targetBracket.rightVert:SetPoint("TOPLEFT", topAnchor, "TOPRIGHT", 1, 2)
        nameplate.targetBracket.rightVert:SetPoint("BOTTOMLEFT", bottomAnchor, "BOTTOMRIGHT", 1, -2)
        nameplate.targetBracket.rightVert:Show()
        
        nameplate.targetBracket.rightTop:ClearAllPoints()
        nameplate.targetBracket.rightTop:SetPoint("TOPRIGHT", nameplate.targetBracket.rightVert, "TOPLEFT", 0, 0)
        nameplate.targetBracket.rightTop:Show()
        
        nameplate.targetBracket.rightBottom:ClearAllPoints()
        nameplate.targetBracket.rightBottom:SetPoint("BOTTOMRIGHT", nameplate.targetBracket.rightVert, "BOTTOMLEFT", 0, 0)
        nameplate.targetBracket.rightBottom:Show()
        
        if Settings.showTargetGlow then
            local glowColor = Settings.targetGlowColor or {0.4, 0.8, 0.9, 0.4}
            local hbWidth = Settings.healthbarWidth or 115
            if nameplate.targetGlowTop then
                nameplate.targetGlowTop:SetVertexColor(glowColor[1], glowColor[2], glowColor[3], 0.4)
                nameplate.targetGlowTop:SetWidth(hbWidth)
                nameplate.targetGlowTop:Show()
            end
            if nameplate.targetGlowBottom then
                nameplate.targetGlowBottom:SetVertexColor(glowColor[1], glowColor[2], glowColor[3], 0.4)
                nameplate.targetGlowBottom:SetWidth(hbWidth)
                nameplate.targetGlowBottom:Show()
            end
        end
        nameplate:SetFrameStrata("BACKGROUND")
        nameplate:SetFrameLevel(10)
    else
        nameplate.targetBracket.leftVert:Hide()
        nameplate.targetBracket.leftTop:Hide()
        nameplate.targetBracket.leftBottom:Hide()
        nameplate.targetBracket.rightVert:Hide()
        nameplate.targetBracket.rightTop:Hide()
        nameplate.targetBracket.rightBottom:Hide()
        if nameplate.targetGlowTop then
            nameplate.targetGlowTop:Hide()
        end
        if nameplate.targetGlowBottom then
            nameplate.targetGlowBottom:Hide()
        end
        nameplate:SetFrameStrata("BACKGROUND")
        if nameplate.isAttackingPlayer then
            nameplate:SetFrameLevel(5)
        else
            nameplate:SetFrameLevel(2)
        end
    end

    local casting = nil
    local now = GetTime()

    local castDB = GudaPlates.castDB
    if hasValidGUID and castDB[unitstr] then
        local cast = castDB[unitstr]
        if cast.startTime + (cast.duration / 1000) > now then
            casting = cast
        else
            castDB[unitstr] = nil
        end
    end

    if not casting and superwow_active and hasValidGUID then
        if UnitCastingInfo then
            local spell, nameSubtext, text, texture, startTime, endTime, isTradeSkill = UnitCastingInfo(unitstr)
            if spell then
                casting = {
                    spell = spell,
                    startTime = startTime / 1000,
                    duration = endTime - startTime,
                    icon = texture
                }
            end
        end

        if not casting and UnitChannelInfo then
            local spell, nameSubtext, text, texture, startTime, endTime, isTradeSkill = UnitChannelInfo(unitstr)
            if spell then
                casting = {
                    spell = spell,
                    startTime = startTime / 1000,
                    duration = endTime - startTime,
                    icon = texture
                }
            end
        end
    end

    local castTracker = GudaPlates.castTracker
    if not casting and plateName and castTracker[plateName] and not hasValidGUID then
        local i = 1
        while i <= table.getn(castTracker[plateName]) do
            local cast = castTracker[plateName][i]
            if now > cast.startTime + (cast.duration / 1000) then
                table.remove(castTracker[plateName], i)
            else
                if not casting then
                    casting = cast
                end
                i = i + 1
            end
        end
    end

    if casting and casting.spell then
        local now = GetTime()
        local start = casting.startTime
        local duration = casting.duration

        local cHeight, cIndependent, cWidth, cShowIcon, hHeight, hWidth, mHeight
        if isFriendly then
            cHeight = Settings.friendCastbarHeight or 6
            cIndependent = Settings.friendCastbarIndependent
            cWidth = Settings.friendCastbarWidth or 85
            cShowIcon = Settings.friendShowCastbarIcon
            hHeight = Settings.friendHealthbarHeight or 4
            hWidth = Settings.friendHealthbarWidth or 85
            mHeight = Settings.friendManabarHeight or 4
        else
            cHeight = Settings.castbarHeight or 12
            cIndependent = Settings.castbarIndependent
            cWidth = Settings.castbarWidth or 115
            cShowIcon = Settings.showCastbarIcon
            hHeight = Settings.healthbarHeight or 14
            hWidth = Settings.healthbarWidth or 115
            mHeight = Settings.manabarHeight or 4
        end

        if now < start + (duration / 1000) then
            nameplate.castbar:SetMinMaxValues(0, duration)
            nameplate.castbar:SetValue((now - start) * 1000)
            nameplate.castbar.text:SetText(casting.spell)

            local timeLeft = (start + (duration / 1000)) - now
            nameplate.castbar.timer:SetText(string_format("%.1fs", timeLeft))

            if casting.icon and cShowIcon then
                nameplate.castbar.icon:SetTexture(casting.icon)
                nameplate.castbar.icon:ClearAllPoints()
                
                local iconSize
                
                if cIndependent and cWidth > hWidth then
                    if nameplate.mana and nameplate.mana:IsShown() then
                        iconSize = hHeight + mHeight
                    else
                        iconSize = hHeight
                    end
                else
                    if nameplate.mana and nameplate.mana:IsShown() then
                        iconSize = hHeight + cHeight + mHeight
                    else
                        iconSize = hHeight + cHeight
                    end
                end
                
                nameplate.castbar.icon:SetWidth(iconSize)
                nameplate.castbar.icon:SetHeight(iconSize)
                
                nameplate.castbar.icon:ClearAllPoints()
                
                if cIndependent and cWidth > hWidth then
                    if Settings.raidIconPosition == "RIGHT" then
                        if Settings.swapNameDebuff then
                            nameplate.castbar.icon:SetPoint("TOPRIGHT", nameplate.health, "TOPLEFT", -4, 0)
                        else
                            if nameplate.mana and nameplate.mana:IsShown() then
                                nameplate.castbar.icon:SetPoint("TOPRIGHT", nameplate.mana, "TOPLEFT", -4, 0)
                            else
                                nameplate.castbar.icon:SetPoint("TOPRIGHT", nameplate.health, "TOPLEFT", -4, 0)
                            end
                        end
                    else
                        if Settings.swapNameDebuff then
                            nameplate.castbar.icon:SetPoint("TOPLEFT", nameplate.health, "TOPRIGHT", 4, 0)
                        else
                            if nameplate.mana and nameplate.mana:IsShown() then
                                nameplate.castbar.icon:SetPoint("TOPLEFT", nameplate.mana, "TOPRIGHT", 4, 0)
                            else
                                nameplate.castbar.icon:SetPoint("TOPLEFT", nameplate.health, "TOPRIGHT", 4, 0)
                            end
                        end
                    end
                else
                    if Settings.raidIconPosition == "RIGHT" then
                        if Settings.swapNameDebuff then
                            nameplate.castbar.icon:SetPoint("TOPRIGHT", nameplate.castbar, "TOPLEFT", -4, 0)
                        else
                            nameplate.castbar.icon:SetPoint("BOTTOMRIGHT", nameplate.castbar, "BOTTOMLEFT", -4, 0)
                        end
                    else
                        if Settings.swapNameDebuff then
                            nameplate.castbar.icon:SetPoint("TOPLEFT", nameplate.castbar, "TOPRIGHT", 4, 0)
                        else
                            nameplate.castbar.icon:SetPoint("BOTTOMLEFT", nameplate.castbar, "BOTTOMRIGHT", 4, 0)
                        end
                    end
                end
                nameplate.castbar.icon:Show()
                if nameplate.castbar.icon.border then nameplate.castbar.icon.border:Show() end
            else
                nameplate.castbar.icon:Hide()
                if nameplate.castbar.icon.border then nameplate.castbar.icon.border:Hide() end
            end

            nameplate.castbar:Show()
        else
            nameplate.castbar:Hide()
        end
    else
        nameplate.castbar:Hide()
    end

    local numDebuffs = 0
    if GudaPlates_Debuffs then
        local lastDebuffUpdate = nameplate.lastDebuffUpdate or 0
        if now - lastDebuffUpdate >= DEBUFF_UPDATE_INTERVAL then
            nameplate.lastDebuffUpdate = now
            numDebuffs = GudaPlates_Debuffs:UpdateDebuffs(nameplate, unitstr, plateName, isTarget, hasValidGUID, superwow_active)
            nameplate.lastDebuffCount = numDebuffs
            GudaPlates_Debuffs:UpdateDebuffPositions(nameplate, numDebuffs)
        else
            numDebuffs = nameplate.lastDebuffCount or 0
            GudaPlates_Debuffs:UpdateDebuffPositions(nameplate, numDebuffs)
        end
    end

    if GudaPlates_ComboPoints and GudaPlates_ComboPoints:CanUseComboPoints() then
        GudaPlates_ComboPoints:UpdateComboPoints(nameplate, isTarget)
        GudaPlates_ComboPoints:UpdateComboPointPositions(nameplate, numDebuffs)
    end
end
GudaPlates.UpdateNamePlate = UpdateNamePlate

local lastDebuffCleanup = 0
local CLEANUP_INTERVAL = 1
local lastPlateUpdate = 0
local PLATE_UPDATE_INTERVAL = 0.5

local function HideOriginalNameplateElements(frame)
    GudaPlates_Hide.HideOriginalElements(frame, {skipRaidIcon = false})
end

local function ResetNameplateScanning()
    for frame, nameplate in pairs(registry) do
        if nameplate and nameplate.Hide then
            nameplate:Hide()
        end
        HideOriginalNameplateElements(frame)
    end

    local numChildren = WorldFrame:GetNumChildren()
    if numChildren > 0 then
        local children = { WorldFrame:GetChildren() }
        for i = 1, numChildren do
            local frame = children[i]
            if frame and GudaPlates_Scanner.IsNamePlate(frame) then
                HideOriginalNameplateElements(frame)
            end
        end
    end

    for k in pairs(registry) do registry[k] = nil end
    GudaPlates_Scanner.Reset()
    cachedWorldChildCount = 0
end
GudaPlates.ResetNameplateScanning = ResetNameplateScanning

local idleFrames = 0
local IDLE_THRESHOLD = 30
local onUpdateEnabled = true

local function GudaPlates_OnUpdate()
    local now = GetTime()
    local didWork = false

    if GudaPlates_Debuffs and now - lastDebuffCleanup > CLEANUP_INTERVAL then
        lastDebuffCleanup = now
        GudaPlates_Debuffs:CleanupTimers()
    end

    if GudaPlates_Scanner.ScanForNewNameplates(registry, HandleNamePlate) then
        didWork = true
    end

    local shouldUpdatePlates = playerInCombat or (now - lastPlateUpdate > PLATE_UPDATE_INTERVAL)

    if shouldUpdatePlates then
        didWork = true
        if not playerInCombat then
            lastPlateUpdate = now
        end

        local plate, nameplate = next(registry)
        while plate do
            if plate:IsShown() then
                UpdateNamePlate(plate)

                if not nameplate.overlapApplied then
                    nameplate.overlapApplied = true
                    if nameplateOverlap then
                        plate:EnableMouse(false)
                        if plate:GetWidth() > 1 then
                            plate:SetWidth(1)
                            plate:SetHeight(1)
                        end
                        nameplate:EnableMouse(not clickThrough)
                    else
                        plate:EnableMouse(not clickThrough)
                        nameplate:EnableMouse(false)
                    end
                    UpdateNamePlateDimensions(plate)
                end
            else
                nameplate.overlapApplied = nil
            end
            plate, nameplate = next(registry, plate)
        end
    end

    if not didWork and not playerInCombat then
        idleFrames = idleFrames + 1
        if idleFrames > IDLE_THRESHOLD then
            onUpdateEnabled = false
            GudaPlatesEventFrame:SetScript("OnUpdate", nil)
        end
    else
        idleFrames = 0
    end
end

local function EnableOnUpdate()
    if not onUpdateEnabled then
        onUpdateEnabled = true
        idleFrames = 0
        GudaPlatesEventFrame:SetScript("OnUpdate", GudaPlates_OnUpdate)
    end
end
GudaPlates.EnableOnUpdate = EnableOnUpdate

GudaPlatesEventFrame:SetScript("OnUpdate", GudaPlates_OnUpdate)

local function cmatch(str, pattern)
    if not str or not pattern then return nil end
    local pat = string_gsub(pattern, "%%%d?%$?s", "(.+)")
    pat = string_gsub(pat, "%%%d?%$?d", "(%d+)")
    for a, b, c, d in string_gfind(str, pat) do
        return a, b, c, d
    end
    return nil
end

GudaPlatesEventFrame:SetScript("OnEvent", function()
    if arg1 and SPELL_EVENTS[event] then
        if GudaPlates.ParseCastStart then GudaPlates.ParseCastStart(arg1) end
        if SpellDB and SPELL_DAMAGE_EVENTS[event] then
            local spell, victim, attacker = nil, nil, nil

            if LP.SPELL_HIT_SELF then
                for s, v in string_gfind(arg1, LP.SPELL_HIT_SELF) do
                    spell, victim, attacker = s, v, "You"
                    break
                end
            end
            if not spell then
                for s, v in string_gfind(arg1, "Your (.+) hits (.+) for %d+.") do
                    spell, victim, attacker = s, v, "You"
                end
            end
            if not spell then
                if LP.SPELL_CRIT_SELF then
                    for s, v in string_gfind(arg1, LP.SPELL_CRIT_SELF) do
                        spell, victim, attacker = s, v, "You"
                        break
                    end
                end
                if not spell then
                    for s, v in string_gfind(arg1, "Your (.+) crits (.+) for %d+.") do
                        spell, victim, attacker = s, v, "You"
                    end
                end
            end
            if not spell then
                if LP.SPELL_RESIST_SELF then
                    for s, v in string_gfind(arg1, LP.SPELL_RESIST_SELF) do
                        spell, victim, attacker = s, v, "You"
                        break
                    end
                end
                if not spell then
                    for s, v in string_gfind(arg1, "Your (.+) was resisted by (.+)%.") do
                        spell, victim, attacker = s, v, "You"
                    end
                end
            end

            if not spell then
                if LP.SPELL_HIT_OTHER then
                    for a, s, v in string_gfind(arg1, LP.SPELL_HIT_OTHER) do
                        spell, victim, attacker = s, v, a
                        break
                    end
                end
                if not spell then
                    for a, s, v in string_gfind(arg1, "(.+)'s (.+) hits (.+) for %d+.") do
                        spell, victim, attacker = s, v, a
                    end
                end
            end
            if not spell then
                if LP.SPELL_CRIT_OTHER then
                    for a, s, v in string_gfind(arg1, LP.SPELL_CRIT_OTHER) do
                        spell, victim, attacker = s, v, a
                        break
                    end
                end
                if not spell then
                    for a, s, v in string_gfind(arg1, "(.+)'s (.+) crits (.+) for %d+.") do
                        spell, victim, attacker = s, v, a
                    end
                end
            end
            if not spell then
                if LP.SPELL_RESIST_OTHER then
                    for a, s, v in string_gfind(arg1, LP.SPELL_RESIST_OTHER) do
                        spell, victim, attacker = s, v, a
                        break
                    end
                end
                if not spell then
                    for a, s, v in string_gfind(arg1, "(.+)'s (.+) was resisted by (.+)%.") do
                        spell, victim, attacker = s, v, a
                    end
                end
            end

            if spell and SpellDB.ResolveSpellName then
                spell = SpellDB:ResolveSpellName(spell, nil)
            end

            if spell and victim and (spell == "Thunderfury" or spell == "Thunderfury's Blessing") then
                local unitlevel = UnitName("target") == victim and UnitLevel("target") or 0
                local duration = SpellDB:GetDuration("Thunderfury", 0)
                local isOwn = (attacker == "You")
                
                SpellDB:RefreshEffect(victim, unitlevel, "Thunderfury", duration, isOwn)
                SpellDB:RefreshEffect(victim, unitlevel, "Thunderfury's Blessing", duration, isOwn)
                
                if GudaPlates_Debuffs and GudaPlates_Debuffs.timers then
                    GudaPlates_Debuffs.timers[victim .. "_" .. "Thunderfury"] = nil
                    GudaPlates_Debuffs.timers[victim .. "_" .. "Thunderfury's Blessing"] = nil
                    
                    if superwow_active and UnitExists("target") and UnitName("target") == victim then
                        local guid = UnitGUID and UnitGUID("target")
                        if guid then
                            GudaPlates_Debuffs.timers[guid .. "_" .. "Thunderfury"] = nil
                            GudaPlates_Debuffs.timers[guid .. "_" .. "Thunderfury's Blessing"] = nil
                        end
                    end
                end

                if superwow_active and UnitExists("target") and UnitName("target") == victim then
                    local guid = UnitGUID and UnitGUID("target")
                    if guid then
                        SpellDB:RefreshEffect(guid, unitlevel, "Thunderfury", duration, isOwn)
                        SpellDB:RefreshEffect(guid, unitlevel, "Thunderfury's Blessing", duration, isOwn)
                    end
                end
            end

            if GudaPlates_Debuffs and GudaPlates_Debuffs.HolyStrikeHandler then
                GudaPlates_Debuffs:HolyStrikeHandler(arg1)
            end
        end
    elseif arg1 and COMBAT_EVENTS[event] then
        if GudaPlates_Debuffs and GudaPlates_Debuffs.DEBUG_JUDGEMENT then
            DEFAULT_CHAT_FRAME:AddMessage("[Judge] COMBAT_EVENT: " .. event .. " - " .. string_sub(arg1, 1, 50))
        end
        if GudaPlates.ParseAttackHit then GudaPlates.ParseAttackHit(arg1) end
    end

    if event == "ADDON_LOADED" then
        if arg1 == "GudaPlates" then
            LoadSettings()
            DisablePfUINameplates()
            if GudaPlates.DisableShaguTweaksNameplates then
                GudaPlates.DisableShaguTweaksNameplates()
            end
        elseif arg1 == "pfUI" then
            if DisablePfUINameplates() then
                Print("Disabled pfUI nameplates module")
            end
        elseif arg1 == "ShaguTweaks" or arg1 == "ShaguTweaks-tbc" then
            if GudaPlates.DisableShaguTweaksNameplates then
                local delayFrame = CreateFrame("Frame")
                delayFrame:SetScript("OnUpdate", function()
                    this:SetScript("OnUpdate", nil)
                    if GudaPlates.DisableShaguTweaksNameplates() then
                        Print("Disabled ShaguTweaks nameplate modules (using GudaPlates instead)")
                    end
                end)
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        DisablePfUINameplates()
        if GudaPlates.DisableShaguTweaksNameplates then
            GudaPlates.DisableShaguTweaksNameplates()
        end

        for k in pairs(GudaPlates.debuffTracker) do GudaPlates.debuffTracker[k] = nil end
        for k in pairs(GudaPlates.castTracker) do GudaPlates.castTracker[k] = nil end
        for k in pairs(GudaPlates.castDB) do GudaPlates.castDB[k] = nil end
        for k in pairs(GudaPlates.recentMeleeCrits) do GudaPlates.recentMeleeCrits[k] = nil end
        for k in pairs(GudaPlates.recentMeleeHits) do GudaPlates.recentMeleeHits[k] = nil end
        for k in pairs(GudaPlates.playerClassCache) do GudaPlates.playerClassCache[k] = nil end
        if SpellDB then SpellDB.objects = {} end
        if SpellDB and SpellDB.ownerBoundCache then SpellDB.ownerBoundCache = {} end

        if GudaPlates.ResetNameplateScanning then
            GudaPlates.ResetNameplateScanning()
        end
        EnableOnUpdate()

        Print(L["Initialized. Scanning..."])
        if twthreat_active then
            Print(L["TWThreat detected - full threat colors enabled"])
        end
        if superwow_active then
            Print(L["SuperWoW detected - GUID targeting enabled"])
            if Settings.showDebuffTimers then
                Print(L["Debuff countdowns enabled"])
            end
        end

        if GudaPlates_Level then
            GudaPlates_Level.UpdatePlayerLevel()
        end

    elseif event == "PLAYER_LEVEL_UP" then
        if GudaPlates_Level then
            GudaPlates_Level.UpdatePlayerLevel(arg1)
        end

    elseif event == "UNIT_CASTEVENT" then
        if GudaPlates.HandleUnitCastEvent then
            local shouldReturn = GudaPlates.HandleUnitCastEvent(arg1, arg2, arg3, arg4, arg5)
            if shouldReturn then return end
        end

    elseif event == "SPELLCAST_STOP" then
        if SpellDB and SpellDB.pending[3] then
            local effect = SpellDB.pending[3]
            local duration = SpellDB.pending[4]
            local unitName = SpellDB.pending[5]
            local unitlevel = SpellDB.pending[2]

            local hasObject = SpellDB.objects[unitName] and SpellDB.objects[unitName][unitlevel] and SpellDB.objects[unitName][unitlevel][effect]

            if unitName and hasObject then
                SpellDB:RefreshEffect(unitName, unitlevel, effect, duration, true)
                if SpellDB.OWNER_BOUND_DEBUFFS and SpellDB.OWNER_BOUND_DEBUFFS[effect] and SpellDB.TrackOwnerBoundDebuff then
                    SpellDB:TrackOwnerBoundDebuff(unitName, effect, duration)
                    if superwow_active and UnitExists("target") and UnitName("target") == unitName then
                        local guid = UnitGUID and UnitGUID("target")
                        if guid then
                            SpellDB:TrackOwnerBoundDebuff(guid, effect, duration)
                        end
                    end
                end
                SpellDB:RemovePending()
            end
        end

    elseif event == "CHAT_MSG_SPELL_FAILED_LOCALPLAYER" and arg1 then
        if SpellDB and REMOVE_PENDING_PATTERNS then
            for _, pattern in pairs(REMOVE_PENDING_PATTERNS) do
                local effect = cmatch(arg1, pattern)
                if effect then
                    if SpellDB.BronzeSpellName then
                        effect = SpellDB:ResolveSpellName(effect, nil)
                    end
                    if SpellDB.pending[3] == effect then
                        SpellDB:RemovePending()
                        return
                    end
                end
            end
        end

    elseif event == "PLAYER_TARGET_CHANGED" or (event == "UNIT_AURA" and arg1 == "target") or 
           event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
            for plate, _ in pairs(registry) do
                if plate:IsShown() then
                    UpdateNamePlate(plate)
                end
            end
        end

        if SpellDB and UnitExists("target") then
            local unitname = UnitName("target")
            local unitlevel = UnitLevel("target") or 0
            for i = 1, 16 do
                local effect, rank, texture, stacks, dtype, duration, timeleft = SpellDB:UnitDebuff("target", i)
                if not texture then break end
                if effect and effect ~= "" then
                    if not SpellDB.objects[unitname] or not SpellDB.objects[unitname][unitlevel] or not SpellDB.objects[unitname][unitlevel][effect] then
                        SpellDB:AddEffect(unitname, unitlevel, effect)
                    end
                end
            end
        end

    elseif event == "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE" or event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE" then
        if arg1 and SpellDB then
            local unit, effect
            if LP.AFFLICTED then
                for u, e in string_gfind(arg1, LP.AFFLICTED) do
                    unit, effect = u, e
                    break
                end
            end
            if not unit or not effect then
                unit, effect = cmatch(arg1, "%s is afflicted by %s.")
            end
            if not unit or not effect then
                for u, e in string_gfind(arg1, "(.+) is afflicted by (.+) %((%d+)%)%.") do
                    unit, effect = u, e
                    break
                end
            end

            if effect then
                effect = StripSpellRank(effect)
                for e, s in string_gfind(effect, "(.+) %((%d+)%)$") do
                    effect = e
                    break
                end
            end

            if effect and SpellDB.ResolveSpellName then
                effect = SpellDB:ResolveSpellName(effect, nil)
            end

            if unit and effect then
                local unitlevel = UnitName("target") == unit and UnitLevel("target") or 0
                
                if effect == "Judgement of Light" or effect == "Judgement of the Crusader" or effect == "Judgement of Justice" or effect == "Judgement of Wisdom" or effect == "Judgement" then
                    local judgementsToRefresh = (effect == "Judgement") and { "Judgement of Wisdom", "Judgement of Light", "Judgement of the Crusader", "Judgement of Justice" } or { effect }
                    
                    for _, effectName in pairs(judgementsToRefresh) do
                        local dbDuration = SpellDB:GetDuration(effectName, 0)
                        if effect == "Judgement" then
                            if SpellDB.objects[unit] and SpellDB.objects[unit][unitlevel] and SpellDB.objects[unit][unitlevel][effectName] then
                                SpellDB:RefreshEffect(unit, unitlevel, effectName, dbDuration, false)
                            end
                        else
                            SpellDB:RefreshEffect(unit, unitlevel, effectName, dbDuration, false)
                        end
                        
                        if superwow_active and UnitExists("target") and UnitName("target") == unit then
                            local guid = UnitGUID and UnitGUID("target")
                            if guid then
                                if effect == "Judgement" then
                                    if SpellDB.objects[guid] and SpellDB.objects[guid][unitlevel] and SpellDB.objects[guid][unitlevel][effectName] then
                                        SpellDB:RefreshEffect(guid, unitlevel, effectName, dbDuration, false)
                                    end
                                else
                                    SpellDB:RefreshEffect(guid, unitlevel, effectName, dbDuration, false)
                                end
                            end
                        end
                    end
                end

                local recent = SpellDB.recentCasts and SpellDB.recentCasts[effect]
                local isRecentCast = recent and recent.time and (GetTime() - recent.time) < 3

                if SpellDB.pending[3] == effect then
                    local pendingDuration = SpellDB.pending[4] or SpellDB:GetDuration(effect, 0)
                    SpellDB:PersistPending(effect)
                    if SpellDB.OWNER_BOUND_DEBUFFS and SpellDB.OWNER_BOUND_DEBUFFS[effect] and SpellDB.TrackOwnerBoundDebuff then
                        SpellDB:TrackOwnerBoundDebuff(unit, effect, pendingDuration)
                        if superwow_active and UnitExists("target") and UnitName("target") == unit then
                            local guid = UnitGUID and UnitGUID("target")
                            if guid then
                                SpellDB:TrackOwnerBoundDebuff(guid, effect, pendingDuration)
                            end
                        end
                    end
                elseif isRecentCast then
                    SpellDB:RefreshEffect(unit, unitlevel, effect, recent.duration, true)
                    if SpellDB.OWNER_BOUND_DEBUFFS and SpellDB.OWNER_BOUND_DEBUFFS[effect] and SpellDB.TrackOwnerBoundDebuff then
                        SpellDB:TrackOwnerBoundDebuff(unit, effect, recent.duration)
                        if superwow_active and UnitExists("target") and UnitName("target") == unit then
                            local guid = UnitGUID and UnitGUID("target")
                            if guid then
                                SpellDB:TrackOwnerBoundDebuff(guid, effect, recent.duration)
                            end
                        end
                    end
                else
                    local isProc = false
                    if effect == "Deep Wound" or effect == "Vindication" or string_find(effect, "Poison") then
                        local now = GetTime()
                        local recentTime = nil
                        
                        if effect == "Deep Wound" then
                            recentTime = GudaPlates.recentMeleeCrits[unit]
                        else
                            recentTime = GudaPlates.recentMeleeHits[unit]
                        end

                        if not recentTime and superwow_active and UnitExists("target") and UnitName("target") == unit then
                            local guid = UnitGUID and UnitGUID("target")
                            if guid then
                                if effect == "Deep Wound" then
                                    recentTime = GudaPlates.recentMeleeCrits[guid]
                                else
                                    recentTime = GudaPlates.recentMeleeHits[guid]
                                end
                            end
                        end

                        if recentTime and (now - recentTime) < 2 then
                            isProc = true
                            local dbDuration = SpellDB:GetDuration(effect, 0) or (effect == "Deep Wound" and 12 or 10)

                            if SpellDB.TrackOwnerBoundDebuff then
                                SpellDB:TrackOwnerBoundDebuff(unit, effect, dbDuration)
                                if superwow_active and UnitExists("target") and UnitName("target") == unit then
                                    local guid = UnitGUID and UnitGUID("target")
                                    if guid then
                                        SpellDB:TrackOwnerBoundDebuff(guid, effect, dbDuration)
                                    end
                                end
                            end

                            SpellDB:RefreshEffect(unit, unitlevel, effect, dbDuration, true)
                        end
                    end

                    if not isProc then
                        local dbDuration = SpellDB:GetDuration(effect, 0)
                        SpellDB:RefreshEffect(unit, unitlevel, effect, dbDuration, false)
                    end
                end
            end
        end

    elseif event == "CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE" then
        if arg1 and SpellDB then
            local effect, unit, damage

            if LP.PERIODIC_SELF_HIT then
                for e, u in string_gfind(arg1, LP.PERIODIC_SELF_HIT) do
                    effect, unit = e, u
                    break
                end
            end
            if not effect then
                for e, u in string_gfind(arg1, "Your (.+) hits (.+) for %d+") do
                    effect, unit = e, u
                    break
                end
            end

            if not effect then
                if LP.PERIODIC_SUFFER then
                    for u, d1, d2, e in string_gfind(arg1, LP.PERIODIC_SUFFER) do
                        unit, effect = u, e
                        break
                    end
                end
                if not effect then
                    for u, e in string_gfind(arg1, "(.+) suffers %d+ .+ from your (.+)%.") do
                        unit, effect = u, e
                        break
                    end
                end
            end

            if not effect then
                if LP.PERIODIC_SELF_CRIT then
                    for e, u in string_gfind(arg1, LP.PERIODIC_SELF_CRIT) do
                        effect, unit = e, u
                        break
                    end
                end
                if not effect then
                    for e, u in string_gfind(arg1, "Your (.+) crits (.+) for %d+") do
                        effect, unit = e, u
                        break
                    end
                end
            end

            if effect and unit then
                effect = StripSpellRank(effect)
                if SpellDB.ResolveSpellName then
                    effect = SpellDB:ResolveSpellName(effect, nil)
                end

                if SpellDB.OWNER_BOUND_DEBUFFS and SpellDB.OWNER_BOUND_DEBUFFS[effect] then
                    local duration = SpellDB:GetDuration(effect, 0) or 12

                    if SpellDB.TrackOwnerBoundDebuff then
                        SpellDB:TrackOwnerBoundDebuff(unit, effect, duration)

                        if superwow_active and UnitExists("target") and UnitName("target") == unit then
                            local guid = UnitGUID and UnitGUID("target")
                            if guid then
                                SpellDB:TrackOwnerBoundDebuff(guid, effect, duration)
                            end
                        end
                    end

                    local unitlevel = UnitExists("target") and UnitName("target") == unit and UnitLevel("target") or 0
                    SpellDB:RefreshEffect(unit, unitlevel, effect, duration, true)
                end
            end
        end

    elseif event == "CHAT_MSG_COMBAT_SELF_HITS" then
        if arg1 then
            local unit

            if LP.MELEE_CRIT_SELF then
                for u in string_gfind(arg1, LP.MELEE_CRIT_SELF) do
                    unit = u
                    break
                end
            end
            if not unit then
                for u in string_gfind(arg1, "You crit (.+) for %d+") do
                    unit = u
                    break
                end
            end

            if unit then
                GudaPlates.recentMeleeCrits[unit] = GetTime()

                if superwow_active and UnitExists("target") and UnitName("target") == unit then
                    local guid = UnitGUID and UnitGUID("target")
                    if guid then
                        GudaPlates.recentMeleeCrits[guid] = GetTime()
                    end
                end
            end
        end

    elseif event == "CHAT_MSG_SPELL_AURA_GONE_OTHER" or event == "CHAT_MSG_SPELL_AURA_GONE_SELF" then
        if arg1 then
            local rawSpell, unit

            if LP.FADES then
                for s, u in string_gfind(arg1, LP.FADES) do
                    rawSpell, unit = s, u
                    break
                end
            end
            if not rawSpell then
                for s, u in string_gfind(arg1, "(.+) fades from (.+)%.") do
                    rawSpell, unit = s, u
                    break
                end
            end
            if not rawSpell then
                for s, u in string_gfind(arg1, "(.+) is removed from (.+)%.") do
                    rawSpell, unit = s, u
                    break
                end
            end

            if rawSpell and unit then
                local spell = StripSpellRank(rawSpell)
                for s, c in string_gfind(spell, "(.+) %((%d+)%)$") do spell = s break end

                if SpellDB and SpellDB.ResolveSpellName then
                    spell = SpellDB:ResolveSpellName(spell, nil)
                end

                GudaPlates.debuffTracker[unit .. spell] = nil
                if SpellDB and SpellDB.objects and SpellDB.objects[unit] then
                    for level, effects in pairs(SpellDB.objects[unit]) do
                        if effects[spell] then effects[spell] = nil end
                    end
                end
                if SpellDB and SpellDB.RemoveOwnerBoundDebuff then
                    SpellDB:RemoveOwnerBoundDebuff(unit, spell)
                end
            end
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        playerInCombat = true
        EnableOnUpdate()
    elseif event == "PLAYER_REGEN_ENABLED" then
        playerInCombat = false
        collectgarbage()
    end

    EnableOnUpdate()
end)

SLASH_GUDAPLATES1 = "/gudaplates"
SLASH_GUDAPLATES2 = "/gp"
SlashCmdList["GUDAPLATES"] = function(msg)
    msg = string_lower(msg or "")
    if msg == "tank" then
        playerRole = "TANK"
        Print(L["Role set to TANK - Blue=you have aggro, Red=need to taunt"])
    elseif msg == "dps" or msg == "healer" then
        playerRole = "DPS"
        Print(L["Role set to DPS/HEALER - Red=mob attacking you, Blue=tank has aggro"])
    elseif msg == "toggle" then
        if playerRole == "TANK" then
            playerRole = "DPS"
            Print(L["Role set to DPS/HEALER"])
        else
            playerRole = "TANK"
            Print(L["Role set to TANK"])
        end
    elseif msg == "debugthreat" then
        DEBUG_THREAT = not DEBUG_THREAT
        if DEBUG_THREAT then
            Print("Threat debug logging ENABLED - check chat for threat info")
        else
            Print("Threat debug logging DISABLED")
        end
    elseif msg == "config" or msg == "options" then
        if GudaPlatesOptionsFrame:IsShown() then
            GudaPlatesOptionsFrame:Hide()
        else
            GudaPlatesOptionsFrame:Show()
        end
    elseif msg == "debug" or msg == "debuffs" then
        if not UnitExists("target") then
            Print("No target selected. Target a unit with debuffs first.")
            return
        end
        local targetName = UnitName("target") or "target"
        Print("=== Debuffs on " .. targetName .. " ===")
        local found = false
        for i = 1, 40 do
            local texture, count = UnitDebuff("target", i)
            if not texture then break end
            found = true
            local spellName = SpellDB and SpellDB:ScanDebuff("target", i)
            local duration = spellName and SpellDB and SpellDB:GetDuration(spellName, 0)
            local durationStr = duration and (duration .. "s") or "NOT IN DB"
            Print(i .. ": " .. (spellName or "UNKNOWN") .. " (" .. durationStr .. ")")
            Print("   Texture: " .. texture)
            if SpellDB and spellName and SpellDB.FindEffectData then
                local unitlevel = UnitLevel("target") or 0
                local tracked = SpellDB:FindEffectData(targetName, unitlevel, spellName)
                if tracked and tracked.start then
                    local remaining = tracked.duration - (GetTime() - tracked.start)
                    Print("   -> TRACKED: " .. string_format("%.1f", remaining) .. "s left")
                end
            end
        end
        if not found then
            Print("No debuffs found on target.")
        end
        Print("=== End of debuffs ===")
    elseif msg == "tracked" then
        Print("=== Tracked Debuffs ===")
        if SpellDB and SpellDB.objects then
            local count = 0
            for unitName, levels in pairs(SpellDB.objects) do
                for level, debuffs in pairs(levels) do
                    for spellName, data in pairs(debuffs) do
                        if data.start and data.duration then
                            local remaining = data.duration - (GetTime() - data.start)
                            if remaining > 0 then
                                Print(unitName .. " (L" .. level .. "): " .. spellName .. " - " .. string_format("%.1f", remaining) .. "s left")
                                count = count + 1
                            end
                        end
                    end
                end
            end
            if count == 0 then
                Print("No tracked debuffs.")
            end
        else
            Print("SpellDB not loaded or no tracked debuffs.")
        end
        Print("=== End of tracked ===")
    elseif msg == "pending" then
        Print("=== Pending Spell ===")
        if SpellDB and SpellDB.pending and SpellDB.pending[3] then
            local p = SpellDB.pending
            Print("Unit: " .. (p[1] or "nil"))
            Print("Level: " .. (p[2] or 0))
            Print("Spell: " .. (p[3] or "nil"))
            Print("Duration: " .. (p[4] or "nil") .. "s")
        else
            Print("No pending spell.")
        end
    elseif msg == "spelldb" then
        Print("=== SpellDB Status ===")
        if SpellDB then
            Print("SpellDB loaded: YES")
            Print("GetDuration: " .. tostring(SpellDB.GetDuration ~= nil))
            Print("ScanDebuff: " .. tostring(SpellDB.ScanDebuff ~= nil))
            local rendDur = SpellDB:GetDuration("Rend", 2)
            Print("Test - Rend Rank 2 -> " .. tostring(rendDur) .. "s")
            local rendMax = SpellDB:GetDuration("Rend", 0)
            Print("Test - Rend default -> " .. tostring(rendMax) .. "s")
        else
            Print("SpellDB loaded: NO")
            Print("GudaPlates_SpellDB: " .. tostring(GudaPlates_SpellDB ~= nil))
        end
    elseif string_find(msg, "^othertank") then
        local args = string_gsub(msg, "^othertank%s*", "")
        local COLOR_PRESETS = {
            lightblue = {0.6, 0.8, 1.0, 1},
            cyan = {0.0, 1.0, 1.0, 1},
            green = {0.0, 0.8, 0.0, 1},
            teal = {0.0, 0.5, 0.5, 1},
            purple = {0.6, 0.4, 0.8, 1},
            pink = {0.376, 0.027, 0.431, 1},
            yellow = {1.0, 1.0, 0.0, 1},
            white = {1.0, 1.0, 1.0, 1},
            gray = {0.5, 0.5, 0.5, 1},
        }
        if args == "" then
            Print("OTHER_TANK color presets: lightblue, cyan, green, teal, purple, pink, yellow, white, gray")
            Print("Usage: /gp othertank <preset> or /gp othertank <r> <g> <b> (0-1 values)")
            local c = THREAT_COLORS.TANK.OTHER_TANK
            Print("Current: " .. string_format("%.2f %.2f %.2f", c[1], c[2], c[3]))
        elseif COLOR_PRESETS[args] then
            THREAT_COLORS.TANK.OTHER_TANK = COLOR_PRESETS[args]
            SaveSettings()
            Print("OTHER_TANK color set to: " .. args)
        else
            local r, g, b
            local values = {}
            for num in string_gfind(args, "([%d%.]+)") do
                table.insert(values, num)
            end
            if values[1] and values[2] and values[3] then
                r, g, b = values[1], values[2], values[3]
            end
            if r and g and b then
                r, g, b = tonumber(r), tonumber(g), tonumber(b)
                if r and g and b and r >= 0 and r <= 1 and g >= 0 and g <= 1 and b >= 0 and b <= 1 then
                    THREAT_COLORS.TANK.OTHER_TANK = {r, g, b, 1}
                    SaveSettings()
                    Print("OTHER_TANK color set to: " .. string_format("%.2f %.2f %.2f", r, g, b))
                else
                    Print("Invalid RGB values. Use values between 0 and 1.")
                end
            else
                Print("Unknown preset: " .. args)
                Print("Available presets: lightblue, cyan, green, teal, purple, pink, yellow, white, gray")
            end
        end
    elseif msg == "debugjudge" then
        if GudaPlates_Debuffs and GudaPlates_Debuffs.ToggleJudgeDebug then
            GudaPlates_Debuffs:ToggleJudgeDebug()
            Print("DEBUG_JUDGEMENT is now: " .. tostring(GudaPlates_Debuffs.DEBUG_JUDGEMENT))
        else
            Print("GudaPlates_Debuffs not loaded")
        end
    elseif msg == "judgements" or msg == "judge" then
        if GudaPlates_Debuffs and GudaPlates_Debuffs.ShowJudgements then
            GudaPlates_Debuffs:ShowJudgements()
        else
            Print("GudaPlates_Debuffs not loaded")
        end
    elseif msg == "testrefresh" then
        if GudaPlates_Debuffs and GudaPlates_Debuffs.SealHandler then
            Print("Manually triggering SealHandler...")
            GudaPlates_Debuffs:SealHandler("You", UnitName("target") or "test")
            Print("Done. Check if judgement timer refreshed.")
        else
            Print("GudaPlates_Debuffs.SealHandler not available")
        end
    elseif msg == "finddebuff" then
        if UnitExists("target") then
            Print("=== All Debuffs on Target ===")
            for i = 1, 40 do
                local texture, stacks = UnitDebuff("target", i)
                if not texture then break end

                local spellName = "Unknown"
                if SpellDB then
                    spellName = SpellDB:ScanDebuff("target", i) or "Unknown"
                end

                Print(i .. ": " .. texture .. " -> " .. spellName)
            end
        else
            Print("No target selected")
        end
    elseif msg == "markdebug" then
        if GudaPlates_Marks and GudaPlates_Marks.DebugTest then
            GudaPlates_Marks.DebugTest()
        end
    elseif msg == "clearmarks" then
        if GudaPlates_Marks then
            GudaPlates_Marks.ClearAllMarks()
            GudaPlates_Marks.UpdateTargetFrameIcon()
            Print("All marks cleared")
        end
    elseif string_find(msg, "^mark") then
        local indexStr = string_gsub(msg, "^mark%s*", "")
        local index = tonumber(indexStr)
        if index and index >= 0 and index <= 8 then
            GudaPlates_Marks_SetMarkOnTarget(index)
        else
            Print("Usage: /gp mark <0-8> (1=Star, 2=Circle, 3=Diamond, 4=Triangle, 5=Moon, 6=Square, 7=Cross, 8=Skull, 0=Clear)")
        end
    else
        Print("Commands: /gp tank | /gp dps | /gp toggle | /gp config")
        Print("         /gp mark <0-8> - Mark target (solo, no party needed)")
        Print("         /gp clearmarks - Clear all marks")
        Print("         /gp othertank <color> - Set Other Tank Aggro color")
        Print("         /gp debug - Show target debuffs with tooltip scanning")
        Print("         /gp debugjudge - Toggle Paladin Judgement refresh debug")
        Print("         /gp judge - Show tracked judgements on target")
        Print("         /gp tracked - Show all tracked debuffs")
        Print("         /gp pending - Show pending spell cast")
        Print("         /gp spelldb - Test SpellDB loading")
        Print(L["Current role: "] .. playerRole)
    end
end

GudaPlatesDB = GudaPlatesDB or {}

local function SaveSettings()
    if GudaPlates.nameplateOverlap ~= nil then
        nameplateOverlap = GudaPlates.nameplateOverlap
    end
    if GudaPlates.nameplateClickThrough ~= nil then
        clickThrough = GudaPlates.nameplateClickThrough
    end
    if GudaPlates.playerRole then
        playerRole = GudaPlates.playerRole
    end

    GudaPlatesDB.playerRole = playerRole
    GudaPlatesDB.THREAT_COLORS = THREAT_COLORS
    GudaPlatesDB.nameplateOverlap = nameplateOverlap
    GudaPlatesDB.nameplateClickThrough = clickThrough
    GudaPlatesDB.minimapAngle = minimapAngle
    GudaPlatesDB.Settings = Settings
    GudaPlatesDB.GP_TankPlayers = GP_TankPlayers

    GudaPlates.playerRole = playerRole
    GudaPlates.THREAT_COLORS = THREAT_COLORS
    GudaPlates.nameplateOverlap = nameplateOverlap
    GudaPlates.nameplateClickThrough = clickThrough
    GudaPlates.minimapAngle = minimapAngle
    GudaPlates.Settings = Settings
end
GudaPlates.SaveSettings = SaveSettings

LoadSettings = function()
    if GudaPlatesDB.playerRole then
        playerRole = GudaPlatesDB.playerRole
    end
    if GudaPlatesDB.nameplateOverlap ~= nil then
        nameplateOverlap = GudaPlatesDB.nameplateOverlap
    end
    if GudaPlatesDB.nameplateClickThrough ~= nil then
        clickThrough = GudaPlatesDB.nameplateClickThrough
    end
    if GudaPlatesDB.minimapAngle then
        minimapAngle = GudaPlatesDB.minimapAngle
    end
    if GudaPlatesDB.Settings then
        for key, value in pairs(GudaPlatesDB.Settings) do
            Settings[key] = value
        end
    end
    if GudaPlatesDB.healthbarHeight then Settings.healthbarHeight = GudaPlatesDB.healthbarHeight end
    if GudaPlatesDB.healthbarWidth then Settings.healthbarWidth = GudaPlatesDB.healthbarWidth end
    if GudaPlatesDB.healthFontSize then Settings.healthFontSize = GudaPlatesDB.healthFontSize end
    if GudaPlatesDB.levelFontSize then Settings.levelFontSize = GudaPlatesDB.levelFontSize end
    if GudaPlatesDB.nameFontSize then Settings.nameFontSize = GudaPlatesDB.nameFontSize end
    if GudaPlatesDB.raidIconPosition then Settings.raidIconPosition = GudaPlatesDB.raidIconPosition end
    if GudaPlatesDB.swapNameDebuff ~= nil then Settings.swapNameDebuff = GudaPlatesDB.swapNameDebuff end
    if GudaPlatesDB.showDebuffTimers ~= nil then Settings.showDebuffTimers = GudaPlatesDB.showDebuffTimers end
    if GudaPlatesDB.showOnlyMyDebuffs ~= nil then Settings.showOnlyMyDebuffs = GudaPlatesDB.showOnlyMyDebuffs end
    if GudaPlatesDB.showManaBar ~= nil then Settings.showManaBar = GudaPlatesDB.showManaBar end
    if GudaPlatesDB.castbarHeight then Settings.castbarHeight = GudaPlatesDB.castbarHeight end
    if GudaPlatesDB.castbarWidth then Settings.castbarWidth = GudaPlatesDB.castbarWidth end
    if GudaPlatesDB.castbarIndependent ~= nil then Settings.castbarIndependent = GudaPlatesDB.castbarIndependent end
    if GudaPlatesDB.showCastbarIcon ~= nil then Settings.showCastbarIcon = GudaPlatesDB.showCastbarIcon end
    if GudaPlatesDB.THREAT_COLORS then
        for role, colors in pairs(GudaPlatesDB.THREAT_COLORS) do
            if THREAT_COLORS[role] then
                for colorType, colorVal in pairs(colors) do
                    if THREAT_COLORS[role][colorType] then
                        THREAT_COLORS[role][colorType] = colorVal
                    end
                end
            end
        end
        if GudaPlatesDB.THREAT_COLORS.TAPPED then
            THREAT_COLORS.TAPPED = GudaPlatesDB.THREAT_COLORS.TAPPED
        end
        if GudaPlatesDB.THREAT_COLORS.STUN then
            THREAT_COLORS.STUN = GudaPlatesDB.THREAT_COLORS.STUN
        end
        if GudaPlatesDB.THREAT_COLORS.MANA_BAR then
            THREAT_COLORS.MANA_BAR = GudaPlatesDB.THREAT_COLORS.MANA_BAR
        end
    end

    if GudaPlatesDB.GP_TankPlayers and GudaPlates.GP_TankPlayers then
        for name, isTank in pairs(GudaPlatesDB.GP_TankPlayers) do
            GudaPlates.GP_TankPlayers[name] = isTank
        end
    end

    GudaPlates.playerRole = playerRole
    GudaPlates.nameplateOverlap = nameplateOverlap
    GudaPlates.nameplateClickThrough = clickThrough
    GudaPlates.minimapAngle = minimapAngle
    GudaPlates.Settings = Settings
    GudaPlates.THREAT_COLORS = THREAT_COLORS
end

local minimapButton = CreateFrame("Button", "GudaPlatesMinimapButton", Minimap)
minimapButton:SetWidth(32)
minimapButton:SetHeight(32)
minimapButton:SetFrameStrata("LOW")
minimapButton:SetToplevel(true)
minimapButton:SetMovable(true)
minimapButton:EnableMouse(true)
minimapButton:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 0, 0)
minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local minimapIcon = minimapButton:CreateTexture(nil, "BACKGROUND")
minimapIcon:SetTexture("Interface\\Icons\\Spell_Nature_WispSplode")
minimapIcon:SetWidth(20)
minimapIcon:SetHeight(20)
minimapIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
minimapIcon:SetPoint("CENTER", minimapButton, "CENTER", 0, 0)

local minimapBorder = minimapButton:CreateTexture(nil, "OVERLAY")
minimapBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
minimapBorder:SetWidth(52)
minimapBorder:SetHeight(52)
minimapBorder:SetPoint("CENTER", minimapButton, "CENTER", 10, -10)

local function UpdateMinimapButtonPosition()
    local rad = math.rad(minimapAngle)
    local x = math.cos(rad) * 80
    local y = math.sin(rad) * 80
    minimapButton:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 52 - x, y - 52)
end
GudaPlates.UpdateMinimapButtonPosition = UpdateMinimapButtonPosition
UpdateMinimapButtonPosition()

minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimapButton:RegisterForDrag("LeftButton", "RightButton")
minimapButton:SetScript("OnDragStart", function()
    this.dragging = true
    this:LockHighlight()
end)

minimapButton:SetScript("OnDragStop", function()
    this.dragging = false
    this:UnlockHighlight()
    SaveSettings()
end)

minimapButton:SetScript("OnUpdate", function()
    if this.dragging then
        local xpos, ypos = GetCursorPosition()
        local xmin, ymin = Minimap:GetLeft() or 400, Minimap:GetBottom() or 400
        local mscale = Minimap:GetEffectiveScale()

        local dx = xmin - xpos / mscale + 70
        local dy = ypos / mscale - ymin - 70
        minimapAngle = math.deg(math.atan2(dy, dx))
        UpdateMinimapButtonPosition()
    end
end)

minimapButton:SetScript("OnClick", function()
    if arg1 == "RightButton" or IsControlKeyDown() then
        if GudaPlatesOptionsFrame:IsShown() then
            GudaPlatesOptionsFrame:Hide()
        else
            GudaPlatesOptionsFrame:Show()
        end
    end
end)

minimapButton:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_LEFT")
    GameTooltip:AddLine("GudaPlates")
    GameTooltip:AddLine("Left-Drag to move button", 1, 1, 1)
    GameTooltip:AddLine("Right-Click or Ctrl-Left-Click for settings", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)

minimapButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("VARIABLES_LOADED")
loadFrame:SetScript("OnEvent", function()
    LoadSettings()
    UpdateMinimapButtonPosition()
    if GudaPlatesOptionsFrame and GudaPlatesOptionsFrame.UpdateBackdrop then
        GudaPlatesOptionsFrame.UpdateBackdrop()
    end
    if GudaPlatesFontDropdown then
        UIDropDownMenu_SetSelectedValue(GudaPlatesFontDropdown, Settings.textFont)
        if GudaPlates.fontOptions then
            for _, opt in ipairs(GudaPlates.fontOptions) do
                if opt.value == Settings.textFont then
                    UIDropDownMenu_SetText(opt.text, GudaPlatesFontDropdown)
                    break
                end
            end
        end
    end
    Print(L["Settings loaded."])

    if SpellDB then
        Print(L["Spell database loaded successfully"])
        local duration = SpellDB:GetDuration("Rend", 2)
        Print("  Test - Rend Rank 2 -> " .. tostring(duration) .. "s (expected: 12)")
    else
        Print(L["ERROR: Spell database not loaded!"])
    end
end)

Print(L["Loaded. Use /gp tank or /gp dps to set role."])