-- QuickHeal Priest Module (Refactored)
-- Consolidated spell selection with shared helper functions

-- Penalty Factors for low-level spells
local PF = QuickHeal_PenaltyFactor or {
    [1] = 0.2875, [4] = 0.4, [10] = 0.625, [18] = 0.925, [20] = 1.0
}

function QuickHeal_Priest_GetRatioHealthyExplanation()
    if QuickHealVariables.RatioHealthyPriest >= QuickHealVariables.RatioFull then
        return QUICKHEAL_SPELL_FLASH_HEAL ..
            " will always be used in combat, and " ..
            QUICKHEAL_SPELL_LESSER_HEAL ..
            ", " ..
            QUICKHEAL_SPELL_HEAL .. " or " .. QUICKHEAL_SPELL_GREATER_HEAL .. " will be used when out of combat. ";
    else
        if QuickHealVariables.RatioHealthyPriest > 0 then
            return QUICKHEAL_SPELL_FLASH_HEAL ..
                " will be used in combat if the target has less than " ..
                QuickHealVariables.RatioHealthyPriest * 100 ..
                "% life, and " ..
                QUICKHEAL_SPELL_LESSER_HEAL ..
                ", " .. QUICKHEAL_SPELL_HEAL .. " or " .. QUICKHEAL_SPELL_GREATER_HEAL .. " will be used otherwise. ";
        else
            return QUICKHEAL_SPELL_FLASH_HEAL ..
                " will never be used. " ..
                QUICKHEAL_SPELL_LESSER_HEAL ..
                ", " ..
                QUICKHEAL_SPELL_HEAL ..
                " or " .. QUICKHEAL_SPELL_GREATER_HEAL .. " will always be used in and out of combat. ";
        end
    end
end

-- Calculate all Priest-specific modifiers
-- Returns: table with bonus, healMods, shMod, ihMod, sgMod
local function GetPriestModifiers()
    local mods = {}

    -- Equipment healing bonus (cached)
    mods.bonus = QuickHeal_GetEquipmentBonus()

    -- Spiritual Guidance - 5% of Spirit per rank
    local sgRank = QuickHeal_GetTalentRank(2, 14)
    local _, spirit = UnitStat('player', 5)
    mods.sgMod = (spirit or 0) * 5 * sgRank / 100

    -- Total healing bonus
    local totalBonus = mods.bonus + mods.sgMod

    -- Healing modifiers by cast time 
    mods.healMod15 = (1.5 / 3.5) * totalBonus 
    mods.healMod20 = (2.0 / 3.5) * totalBonus 
    mods.healMod25 = (2.5 / 3.5) * totalBonus
    mods.healMod30 = (3.0 / 3.5) * totalBonus

    -- HoT modifiers (no downrank penalty)
    mods.hotMod15 = (1.5 / 3.5) * totalBonus
    mods.hotMod35 = (15 / 15) * totalBonus

    -- Spiritual Healing - 2% per rank
    local shRank = QuickHeal_GetTalentRank(2, 15)
    mods.shMod = 1 + 2 * shRank / 100

    -- Improved Healing - reduces mana by 5% per rank
    local ihRank = QuickHeal_GetTalentRank(2, 10)
    mods.ihMod = 1 - 5 * ihRank / 100

    return mods
end

