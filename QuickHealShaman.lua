-- QuickHeal Shaman Module (Refactored)
-- Consolidated spell selection with shared helper functions

local function writeLine(s, r, g, b)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(s, r or 1, g or 1, b or 0.5)
    end
end

-- Penalty Factors for low-level spells
local PF = {
    [1]  = 0.2875,
    [6]  = 0.475,
    [12] = 0.7,
    [18] = 0.925,
}

function QuickHeal_Shaman_GetRatioHealthyExplanation()
    local RatioHealthy = QuickHeal_GetRatioHealthy()
    local RatioFull = QuickHealVariables["RatioFull"]
    if RatioHealthy >= RatioFull then
        return QUICKHEAL_SPELL_LESSER_HEALING_WAVE ..
            " will always be used in combat, and " .. QUICKHEAL_SPELL_HEALING_WAVE .. " will be used out of combat. "
    else
        if RatioHealthy > 0 then
            return QUICKHEAL_SPELL_LESSER_HEALING_WAVE ..
                " will be used in combat if the target has less than " ..
                RatioHealthy * 100 .. "% life, and " .. QUICKHEAL_SPELL_HEALING_WAVE .. " will be used otherwise. "
        else
            return QUICKHEAL_SPELL_LESSER_HEALING_WAVE ..
                " will never be used. " .. QUICKHEAL_SPELL_HEALING_WAVE .. " will always be used in and out of combat. "
        end
    end
end

-- Calculate all Shaman-specific modifiers
local function GetShamanModifiers()
    local mods = {}
    -- Equipment healing bonus (cached)
    mods.bonus = QuickHeal_GetEquipmentBonus()
    -- Calculate healing modifiers by cast time
    mods.healModLHW = (1.5 / 3.5) * mods.bonus
    mods.healModCH  = 0.6142 * mods.bonus -- 1.18 coefficient (not sure on octowow)
    mods.healMod15  = (1.5 / 3.5) * mods.bonus
    mods.healMod20  = (2.0 / 3.5) * mods.bonus
    mods.healMod25  = (2.5 / 3.5) * mods.bonus
    mods.healMod30  = (3.0 / 3.5) * mods.bonus
    
    -- Tidal Focus - Decreases mana usage by 1% per rank
    local tfRank = QuickHeal_GetTalentRank(3, 2)
    mods.tfMod = 1 - tfRank / 100
    -- Tidal Mastery Talent - increases Healing spell crit chance by 1% per rank (crit is 50% bonus so 0.5 bonus per rank)
    local tmRank = QuickHeal_GetTalentRank(3, 5)
    mods.tmMod = 1 + 0.5 * tmRank / 100
    return mods
end

-- Check for Shaman-specific buffs that affect healing
-- Returns: inCombat (adjusted)
-- Nature's Swiftness and Hand of Edward the Odd both force "out of combat" mode (HW priority)
local function CheckShamanBuffs(inCombat)
    -- Nampower: use aura spell ID array for reliable detection
    if GetUnitField then
        local success, auras = pcall(GetUnitField, "player", "aura")
        if success and auras then
            for i = 1, 31 do -- slots 1-31 are buffs
                local spellId = auras[i]
                if spellId and spellId > 0 then
                    if spellId == 17116 then -- Nature's Swiftness
                        QuickHeal_debug("BUFF: Nature's Swiftness [" .. spellId .. "] (out of combat healing forced)")
                        inCombat = false
                    elseif spellId == 18803 then -- Focus (Hand of Edward the Odd)
                        QuickHeal_debug("BUFF: Hand of Edward the Odd [" .. spellId .. "] (out of combat healing forced)")
                        inCombat = false
                    end
                end
            end
        end
    end
    -- Texture-based detection (fallback for buffs not caught by Nampower aura names)
    -- Detect Nature's Swiftness (next nature spell is instant cast)
    if not (inCombat == false) and QuickHeal_DetectBuff('player', "Spell_Nature_RavenForm") then
        QuickHeal_debug("BUFF: Nature's Swiftness (texture fallback)")
        inCombat = false
    end
    -- Detect Hand of Edward the Odd (next spell is instant cast)
    -- Note: Must exclude "Protective Light" which uses icon "Spell_Holy_SearingLightPriest"
    if not (inCombat == false) and
       QuickHeal_DetectBuff('player', "Spell_Holy_SearingLight") and
       not QuickHeal_DetectBuff('player', "Spell_Holy_SearingLightPriest") then
        QuickHeal_debug("BUFF: Hand of Edward the Odd (texture fallback)")
        inCombat = false
    end
    return inCombat