-- Check for Priest-specific buffs that affect healing
-- Returns: inCombat (adjusted), manaLeft (adjusted), healneed (adjusted), forceGH
local function CheckPriestBuffs(target, inCombat, manaLeft, healneed)
    local forceGH = false

    -- Nampower: use aura spell ID array for reliable detection
    if GetUnitField then
        local success, auras = pcall(GetUnitField, "player", "aura")
        if success and auras then
            for i = 1, 31 do -- slots 1-31 are buffs
                local spellId = auras[i]
                if spellId and spellId > 0 then
                    if spellId == 18803 then -- Focus (Hand of Edward the Odd)
                        QuickHeal_debug("BUFF: Hand of Edward the Odd [" .. spellId .. "] (out of combat healing forced)")
                        inCombat = false
                    elseif spellId == 24546 then -- Rapid Healing (Hazza'rah's Charm of Healing)
                        QuickHeal_debug("BUFF: Hazza'rah buff [" .. spellId .. "] (Greater Heal forced)")
                        forceGH = true
                    elseif spellId == 14751 or spellId == 20711 then -- Inner Focus / Spirit of Redemption
                        QuickHeal_debug("BUFF: Free mana [" .. spellId .. "]")
                        manaLeft = QH_GetUnitMaxMana('player')
                        healneed = 1000000
                    end
                end
            end
        end
    end

    -- Texture-based detection (fallback for buffs not caught by Nampower aura names)
    -- Hand of Edward the Odd - instant cast
    -- Note: Must exclude "Protective Light" which uses icon "Spell_Holy_SearingLightPriest"
    if not (inCombat == false) and
       QuickHeal_DetectBuff('player', "Spell_Holy_SearingLight") and
       not QuickHeal_DetectBuff('player', "Spell_Holy_SearingLightPriest") then
        QuickHeal_debug("BUFF: Hand of Edward the Odd (texture fallback, out of combat healing forced)")
        inCombat = false
    end

    -- Hazza'rah's Charm - force Greater Heal
    if not forceGH and QuickHeal_DetectBuff('player', "Spell_Holy_HealingAura") then
        QuickHeal_debug("BUFF: Hazza'rah buff (texture fallback, Greater Heal forced)")
        forceGH = true
    end

    -- Inner Focus or Spirit of Redemption - free mana
    if manaLeft ~= QH_GetUnitMaxMana('player') and
       (QuickHeal_DetectBuff('player', "Spell_Frost_WindWalkOn", 1) or
        QuickHeal_DetectBuff('player', "Spell_Holy_GreaterHeal")) then
        QuickHeal_debug("Inner Focus or Spirit of Redemption active (texture fallback)")
        manaLeft = QH_GetUnitMaxMana('player')
        healneed = 1000000
    end

    return inCombat, manaLeft, healneed, forceGH
end

-- Unified heal spell selection (works with or without target)
-- target: unit ID or nil (for NoTarget mode)
-- maxhealth, healDeficit, hdb, incombat: used when target is nil
function QuickHeal_Priest_FindHealSpellToUse(target, healType, multiplier, forceMaxHPS, maxhealth, healDeficit, hdb, incombat)
    local SpellID = nil
    local HealSize = 0
    multiplier = multiplier or 1

    -- Get health info
    local healneed, Health, HDB
    if target then
        healneed, Health, HDB = QuickHeal_GetTargetHealth(target, nil, nil, multiplier, nil)
        incombat = UnitAffectingCombat('player') or UnitAffectingCombat(target)
    else
        healneed, Health, HDB = QuickHeal_GetTargetHealth(nil, maxhealth, healDeficit, multiplier, hdb)
        incombat = UnitAffectingCombat('player') or incombat
    end

    if healneed <= 0 then return nil, 0 end

    -- Modifiers
    local mods = GetPriestModifiers()
    local ManaLeft = QH_GetUnitMana('player')

    -- Buffs
    local forceGH
    incombat, ManaLeft, healneed, forceGH = CheckPriestBuffs(target, incombat, ManaLeft, healneed)

    -- Spells
    local SpellIDsLH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_LESSER_HEAL)
    local SpellIDsH  = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HEAL)
    local SpellIDsGH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_GREATER_HEAL)
    local SpellIDsFH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_FLASH_HEAL)

    local maxRankLH = table.getn(SpellIDsLH)
    local maxRankH  = table.getn(SpellIDsH)
    local maxRankGH = table.getn(SpellIDsGH)
    local maxRankFH = table.getn(SpellIDsFH)

    -- Settings
    local downRankFH = QuickHealVariables.DownrankValueFH or 99
    local downRankNH = QuickHealVariables.DownrankValueNH or 99
    local minRankFH  = QuickHealVariables.MinrankValueFH or 1
    local minRankNH  = QuickHealVariables.MinrankValueNH or 1

    local k, K = QuickHeal_GetCombatMultipliers(incombat)

    local TargetIsHealthy = Health >= QuickHealVariables.RatioHealthyPriest
    local shMod = mods.shMod
    local ihMod = mods.ihMod
    local healMod15, healMod20, healMod25, healMod30 = mods.healMod15, mods.healMod20, mods.healMod25, mods.healMod30

    -- =========================
    -- FORCE GREATER HEAL
    -- =========================
    if (forceGH or healType == "gh") and ManaLeft >= 370 * ihMod and maxRankGH >= 1 and downRankNH >= 8 and SpellIDsGH[1] then
        if Health < QuickHealVariables.RatioFull or QHV.TestMode or (QHV.PrecastAggro and QuickHeal_UnitHasAggro(target)) then
            SpellID = SpellIDsGH[1]; HealSize = (956 + healMod30) * shMod

            if (healneed > (1219* shMod + healMod30) * K or 9 <= minRankNH) and ManaLeft >= 455 * ihMod and maxRankGH >= 2 and downRankNH >= 9 and SpellIDsGH[2] then
                SpellID = SpellIDsGH[2]; HealSize = (1219* shMod + healMod30) 
            end
            if (healneed > (1523* shMod + healMod30) * K or 10 <= minRankNH) and ManaLeft >= 545 * ihMod and maxRankGH >= 3 and downRankNH >= 10 and SpellIDsGH[3] then
                SpellID = SpellIDsGH[3]; HealSize = (1523* shMod + healMod30) 
            end
            if (healneed > (1902* shMod + healMod30) * K  or 11 <= minRankNH) and ManaLeft >= 655 * ihMod and maxRankGH >= 4 and downRankNH >= 11 and SpellIDsGH[4] then
                SpellID = SpellIDsGH[4]; HealSize = (1902* shMod + healMod30) 
            end
            if (healneed > (2080* shMod + healMod30) * K  or 12 <= minRankNH) and ManaLeft >= 710 * ihMod and maxRankGH >= 5 and downRankNH >= 12 and SpellIDsGH[5] then
                SpellID = SpellIDsGH[5]; HealSize = (2080* shMod + healMod30) 
            end
        end

    -- =========================
    -- NORMAL HEAL (LESSER OR HEAL OR GREATER)
    -- =========================
    elseif (not forceMaxHPS) and (not incombat or TargetIsHealthy or maxRankFH < 1) then
        if Health < QuickHealVariables.RatioFull or QHV.TestMode or (QHV.PrecastAggro and QuickHeal_UnitHasAggro(target)) then
            SpellID = SpellIDsLH[1]; HealSize = (51* shMod + healMod15 * PF[1]) 

            if (healneed > (78* shMod + healMod20 * PF[4]) * k or 2 <= minRankNH) and ManaLeft >= 45 * ihMod and maxRankLH >= 2 then
                SpellID = SpellIDsLH[2]; HealSize = (78* shMod + healMod20 * PF[4]) 
            end
            if (healneed > (146* shMod + healMod25 * PF[10]) * K  or 3 <= minRankNH) and ManaLeft >= 75 * ihMod and maxRankLH >= 3 then
                SpellID = SpellIDsLH[3]; HealSize = (146* shMod + healMod25 * PF[10]) 
            end

            if (healneed > (318* shMod + healMod30 * PF[18]) * K or 4 <= minRankNH) and ManaLeft >= 155 * ihMod and maxRankH >= 1 then
                SpellID = SpellIDsH[1]; HealSize = (318* shMod + healMod30 * PF[18]) 
            end
            if (healneed > (460* shMod + healMod30) * K or 5 <= minRankNH) and ManaLeft >= 205 * ihMod and maxRankH >= 2 then
                SpellID = SpellIDsH[2]; HealSize = (460* shMod + healMod30) 
            end

            if (healneed > (604* shMod + healMod30) * K or 6 <= minRankNH) and ManaLeft >= 255 * ihMod and maxRankH >= 3 then
                SpellID = SpellIDsH[3]; HealSize = (604* shMod + healMod30) 
            end
            if (healneed > (758* shMod + healMod30) * K or 7 <= minRankNH) and ManaLeft >= 305 * ihMod and maxRankH >= 4 then
                SpellID = SpellIDsH[4]; HealSize = (758* shMod + healMod30) 
            end

            if (healneed > (956* shMod + healMod30) * K  or 8 <= minRankNH) and ManaLeft >= 370 * ihMod and maxRankGH >= 1 then
                SpellID = SpellIDsGH[1]; HealSize = (956* shMod + healMod30) 
            end
            if (healneed > (1219* shMod + healMod30) * K  or 9 <= minRankNH) and ManaLeft >= 455 * ihMod and maxRankGH >= 2 then
                SpellID = SpellIDsGH[2]; HealSize = (1219* shMod + healMod30) 
            end
            if (healneed > (1523* shMod + healMod30) * K  or 10 <= minRankNH) and ManaLeft >= 545 * ihMod and maxRankGH >= 3 then
                SpellID = SpellIDsGH[3]; HealSize = (1523* shMod + healMod30) 
            end
            if (healneed > (1902* shMod + healMod30) * K  or 11 <= minRankNH) and ManaLeft >= 655 * ihMod and maxRankGH >= 4 then
                SpellID = SpellIDsGH[4]; HealSize = (1902* shMod + healMod30) 
            end
            if (healneed > (2080* shMod + healMod30) * K  or 12 <= minRankNH) and ManaLeft >= 710 * ihMod and maxRankGH >= 5 then
                SpellID = SpellIDsGH[5]; HealSize = (2080* shMod + healMod30) 
            end
        end

    -- =========================
    -- FLASH HEAL (when target is low) 
    -- =========================
    elseif not forceMaxHPS then
        if Health < QuickHealVariables.RatioFull or QHV.TestMode or (QHV.PrecastAggro and QuickHeal_UnitHasAggro(target)) then
            SpellID = SpellIDsFH[1]; HealSize = (215* shMod + healMod15) 

            if (healneed > (286* shMod + healMod15) * k  or 2 <= minRankFH) and ManaLeft >= 155 and maxRankFH >= 2 then
                SpellID = SpellIDsFH[2]; HealSize = (286* shMod + healMod15) 
            end
            if (healneed > (360* shMod + healMod15) * k  or 3 <= minRankFH) and ManaLeft >= 185 and maxRankFH >= 3 then
                SpellID = SpellIDsFH[3]; HealSize = (360* shMod + healMod15) 
            end
            if (healneed > (439* shMod + healMod15) * k  or 4 <= minRankFH) and ManaLeft >= 215 and maxRankFH >= 4 then
                SpellID = SpellIDsFH[4]; HealSize = (439* shMod + healMod15) 
            end
            if (healneed > (567* shMod + healMod15) * k  or 5 <= minRankFH) and ManaLeft >= 265 and maxRankFH >= 5 then
                SpellID = SpellIDsFH[5]; HealSize = (567* shMod + healMod15) 
            end
            if (healneed > (704* shMod + healMod15) * k  or 6 <= minRankFH) and ManaLeft >= 315 and maxRankFH >= 6 then
                SpellID = SpellIDsFH[6]; HealSize = (704* shMod + healMod15) 
            end
            if (healneed > (888* shMod + healMod15) * k  or 7 <= minRankFH) and ManaLeft >= 380 and maxRankFH >= 7 then
                SpellID = SpellIDsFH[7]; HealSize = (888* shMod + healMod15) 
            end
        end

    -- =========================
    -- MAX RANK FLASH HEAL 
    -- =========================
    else
        if ManaLeft >= 125 and maxRankFH >= 1 then
            SpellID = SpellIDsFH[1]; HealSize = (215* shMod + healMod15) 
        end
        if ManaLeft >= 155 and maxRankFH >= 2 then
            SpellID = SpellIDsFH[2]; HealSize = (286* shMod + healMod15) 
        end
        if ManaLeft >= 185 and maxRankFH >= 3 then
            SpellID = SpellIDsFH[3]; HealSize = (360* shMod + healMod15) 
        end
        if ManaLeft >= 215 and maxRankFH >= 4 then
            SpellID = SpellIDsFH[4]; HealSize = (439* shMod + healMod15) 
        end
        if ManaLeft >= 265 and maxRankFH >= 5 then
            SpellID = SpellIDsFH[5]; HealSize = (567* shMod + healMod15) 
        end
        if ManaLeft >= 315 and maxRankFH >= 6 then
            SpellID = SpellIDsFH[6]; HealSize = (704* shMod + healMod15) 
        end
        if ManaLeft >= 380 and maxRankFH >= 7 then
            SpellID = SpellIDsFH[7]; HealSize = (888* shMod + healMod15) 
        end
    end

    return SpellID, HealSize * HDB