end

-- Get Healing Way modifier from target buff
local function GetHealingWayMod(target)
    local hwMod = QuickHeal_DetectBuff(target, "Spell_Nature_HealingWay")
    if hwMod then
        hwMod = 1 + 0.06 * hwMod
    else
        hwMod = 1
    end
    QuickHeal_debug("Healing Way healing modifier", hwMod)
    return hwMod
end

-- Chain Heal spell selection (works with or without target)
function QuickHeal_Shaman_FindChainHealSpellToUse(target, healType, multiplier, forceMaxRank, maxhealth, healDeficit, hdb)
    local SpellID = nil
    local HealSize = 0
    multiplier = multiplier or 1
    local RatioFull    = QuickHealVariables["RatioFull"]
    local RatioHealthy = QuickHeal_GetRatioHealthy()
    local debug        = QuickHeal_debug

    -- Get health info
    local healneed, Health, HDB, hwMod
    if target then
        if QuickHeal_UnitHasHealthInfo(target) then
            healneed = QH_GetUnitMaxHealth(target) - QH_GetUnitHealth(target)
            Health   = QH_GetUnitHealth(target) / QH_GetUnitMaxHealth(target)
        else
            healneed = QuickHeal_EstimateUnitHealNeed(target, true)
            Health   = QH_GetUnitHealth(target) / 100
        end
        HDB   = QuickHeal_GetHealModifier(target)
        hwMod = GetHealingWayMod(target)
    else
        -- NoTarget mode
        if not maxhealth or maxhealth <= 0 then return nil, 0 end
        healneed = healDeficit * multiplier
        Health   = healDeficit / maxhealth
        HDB      = hdb or 1
        hwMod    = 1 -- Can't detect Healing Way without target
    end

    debug("Target debuff healing modifier", HDB)
    healneed = healneed / HDB

    -- Get modifiers
    local mods      = GetShamanModifiers()
    local ManaLeft  = QH_GetUnitMana('player')

    -- Get Chain Heal spell IDs
    local SpellIDsCH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_CHAIN_HEAL)
    local maxRankCH  = table.getn(SpellIDsCH)

    -- Chain Heal downrank settings
    local downRankCH = QuickHealVariables.DownrankValueCH or 3
    local minRankCH  = QuickHealVariables.MinrankValueCH  or 1

    debug(string.format("Found CH up to rank %d, downrank limit: %d, minrank: %d", maxRankCH, downRankCH, minRankCH))

    local tfMod     = mods.tfMod
    local tmMod     = mods.tmMod
    local healModCH = mods.healModCH
    local K         = 0.8 -- Combat compensation for slow spells

    if not forceMaxRank then
        -- Start with lowest rank within min/max range (default: rank 1)
        if maxRankCH >= 1 and minRankCH <= 1 and downRankCH >= 1 and SpellIDsCH[1] then
            SpellID = SpellIDsCH[1]; HealSize = (356 + healModCH)  * hwMod * tmMod
        elseif maxRankCH >= 2 and minRankCH <= 2 and downRankCH >= 2 and SpellIDsCH[2] then
            SpellID = SpellIDsCH[2]; HealSize = (449 + healModCH)  * hwMod * tmMod
        elseif maxRankCH >= 3 and minRankCH <= 3 and downRankCH >= 3 and SpellIDsCH[3] then
            SpellID = SpellIDsCH[3]; HealSize = (607 + healModCH)  * hwMod * tmMod
        end
        -- Upgrade to rank 2 if heal need exceeds threshold
        if healneed > (673  + healModCH)  * hwMod * tmMod * K and ManaLeft >= 315 * tfMod and maxRankCH >= 2 and minRankCH <= 2 and downRankCH >= 2 and SpellIDsCH[2] then
            SpellID = SpellIDsCH[2]; HealSize = (449  + healModCH)  * hwMod * tmMod
        end
        -- Upgrade to rank 3 if heal need exceeds threshold
        if healneed > (910  + healModCH)  * hwMod * tmMod * K and ManaLeft >= 405 * tfMod and maxRankCH >= 3 and minRankCH <= 3 and downRankCH >= 3 and SpellIDsCH[3] then
            SpellID = SpellIDsCH[3]; HealSize = (607  + healModCH)  * hwMod * tmMod
        end
    else
        -- Force max rank available within downrank limit
        if     maxRankCH >= 3 and downRankCH >= 3 and SpellIDsCH[3] then
            SpellID = SpellIDsCH[3]; HealSize = (607  + healModCH)  * hwMod * tmMod
        elseif maxRankCH >= 2 and downRankCH >= 2 and SpellIDsCH[2] then
            SpellID = SpellIDsCH[2]; HealSize = (449  + healModCH)  * hwMod * tmMod
        elseif maxRankCH >= 1 and downRankCH >= 1 and SpellIDsCH[1] then
            SpellID = SpellIDsCH[1]; HealSize = (356  + healModCH)  * hwMod * tmMod
        end
    end

    debug(string.format("SpellID: %s  HealSize: %s", tostring(SpellID), tostring(HealSize)))
    return SpellID, HealSize * HDB