end

-- NoTarget wrapper for backwards compatibility
function QuickHeal_Priest_FindHealSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxHPS,
                                                     forceMaxRank, hdb, incombat)
    return QuickHeal_Priest_FindHealSpellToUse(nil, healType, multiplier, forceMaxHPS, maxhealth, healDeficit, hdb,
        incombat)
end

    -- =========================
    -- RENEW
    -- =========================


-- Unified HoT spell selection (Renew)
function QuickHeal_Priest_FindHoTSpellToUse(target, healType, forceMaxRank, maxhealth, healDeficit, hdb, incombat)
    local SpellID = nil
    local HealSize = 0

    -- Get health info
    local healneed, Health, HDB
    if target then
        healneed, Health, HDB = QuickHeal_GetTargetHealth(target, nil, nil, 1, nil)
        incombat = UnitAffectingCombat('player') or UnitAffectingCombat(target)
    else
        healneed, Health, HDB = QuickHeal_GetTargetHealth(nil, maxhealth, healDeficit, 1, hdb)
        incombat = UnitAffectingCombat('player') or incombat
    end

    -- Get modifiers
    local mods = GetPriestModifiers()
    local ManaLeft = QH_GetUnitMana('player')

    -- Check buffs
    incombat, ManaLeft, healneed = CheckPriestBuffs(target, incombat, ManaLeft, healneed)

    -- Get Renew spell IDs
    local SpellIDsR = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_RENEW)
    local maxRankR = table.getn(SpellIDsR)

    local k, K = QuickHeal_GetCombatMultipliers(incombat)
    local shMod = mods.shMod
    local hotMod35 = mods.hotMod35

    if healType == "hot" then
        if not forceMaxRank then
            -- Select rank based on healneed
            SpellID = SpellIDsR[1]; HealSize = (45* shMod + hotMod35) 
            if healneed > (100* shMod + hotMod35) * k  and ManaLeft >= 65 and maxRankR >= 2 and SpellIDsR[2] then
                SpellID = SpellIDsR[2]; HealSize = (100* shMod + hotMod35) 
            end
            if healneed > (175* shMod + hotMod35) * k  and ManaLeft >= 105 and maxRankR >= 3 and SpellIDsR[3] then
                SpellID = SpellIDsR[3]; HealSize = (175* shMod + hotMod35) 
            end
            if healneed > (245* shMod  + hotMod35) * k and ManaLeft >= 140 and maxRankR >= 4 and SpellIDsR[4] then
                SpellID = SpellIDsR[4]; HealSize = (245* shMod + hotMod35) 
            end
            if healneed > (315* shMod + hotMod35) * k  and ManaLeft >= 170 and maxRankR >= 5 and SpellIDsR[5] then
                SpellID = SpellIDsR[5]; HealSize = (315* shMod + hotMod35) 
            end
            if healneed > (400* shMod + hotMod35) * k  and ManaLeft >= 205 and maxRankR >= 6 and SpellIDsR[6] then
                SpellID = SpellIDsR[6]; HealSize = (400* shMod + hotMod35) 
            end
            if healneed > (510* shMod + hotMod35) * k  and ManaLeft >= 250 and maxRankR >= 7 and SpellIDsR[7] then
                SpellID = SpellIDsR[7]; HealSize = (510* shMod + hotMod35)
            end
            if healneed > (650* shMod + hotMod35) * k  and ManaLeft >= 305 and maxRankR >= 8 and SpellIDsR[8] then
                SpellID = SpellIDsR[8]; HealSize = (650* shMod + hotMod35) 
            end
            if healneed > (810* shMod + hotMod35) * k  and ManaLeft >= 365 and maxRankR >= 9 and SpellIDsR[9] then
                SpellID = SpellIDsR[9]; HealSize = (810* shMod + hotMod35) 
            end
            if healneed > (970* shMod + hotMod35) * k  and ManaLeft >= 410 and maxRankR >= 10 and SpellIDsR[10] then
                SpellID = SpellIDsR[10]; HealSize = (970* shMod + hotMod35) 
            end
        else
            -- Force max rank
            if maxRankR >= 1 and SpellIDsR[1] then
                SpellID = SpellIDsR[1]; HealSize = (45* shMod + hotMod35) 
            end
            if maxRankR >= 2 and SpellIDsR[2] then
                SpellID = SpellIDsR[2]; HealSize = (100* shMod + hotMod35) 
            end
            if maxRankR >= 3 and SpellIDsR[3] then
                SpellID = SpellIDsR[3]; HealSize = (175* shMod + hotMod35) 
            end
            if maxRankR >= 4 and SpellIDsR[4] then
                SpellID = SpellIDsR[4]; HealSize = (245* shMod + hotMod35) 
            end
            if maxRankR >= 5 and SpellIDsR[5] then
                SpellID = SpellIDsR[5]; HealSize = (315* shMod + hotMod35) 
            end
            if maxRankR >= 6 and SpellIDsR[6] then
                SpellID = SpellIDsR[6]; HealSize = (400* shMod + hotMod35) 
            end
            if maxRankR >= 7 and SpellIDsR[7] then
                SpellID = SpellIDsR[7]; HealSize = (510* shMod + hotMod35) 
            end
            if maxRankR >= 8 and SpellIDsR[8] then
                SpellID = SpellIDsR[8]; HealSize = (650* shMod + hotMod35) 
            end
            if maxRankR >= 9 and SpellIDsR[9] then
                SpellID = SpellIDsR[9]; HealSize = (810* shMod + hotMod35) 
            end
            if maxRankR >= 10 and SpellIDsR[10] then
                SpellID = SpellIDsR[10]; HealSize = (970* shMod + hotMod35) 
            end
        end
    elseif healType == "channel" then
        -- Channel heal type uses direct heals
        return QuickHeal_Priest_FindHealSpellToUse(target, healType, 1, false, maxhealth, healDeficit, hdb, incombat)
    end

    return SpellID, HealSize * HDB