end

-- NoTarget wrapper for Chain Heal
function QuickHeal_Shaman_FindChainHealSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxHPS, forceMaxRank, hdb, incombat)
    return QuickHeal_Shaman_FindChainHealSpellToUse(nil, healType, multiplier, forceMaxRank, maxhealth, healDeficit, hdb)
end

-- Unified heal spell selection (works with or without target)
function QuickHeal_Shaman_FindHealSpellToUse(target, healType, multiplier, forceMaxHPS, maxhealth, healDeficit, hdb, incombat)
    local SpellID  = nil
    local HealSize = 0
    multiplier = multiplier or 1
    local RatioFull    = QuickHealVariables["RatioFull"]
    local RatioHealthy = QuickHeal_GetRatioHealthy()
    local debug        = QuickHeal_debug

    -- ===== HEALTH INFO =====
    local healneed, Health, HDB, hwMod
    if target then
        if QuickHeal_UnitHasHealthInfo(target) then
            healneed = QH_GetUnitMaxHealth(target) - QH_GetUnitHealth(target)
            Health   = QH_GetUnitHealth(target) / QH_GetUnitMaxHealth(target)
        else
            healneed = QuickHeal_EstimateUnitHealNeed(target, true)
            Health   = QH_GetUnitHealth(target) / 100
        end
        HDB      = QuickHeal_GetHealModifier(target)
        incombat = UnitAffectingCombat('player') or UnitAffectingCombat(target)
        hwMod    = GetHealingWayMod(target)
    else
        if not maxhealth or maxhealth <= 0 then return nil, 0 end
        healneed = healDeficit * multiplier
        Health   = healDeficit / maxhealth
        HDB      = hdb or 1
        incombat = UnitAffectingCombat('player') or incombat
        hwMod    = 1
    end

    debug("Target debuff healing modifier", HDB)
    healneed = healneed / HDB
    if healneed <= 0 then return nil, 0 end

    -- ===== SETUP =====
    local mods     = GetShamanModifiers()
    local ManaLeft = QH_GetUnitMana('player')

    -- Ajustement combat selon buffs Shaman (Nature's Swiftness, Hand of Edward the Odd)
    incombat = CheckShamanBuffs(incombat)

    local SpellIDsHW  = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HEALING_WAVE)
    local SpellIDsLHW = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_LESSER_HEALING_WAVE)
    local maxRankHW   = table.getn(SpellIDsHW)
    local maxRankLHW  = table.getn(SpellIDsLHW)

    debug(string.format("Found HW up to rank %d, and found LHW up to rank %d", maxRankHW, maxRankLHW))

    local downRankFH = QuickHealVariables.DownrankValueFH or 99
    local downRankNH = QuickHealVariables.DownrankValueNH or 99
    local minRankFH  = QuickHealVariables.MinrankValueFH  or 1
    local minRankNH  = QuickHealVariables.MinrankValueNH  or 1

    local tfMod      = mods.tfMod
    local tmMod      = mods.tmMod
    local healModLHW = mods.healModLHW
    local healMod15, healMod20, healMod25, healMod30 = mods.healMod15, mods.healMod20, mods.healMod25, mods.healMod30

    -- =========================
    -- HEAL TYPE RESOLUTION
    -- =========================

    local TargetIsHealthy = Health >= RatioHealthy
    local forceHW  = (healType == "hw")
    local forceLHW = (healType == "lhw")
    local useHW
    if forceHW then
        useHW = true
    elseif forceLHW then
        useHW = false
    else
        if not incombat then
            useHW = true
        elseif not target then
            -- without target, can't get  RatioHealthy 
            -- we use HW if not force LHW 
            useHW = true
        else
            -- In combat with target : LHW if unhealthy
            -- if slider at 0 (RatioHealthy=0), TargetIsHealthy=false → LHW always
            -- if slide at max (RatioHealthy≥RatioFull), TargetIsHealthy=false → HW always
            useHW = (TargetIsHealthy or maxRankLHW < 1)
        end
    end

    debug("useHW=" .. tostring(useHW) .. " incombat=" .. tostring(incombat) .. " TargetIsHealthy=" .. tostring(TargetIsHealthy))

    -- ===== MODE MAX RANK =====
    if forceMaxHPS then
        debug("forceMaxHPS: useHW=" .. tostring(useHW))
        if useHW then
            if     maxRankHW >= 10 and ManaLeft >= 620 * tfMod and SpellIDsHW[10] then
                return SpellIDsHW[10], (1735  + healMod30)           * hwMod * tmMod * HDB
            elseif maxRankHW >= 9  and ManaLeft >= 560 * tfMod and SpellIDsHW[9]  then
                return SpellIDsHW[9],  (1464  + healMod30)           * hwMod * tmMod * HDB
            elseif maxRankHW >= 8  and ManaLeft >= 440 * tfMod and SpellIDsHW[8]  then
                return SpellIDsHW[8],  (1092  + healMod30)           * hwMod * tmMod * HDB
            elseif maxRankHW >= 7  and ManaLeft >= 340 * tfMod and SpellIDsHW[7]  then
                return SpellIDsHW[7],  (797   + healMod30)           * hwMod * tmMod * HDB
            elseif maxRankHW >= 6  and ManaLeft >= 265 * tfMod and SpellIDsHW[6]  then
                return SpellIDsHW[6],  (579   + healMod30)           * hwMod * tmMod * HDB
            elseif maxRankHW >= 5  and ManaLeft >= 200 * tfMod and SpellIDsHW[5]  then
                return SpellIDsHW[5],  (408   + healMod30)           * hwMod * tmMod * HDB
            elseif maxRankHW >= 4  and ManaLeft >= 155 * tfMod and SpellIDsHW[4]  then
                return SpellIDsHW[4],  (292   + healMod30 * PF[18]) * hwMod * tmMod * HDB
            elseif maxRankHW >= 3  and ManaLeft >= 80  * tfMod and SpellIDsHW[3]  then
                return SpellIDsHW[3],  (142   + healMod25 * PF[12]) * hwMod * tmMod * HDB
            elseif maxRankHW >= 2  and ManaLeft >= 45  * tfMod and SpellIDsHW[2]  then
                return SpellIDsHW[2],  (71    + healMod20 * PF[6])  * hwMod * tmMod * HDB
            elseif maxRankHW >= 1  and SpellIDsHW[1] then
                return SpellIDsHW[1],  (39    + healMod15 * PF[1])  * hwMod * tmMod * HDB
            end
        else
            if     maxRankLHW >= 6 and ManaLeft >= 380 * tfMod and SpellIDsLHW[6] then
                return SpellIDsLHW[6], (880   + healModLHW) * tmMod * HDB
            elseif maxRankLHW >= 5 and ManaLeft >= 305 * tfMod and SpellIDsLHW[5] then
                return SpellIDsLHW[5], (668   + healModLHW) * tmMod * HDB
            elseif maxRankLHW >= 4 and ManaLeft >= 235 * tfMod and SpellIDsLHW[4] then
                return SpellIDsLHW[4], (486   + healModLHW) * tmMod * HDB
            elseif maxRankLHW >= 3 and ManaLeft >= 185 * tfMod and SpellIDsLHW[3] then
                return SpellIDsLHW[3], (359   + healModLHW) * tmMod * HDB
            elseif maxRankLHW >= 2 and ManaLeft >= 145 * tfMod and SpellIDsLHW[2] then
                return SpellIDsLHW[2], (264   + healModLHW) * tmMod * HDB
            elseif maxRankLHW >= 1 and ManaLeft >= 105 * tfMod and SpellIDsLHW[1] then
                return SpellIDsLHW[1], (174   + healModLHW) * tmMod * HDB
            end
        end
        return nil, 0
    end

    -- ===== NORMAL LOGIC FROM HEALNEED =====
    
    local k = 0.9
    local K = 0.8
    local needsHeal = Health < RatioFull or QHV.TestMode or not target or (QHV.PrecastAggro and QuickHeal_UnitHasAggro(target))

    if useHW then
        -- ===== HW BRANCH : out of combat or healthy target or force HW =====
        debug("useHW=true: HW only branch")
        if needsHeal then
            if not forceLHW and maxRankHW >= 1 and SpellIDsHW[1] then
                SpellID = SpellIDsHW[1]; HealSize = (39  + healMod15 * PF[1]) * hwMod * tmMod
            end
            if not forceLHW and (healneed > (71    + healMod20 * PF[6])  * hwMod * tmMod or 2  <= minRankNH) and ManaLeft >= 45  * tfMod and maxRankHW >= 2  and downRankNH >= 2  and SpellIDsHW[2]  then SpellID = SpellIDsHW[2];  HealSize = (71    + healMod20 * PF[6])  * hwMod * tmMod end
            if not forceLHW and (healneed > (142   + healMod25 * PF[12]) * hwMod * tmMod or 3  <= minRankNH) and ManaLeft >= 80  * tfMod and maxRankHW >= 3  and downRankNH >= 3  and SpellIDsHW[3]  then SpellID = SpellIDsHW[3];  HealSize = (142   + healMod25 * PF[12]) * hwMod * tmMod end
            if not forceLHW and (healneed > (292   + healMod30 * PF[18]) * hwMod * tmMod or 4  <= minRankNH) and ManaLeft >= 155 * tfMod and maxRankHW >= 4  and downRankNH >= 4  and SpellIDsHW[4]  then SpellID = SpellIDsHW[4];  HealSize = (292   + healMod30 * PF[18]) * hwMod * tmMod end
            if not forceLHW and (healneed > (408   + healMod30)           * hwMod * tmMod or 5  <= minRankNH) and ManaLeft >= 200 * tfMod and maxRankHW >= 5  and downRankNH >= 5  and SpellIDsHW[5]  then SpellID = SpellIDsHW[5];  HealSize = (408   + healMod30)           * hwMod * tmMod end
            if not forceLHW and (healneed > (579   + healMod30)           * hwMod * tmMod or 6  <= minRankNH) and ManaLeft >= 265 * tfMod and maxRankHW >= 6  and downRankNH >= 6  and SpellIDsHW[6]  then SpellID = SpellIDsHW[6];  HealSize = (579   + healMod30)           * hwMod * tmMod end
            if not forceLHW and (healneed > (797   + healMod30)           * hwMod * tmMod or 7  <= minRankNH) and ManaLeft >= 340 * tfMod and maxRankHW >= 7  and downRankNH >= 7  and SpellIDsHW[7]  then SpellID = SpellIDsHW[7];  HealSize = (797   + healMod30)           * hwMod * tmMod end
            if not forceLHW and (healneed > (1092  + healMod30)           * hwMod * tmMod or 8  <= minRankNH) and ManaLeft >= 440 * tfMod and maxRankHW >= 8  and downRankNH >= 8  and SpellIDsHW[8]  then SpellID = SpellIDsHW[8];  HealSize = (1092  + healMod30)           * hwMod * tmMod end
            if not forceLHW and (healneed > (1464  + healMod30)           * hwMod * tmMod or 9  <= minRankNH) and ManaLeft >= 560 * tfMod and maxRankHW >= 9  and downRankNH >= 9  and SpellIDsHW[9]  then SpellID = SpellIDsHW[9];  HealSize = (1464  + healMod30)           * hwMod * tmMod end
            if not forceLHW and (healneed > (1735  + healMod30)           * hwMod * tmMod or 10 <= minRankNH) and ManaLeft >= 620 * tfMod and maxRankHW >= 10 and downRankNH >= 10 and SpellIDsHW[10] then SpellID = SpellIDsHW[10]; HealSize = (1735  + healMod30)           * hwMod * tmMod end
        end
    else
        -- ===== LHW BRANCH : in combat, unhealthy target, not forceHW =====
        debug("useHW=false: LHW only branch")
        if needsHeal then
            if not forceHW and maxRankLHW >= 1 and SpellIDsLHW[1] then
                SpellID = SpellIDsLHW[1]; HealSize = (174  + healModLHW) * hwMod * tmMod
            end
            if not forceHW and (healneed > (264  + healModLHW) * hwMod * tmMod * k or 2 <= minRankFH) and ManaLeft >= 145 * tfMod and maxRankLHW >= 2 and downRankFH >= 2 and SpellIDsLHW[2] then
                SpellID = SpellIDsLHW[2]; HealSize = (264  + healModLHW) * hwMod * tmMod
            end
            if not forceHW and (healneed > (359  + healModLHW) * hwMod * tmMod * k or 3 <= minRankFH) and ManaLeft >= 185 * tfMod and maxRankLHW >= 3 and downRankFH >= 3 and SpellIDsLHW[3] then
                SpellID = SpellIDsLHW[3]; HealSize = (359  + healModLHW) * hwMod * tmMod
            end
            if not forceHW and (healneed > (486  + healModLHW) * hwMod * tmMod * k or 4 <= minRankFH) and ManaLeft >= 235 * tfMod and maxRankLHW >= 4 and downRankFH >= 4 and SpellIDsLHW[4] then
                SpellID = SpellIDsLHW[4]; HealSize = (486  + healModLHW) * hwMod * tmMod
            end
            if not forceHW and (healneed > (668  + healModLHW) * hwMod * tmMod * k or 5 <= minRankFH) and ManaLeft >= 305 * tfMod and maxRankLHW >= 5 and downRankFH >= 5 and SpellIDsLHW[5] then
                SpellID = SpellIDsLHW[5]; HealSize = (668  + healModLHW) * hwMod * tmMod
            end
            if not forceHW and (healneed > (880  + healModLHW) * hwMod * tmMod * k or 6 <= minRankFH) and ManaLeft >= 380 * tfMod and maxRankLHW >= 6 and downRankFH >= 6 and SpellIDsLHW[6] then
                SpellID = SpellIDsLHW[6]; HealSize = (880  + healModLHW) * hwMod * tmMod
            end
        end
    end

    return SpellID, HealSize * HDB
end

-- NoTarget wrapper for backwards compatibility
function QuickHeal_Shaman_FindHealSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxHPS, forceMaxRank, hdb, incombat)
    return QuickHeal_Shaman_FindHealSpellToUse(nil, healType, multiplier, forceMaxHPS, maxhealth, healDeficit, hdb, incombat)
end

-- Command handler
function QuickHeal_Command_Shaman(msg)
    local _, _, arg1, arg2, arg3 = string.find(msg, "%s?(%w+)%s?(%w+)%s?(%w+)")

    -- Match 3 arguments
    if arg1 and arg2 and arg3 then
        if arg1 == "player" or arg1 == "target" or arg1 == "targettarget" or arg1 == "party" or arg1 == "subgroup" or arg1 == "mt" or arg1 == "nonmt" then
            if arg2 == "heal" and arg3 == "max" then
                -- /qh [mask] heal max : HW ou LHW rang max selon slider
                QuickHeal(arg1, nil, nil, true)
                return
            end
            if arg2 == "hw" and arg3 == "max" then
                -- /qh [mask] hw max : HW uniquement, rang max selon mana
                QuickHeal(arg1, nil, {healType = "hw"}, true)
                return
            end
            if arg2 == "lhw" and arg3 == "max" then
                -- /qh [mask] lhw max : LHW uniquement, rang max selon mana
                QuickHeal(arg1, nil, {healType = "lhw"}, true)
                return
            end
            if arg2 == "chainheal" and arg3 == "max" then
                -- /qh [mask] chainheal max : Chain Heal rang max
                QuickChainHeal(arg1, nil, nil, true, true)
                return
            end
        end
    end

    -- Match 2 arguments
    local _, _, arg4, arg5 = string.find(msg, "%s?(%w+)%s?(%w+)")
    if arg4 and arg5 then
        if arg4 == "debug" then
            if arg5 == "on" then
                QHV.DebugMode = true
                return
            elseif arg5 == "off" then
                QHV.DebugMode = false
                return
            end
        end
        if arg4 == "test" then
            if arg5 == "on" then
                QHV.TestMode = true
                writeLine("QuickHeal: Test mode enabled (ignoring health thresholds)", 0, 1, 0)
                return
            elseif arg5 == "off" then
                QHV.TestMode = false
                writeLine("QuickHeal: Test mode disabled", 1, 1, 0)
                return
            end
        end
        if arg4 == "chainheal" and arg5 == "max" then
            -- /qh chainheal max : Chain Heal rang max
            QuickChainHeal(nil, nil, nil, true, false)
            return
        end
        if arg4 == "heal" and arg5 == "max" then
            -- /qh heal max : HW ou LHW rang max selon slider
            QuickHeal(nil, nil, nil, true)
            return
        end
        if arg4 == "hw" and arg5 == "max" then
            -- /qh hw max : HW uniquement, rang max selon mana
            QuickHeal(nil, nil, {healType = "hw"}, true)
            return
        end
        if arg4 == "lhw" and arg5 == "max" then
            -- /qh lhw max : LHW uniquement, rang max selon mana
            QuickHeal(nil, nil, {healType = "lhw"}, true)
            return
        end
        if arg4 == "player" or arg4 == "target" or arg4 == "targettarget" or arg4 == "party" or arg4 == "subgroup" or arg4 == "mt" or arg4 == "nonmt" then
            if arg5 == "chainheal" then
                QuickChainHeal(arg4, nil, nil, false)
                return
            end
            if arg5 == "heal" then
                QuickHeal(arg4, nil, nil, false)
                return
            end
            if arg5 == "hw" then
                -- /qh [mask] hw : HW uniquement sur une cible spécifique
                QuickHeal(arg4, nil, {healType = "hw"}, false)
                return
            end
            if arg5 == "lhw" then
                -- /qh [mask] lhw : LHW uniquement sur une cible spécifique
                QuickHeal(arg4, nil, {healType = "lhw"}, false)
                return
            end
        end
    end

    -- Match 1 argument
    local cmd = string.lower(msg)
    if cmd == "cfg" then
        QuickHeal_ToggleConfigurationPanel()
        return
    end
    if cmd == "toggle" then
        QuickHeal_Toggle_Healthy_Threshold()
        return
    end
    if cmd == "downrank" or cmd == "dr" or cmd == "minrank" or cmd == "ranks" then
        ToggleDownrankWindow()
        return
    end
    if cmd == "tanklist" or cmd == "tl" then
        QH_ShowHideMTListUI()
        return
    end
    if cmd == "reset" then
        QuickHeal_SetDefaultParameters()
        writeLine(QuickHealData.name .. " reset to default configuration", 0, 0, 1)
        QuickHeal_ToggleConfigurationPanel()
        QuickHeal_ToggleConfigurationPanel()
        return
    end
    if cmd == "dll" then
        QuickHeal_ReportDLLStatus()
        return
    end
    if cmd == "chainheal" then
        -- /qh chainheal : Chain Heal sélection par healneed
        QuickChainHeal()
        return
    end
    if cmd == "hw" then
        -- /qh hw : HW uniquement, sélection par healneed
        QuickHeal(nil, nil, {healType = "hw"}, false)
        return
    end
    if cmd == "lhw" then
        -- /qh lhw : LHW uniquement, sélection par healneed
        QuickHeal(nil, nil, {healType = "lhw"}, false)
        return
    end
    if cmd == "heal" then
        -- /qh heal : HW ou LHW selon logique slider
        QuickHeal()
        return
    end
    if cmd == "" then
        QuickHeal(nil)
        return
    elseif cmd == "player" or cmd == "target" or cmd == "targettarget" or cmd == "party" or cmd == "subgroup" or cmd == "mt" or cmd == "nonmt" then
        QuickHeal(cmd)
        return
    end

    -- Print usage
    writeLine("== QUICKHEAL USAGE : SHAMAN ==")
    writeLine("/qh cfg - Opens up the configuration panel.")
    writeLine("/qh test on|off - Toggles test mode (ignores health thresholds).")
    writeLine("/qh debug on|off - Toggles debug output.")
    writeLine("/qh dll - Report DLL enhancement status.")
    writeLine("/qh toggle - Switches between High HPS and Normal HPS.")
    writeLine("/qh downrank | dr | minrank | ranks - Opens the slider to constrain healing to lower ranks.")
    writeLine("/qh tanklist | tl - Toggles display of the main tank list UI.")
    writeLine("/qh reset - Reset configuration to default parameters.")
    writeLine("/qh heal - HW or LHW with slider logic (HW if healthy/out of combat, LHW otherwise)")
    writeLine("/qh heal max - Max rank HW or LHW with slider logic")
    writeLine("/qh hw - Healing Wave only (rank by healneed)")
    writeLine("/qh hw max - Max rank Healing Wave only")
    writeLine("/qh lhw - Lesser Healing Wave only (rank by healneed)")
    writeLine("/qh lhw max - Max rank Lesser Healing Wave only")
    writeLine("/qh chainheal - Chain Heal (rank by healneed)")
    writeLine("/qh chainheal max - Max rank Chain Heal")
    writeLine("/qh [mask] [type] [mod] - Heals the party/raid member that most needs it.")
    writeLine(" [mask]: player, target, targettarget, party, mt, nonmt, subgroup")
    writeLine(" [type]: heal (HW/LHW), hw (HW only), lhw (LHW only), chainheal (Chain Heal)")
    writeLine(" [mod]: max (max rank)")
end