end

-- NoTarget wrapper for backwards compatibility
function QuickHeal_Priest_FindHoTSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxHPS,
                                                    forceMaxRank, hdb, incombat)
    return QuickHeal_Priest_FindHoTSpellToUse(nil, healType, forceMaxRank, maxhealth, healDeficit, hdb, incombat)
end

-- Utility function to get spell info by healneed
function QuickHealSpellID(healneed)
    local SpellID, HealSize = QuickHeal_Priest_FindHealSpellToUse(nil, "channel", 1, false, 10000, healneed, 1, false)

    if not SpellID then
        return nil, nil
    end

    local SpellName, SpellRank = GetSpellName(SpellID, BOOKTYPE_SPELL)
    if SpellRank == "" then SpellRank = nil end

    local rankNum = SpellRank and string.gsub(SpellRank, "%a+", "") or "1"
    return SpellName, rankNum
end





-- Command handler
function QuickHeal_Command_Priest(msg)
    local _, _, arg1, arg2, arg3 = string.find(msg, "%s?(%w+)%s?(%w+)%s?(%w+)")

    -- =========================
    -- Match 3 arguments
    -- =========================
    if arg1 and arg2 and arg3 then
        if arg1 == "player" or arg1 == "target" or arg1 == "targettarget" or arg1 == "party" or arg1 == "subgroup" or arg1 == "mt" or arg1 == "nonmt" then
            if arg2 == "heal" and arg3 == "max" then
                QuickHeal(arg1, nil, nil, true)
                return
            end
            if arg2 == "hot" and arg3 == "spam" then
                QuickHOT(arg1, nil, nil, true, true)
                return
            end
            if arg2 == "hot" and arg3 == "max" then
                QuickHOT(arg1, nil, nil, true, false)
                return
            end
        end
    end

    -- =========================
    -- Match 2 arguments
    -- =========================
    local _, _, arg4, arg5 = string.find(msg, "%s?(%w+)%s?(%w+)")

    if arg4 and arg5 then
        -- Debug
        if arg4 == "debug" then
            if arg5 == "on" then
                QHV.DebugMode = true
                return
            elseif arg5 == "off" then
                QHV.DebugMode = false
                return
            end
        end

        -- Test mode
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

        -- Global commands
        if arg4 == "heal" and arg5 == "max" then
            QuickHeal(nil, nil, nil, true)
            return
        end
        if arg4 == "hot" and arg5 == "max" then
            QuickHOT(nil, nil, nil, true, false)
            return
        end
        if arg4 == "hot" and arg5 == "spam" then
            QuickHOT(nil, nil, nil, true, true)
            return
        end

        -- Masked commands
        if arg4 == "player" or arg4 == "target" or arg4 == "targettarget" or arg4 == "party" or arg4 == "subgroup" or arg4 == "mt" or arg4 == "nonmt" then
            if arg5 == "hot" then
                QuickHOT(arg4, nil, nil, false, false)
                return
            end
            if arg5 == "heal" then
                QuickHeal(arg4, nil, nil, false)
                return
            end
            if arg5 == "gh" then
                QuickHeal(arg4, nil, {healType = "gh"})
                return
            end
        end
    end

    -- =========================
    -- Match 1 argument
    -- =========================
    local cmd = string.lower(msg or "")

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

    -- New GH command
    if cmd == "gh" then
        QuickHeal(nil, nil, {healType = "gh"})
        return
    end

    if cmd == "heal" then
        QuickHeal()
        return
    end
    if cmd == "hot" then
        QuickHOT()
        return
    end
    if cmd == "" then
        QuickHeal(nil)
        return
    elseif cmd == "player" or cmd == "target" or cmd == "targettarget" or cmd == "party" or cmd == "subgroup" or cmd == "mt" or cmd == "nonmt" then
        QuickHeal(cmd)
        return
    end

    -- =========================
    -- Help
    -- =========================
    writeLine("== QUICKHEAL PRIEST ==")
    
    -- Core usage
    writeLine(" ")
    writeLine("Basic usage:")
    writeLine("/qh [target] [type] [mode]")
    
    writeLine("Targets:")
    writeLine(" player | target | targettarget | party | mt | nonmt | subgroup")
    
    writeLine("Types:")
    writeLine(" heal  - Smart heal (uses slider logic)")
    writeLine(" gh    - Force Greater Heal")
    writeLine(" hot   - Renew")
    
    writeLine("Modes:")
    writeLine(" max   - Use highest rank (FH / Renew)")
    writeLine(" spam  - Ignore HP, spam max Renew")
    
    -- Examples
    writeLine(" ")
    writeLine("Examples:")
    writeLine("/qh                 - Smart heal depending on slider")
    writeLine("/qh heal max        - Max rank Flash Heal")
    writeLine("/qh hot spam        - Spam max Renew")
    
    -- Settings
    writeLine(" ")
    writeLine("Settings:")
    writeLine("/qh cfg             - Open config")
    writeLine("/qh toggle          - Switch HPS mode (slider)")
    writeLine("/qh downrank | dr   - Limit usable ranks")
    writeLine("/qh tanklist | tl   - Toggle tank list")
    writeLine("/qh reset           - Reset settings")
    
    -- Debug
    writeLine(" ")
    writeLine("Other:")
    writeLine("/qh test on|off     - Test mode")
    writeLine("/qh debug on|off    - Debug mode")
    writeLine("/qh dll             - DLL status")
end
