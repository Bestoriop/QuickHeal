-- QuickHeal Priest Module (Refactored)
-- Penalty Factors for low-level spells
local PF = QuickHeal_PenaltyFactor or {
    [1] = 0.2875, [4] = 0.4, [10] = 0.625, [18] = 0.925, [20] = 1.0
}

function QuickHeal_Priest_GetRatioHealthyExplanation()
    if QuickHealVariables.RatioHealthyPriest >= QuickHealVariables.RatioFull then
        return QUICKHEAL_SPELL_FLASH_HEAL ..
            " will always be used in combat, and " ..
            QUICKHEAL_SPELL_LESSER_HEAL ..
            ", " .. QUICKHEAL_SPELL_HEAL .. " or " .. QUICKHEAL_SPELL_GREATER_HEAL ..
            " will be used when out of combat. "
    elseif QuickHealVariables.RatioHealthyPriest > 0 then
        return QUICKHEAL_SPELL_FLASH_HEAL ..
            " will be used in combat if the target has less than " ..
            QuickHealVariables.RatioHealthyPriest * 100 ..
            "% life, and " ..
            QUICKHEAL_SPELL_LESSER_HEAL ..
            ", " .. QUICKHEAL_SPELL_HEAL .. " or " .. QUICKHEAL_SPELL_GREATER_HEAL ..
            " will be used otherwise. "
    else
        return QUICKHEAL_SPELL_FLASH_HEAL ..
            " will never be used. " ..
            QUICKHEAL_SPELL_LESSER_HEAL ..
            ", " .. QUICKHEAL_SPELL_HEAL ..
            " or " .. QUICKHEAL_SPELL_GREATER_HEAL ..
            " will always be used in and out of combat. "
    end
end

-- Calculate all Priest-specific modifiers
local function GetPriestModifiers()
    local mods = {}
    mods.bonus = QuickHeal_GetEquipmentBonus()
    local sgRank = QuickHeal_GetTalentRank(2, 12)
    local _, spirit = UnitStat('player', 5)
    mods.sgMod = (spirit or 0) * 5 * sgRank / 100
    local totalBonus = mods.bonus + mods.sgMod
    mods.healMod15 = (1.5 / 3.5) * totalBonus
    mods.healMod20 = (2.0 / 3.5) * totalBonus
    mods.healMod25 = (2.5 / 3.5) * totalBonus
    mods.healMod30 = (3.0 / 3.5) * totalBonus
    mods.hotMod15  = (1.5 / 3.5) * totalBonus
    mods.hotMod35  = (15 / 15)   * totalBonus
    local shRank = QuickHeal_GetTalentRank(2, 16)
    mods.shMod = 1 + 6 * shRank / 100
    local ihRank = QuickHeal_GetTalentRank(2, 11)
    mods.ihMod = 1 - 5 * ihRank / 100
    return mods
end

-- Check for Priest-specific buffs
-- Returns: inCombat, manaLeft, healneed, forceGH
local function CheckPriestBuffs(target, inCombat, manaLeft, healneed)
    local forceGH = false
    if GetUnitField then
        local success, auras = pcall(GetUnitField, "player", "aura")
        if success and auras then
            for i = 1, 31 do
                local spellId = auras[i]
                if spellId and spellId > 0 then
                    if spellId == 18803 then
                        QuickHeal_debug("BUFF: Hand of Edward the Odd [" .. spellId .. "] (out of combat healing forced)")
                        inCombat = false
                    elseif spellId == 24546 then
                        QuickHeal_debug("BUFF: Hazza'rah buff [" .. spellId .. "] (Greater Heal forced)")
                        forceGH = true
                    elseif spellId == 14751 or spellId == 20711 then
                        QuickHeal_debug("BUFF: Free mana [" .. spellId .. "]")
                        manaLeft = QH_GetUnitMaxMana('player')
                        healneed = 1000000
                    end
                end
            end
        end
    end
    if inCombat ~= false and
       QuickHeal_DetectBuff('player', "Spell_Holy_SearingLight") and
       not QuickHeal_DetectBuff('player', "Spell_Holy_SearingLightPriest") then
        QuickHeal_debug("BUFF: Hand of Edward the Odd (texture fallback)")
        inCombat = false
    end
    if not forceGH and QuickHeal_DetectBuff('player', "Spell_Holy_HealingAura") then
        QuickHeal_debug("BUFF: Hazza'rah buff (texture fallback)")
        forceGH = true
    end
    if manaLeft ~= QH_GetUnitMaxMana('player') and
       (QuickHeal_DetectBuff('player', "Spell_Frost_WindWalkOn", 1) or
        QuickHeal_DetectBuff('player', "Spell_Holy_GreaterHeal")) then
        QuickHeal_debug("Inner Focus or Spirit of Redemption active (texture fallback)")
        manaLeft = QH_GetUnitMaxMana('player')
        healneed = 1000000
    end
    return inCombat, manaLeft, healneed, forceGH
end

-- ============================================================
-- DIRECT HEAL SELECTION
-- healType : "heal" | "gh" | "fh"
-- forceMaxRank : true = use the highest possible rank
-- ============================================================
function QuickHeal_Priest_FindHealSpellToUse(target, healType, multiplier, forceMaxRank,
                                              maxhealth, healDeficit, hdb, incombat)
    local SpellID = nil
    local HealSize = 0
    multiplier = multiplier or 1
    healType   = healType or "heal"

    -- Health info
    local healneed, Health, HDB
    if target then
        healneed, Health, HDB = QuickHeal_GetTargetHealth(target, nil, nil, multiplier, nil)
        incombat = UnitAffectingCombat('player') or UnitAffectingCombat(target)
    else
        healneed, Health, HDB = QuickHeal_GetTargetHealth(nil, maxhealth, healDeficit, multiplier, hdb)
        incombat = UnitAffectingCombat('player') or incombat
    end
    if healneed <= 0 then return nil, 0 end

    local mods     = GetPriestModifiers()
    local ManaLeft = QH_GetUnitMana('player')
    local forceGH
    incombat, ManaLeft, healneed, forceGH = CheckPriestBuffs(target, incombat, ManaLeft, healneed)

    -- forceGH (buff externe) : remplace healType par "gh"
    if forceGH then healType = "gh" end

    local SpellIDsLH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_LESSER_HEAL)
    local SpellIDsH  = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HEAL)
    local SpellIDsGH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_GREATER_HEAL)
    local SpellIDsFH = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_FLASH_HEAL)
    local maxRankLH  = table.getn(SpellIDsLH)
    local maxRankH   = table.getn(SpellIDsH)
    local maxRankGH  = table.getn(SpellIDsGH)
    local maxRankFH  = table.getn(SpellIDsFH)

    local downRankFH = QuickHealVariables.DownrankValueFH or 99
    local downRankNH = QuickHealVariables.DownrankValueNH or 99
    local minRankFH  = QuickHealVariables.MinrankValueFH  or 1
    local minRankNH  = QuickHealVariables.MinrankValueNH  or 1

    local k, K = QuickHeal_GetCombatMultipliers(incombat)
    local TargetIsHealthy = Health >= QuickHealVariables.RatioHealthyPriest

    local shMod                        = mods.shMod
    local ihMod                        = mods.ihMod
    local healMod15, healMod20         = mods.healMod15, mods.healMod20
    local healMod25, healMod30         = mods.healMod25, mods.healMod30

    -- Condition commune : ne soigne que si nécessaire (ou TestMode / PrecastAggro)
    local shouldHeal = Health < QuickHealVariables.RatioFull
                    or (QHV.TestMode)
                    or (QHV.PrecastAggro and target and QuickHeal_UnitHasAggro(target))
    if not shouldHeal then return nil, 0 end

    -- ========================= GREATER HEAL =========================
    if healType == "gh" then
        if forceMaxRank then
            -- rank max from mana
            if ManaLeft >= 351 * ihMod and maxRankGH >= 1 and SpellIDsGH[1] then SpellID = SpellIDsGH[1]; HealSize = (838  + healMod30) * shMod end
            if ManaLeft >= 432 * ihMod and maxRankGH >= 2 and SpellIDsGH[2] then SpellID = SpellIDsGH[2]; HealSize = (1066 + healMod30) * shMod end
            if ManaLeft >= 517 * ihMod and maxRankGH >= 3 and SpellIDsGH[3] then SpellID = SpellIDsGH[3]; HealSize = (1328 + healMod30) * shMod end
            if ManaLeft >= 622 * ihMod and maxRankGH >= 4 and SpellIDsGH[4] then SpellID = SpellIDsGH[4]; HealSize = (1632 + healMod30) * shMod end
            if ManaLeft >= 674 * ihMod and maxRankGH >= 5 and SpellIDsGH[5] then SpellID = SpellIDsGH[5]; HealSize = (1768 + healMod30) * shMod end
        else
            -- rank from healneed
            if                                                                    ManaLeft >= 351 * ihMod and maxRankGH >= 1 and downRankNH >= 8  and SpellIDsGH[1] then SpellID = SpellIDsGH[1]; HealSize = (838  + healMod30) * shMod end
            if (healneed > (1066 + healMod30) * shMod * K or 9  <= minRankNH) and ManaLeft >= 432 * ihMod and maxRankGH >= 2 and downRankNH >= 9  and SpellIDsGH[2] then SpellID = SpellIDsGH[2]; HealSize = (1066 + healMod30) * shMod end
            if (healneed > (1328 + healMod30) * shMod * K or 10 <= minRankNH) and ManaLeft >= 517 * ihMod and maxRankGH >= 3 and downRankNH >= 10 and SpellIDsGH[3] then SpellID = SpellIDsGH[3]; HealSize = (1328 + healMod30) * shMod end
            if (healneed > (1632 + healMod30) * shMod * K or 11 <= minRankNH) and ManaLeft >= 622 * ihMod and maxRankGH >= 4 and downRankNH >= 11 and SpellIDsGH[4] then SpellID = SpellIDsGH[4]; HealSize = (1632 + healMod30) * shMod end
            if (healneed > (1768 + healMod30) * shMod * K or 12 <= minRankNH) and ManaLeft >= 674 * ihMod and maxRankGH >= 5 and downRankNH >= 12 and SpellIDsGH[5] then SpellID = SpellIDsGH[5]; HealSize = (1768 + healMod30) * shMod end
        end

    -- ========================= FLASH HEAL =========================
    elseif healType == "fh" then
        if forceMaxRank then
            if ManaLeft >= 125 and maxRankFH >= 1 and SpellIDsFH[1] then SpellID = SpellIDsFH[1]; HealSize = (225 + healMod15) * shMod end
            if ManaLeft >= 155 and maxRankFH >= 2 and SpellIDsFH[2] then SpellID = SpellIDsFH[2]; HealSize = (297 + healMod15) * shMod end
            if ManaLeft >= 185 and maxRankFH >= 3 and SpellIDsFH[3] then SpellID = SpellIDsFH[3]; HealSize = (319 + healMod15) * shMod end
            if ManaLeft >= 215 and maxRankFH >= 4 and SpellIDsFH[4] then SpellID = SpellIDsFH[4]; HealSize = (387 + healMod15) * shMod end
            if ManaLeft >= 265 and maxRankFH >= 5 and SpellIDsFH[5] then SpellID = SpellIDsFH[5]; HealSize = (498 + healMod15) * shMod end
            if ManaLeft >= 315 and maxRankFH >= 6 and SpellIDsFH[6] then SpellID = SpellIDsFH[6]; HealSize = (618 + healMod15) * shMod end
            if ManaLeft >= 380 and maxRankFH >= 7 and SpellIDsFH[7] then SpellID = SpellIDsFH[7]; HealSize = (769 + healMod15) * shMod end
        else
            -- rank from healneed
            if                                                                    ManaLeft >= 125 and maxRankFH >= 1 and downRankFH >= 1 and SpellIDsFH[1] then SpellID = SpellIDsFH[1]; HealSize = (225 + healMod15) * shMod end
            if (healneed > (297 + healMod15) * shMod * k or 2 <= minRankFH) and  ManaLeft >= 155 and maxRankFH >= 2 and downRankFH >= 2 and SpellIDsFH[2] then SpellID = SpellIDsFH[2]; HealSize = (297 + healMod15) * shMod end
            if (healneed > (319 + healMod15) * shMod * k or 3 <= minRankFH) and  ManaLeft >= 185 and maxRankFH >= 3 and downRankFH >= 3 and SpellIDsFH[3] then SpellID = SpellIDsFH[3]; HealSize = (319 + healMod15) * shMod end
            if (healneed > (387 + healMod15) * shMod * k or 4 <= minRankFH) and  ManaLeft >= 215 and maxRankFH >= 4 and downRankFH >= 4 and SpellIDsFH[4] then SpellID = SpellIDsFH[4]; HealSize = (387 + healMod15) * shMod end
            if (healneed > (498 + healMod15) * shMod * k or 5 <= minRankFH) and  ManaLeft >= 265 and maxRankFH >= 5 and downRankFH >= 5 and SpellIDsFH[5] then SpellID = SpellIDsFH[5]; HealSize = (498 + healMod15) * shMod end
            if (healneed > (618 + healMod15) * shMod * k or 6 <= minRankFH) and  ManaLeft >= 315 and maxRankFH >= 6 and downRankFH >= 6 and SpellIDsFH[6] then SpellID = SpellIDsFH[6]; HealSize = (618 + healMod15) * shMod end
            if (healneed > (769 + healMod15) * shMod * k or 7 <= minRankFH) and  ManaLeft >= 380 and maxRankFH >= 7 and downRankFH >= 7 and SpellIDsFH[7] then SpellID = SpellIDsFH[7]; HealSize = (769 + healMod15) * shMod end
        end

    -- ========================= HEAL (palette complète) =========================
    else -- healType == "heal"
        if forceMaxRank and (not incombat or TargetIsHealthy or maxRankFH < 1) then
            -- Every possible heal, from mana
            if                             maxRankLH >= 1 and SpellIDsLH[1]  then SpellID = SpellIDsLH[1]; HealSize = (53  + healMod15 * PF[1])  * shMod end
            if ManaLeft >= 45  * ihMod and maxRankLH >= 2 and SpellIDsLH[2] then SpellID = SpellIDsLH[2]; HealSize = (84   + healMod20 * PF[4])  * shMod end
            if ManaLeft >= 75  * ihMod and maxRankLH >= 3 and SpellIDsLH[3] then SpellID = SpellIDsLH[3]; HealSize = (154  + healMod25 * PF[10]) * shMod end
            if ManaLeft >= 155 * ihMod and maxRankH  >= 1 and SpellIDsH[1]  then SpellID = SpellIDsH[1];  HealSize = (330  + healMod30 * PF[18]) * shMod end
            if ManaLeft >= 205 * ihMod and maxRankH  >= 2 and SpellIDsH[2]  then SpellID = SpellIDsH[2];  HealSize = (476 + healMod30) * shMod           end
            if ManaLeft >= 255 * ihMod and maxRankH  >= 3 and SpellIDsH[3]  then SpellID = SpellIDsH[3];  HealSize = (624 + healMod30) * shMod           end
            if ManaLeft >= 305 * ihMod and maxRankH  >= 4 and SpellIDsH[4]  then SpellID = SpellIDsH[4];  HealSize = (667 + healMod30) * shMod           end
            if ManaLeft >= 370 * ihMod and maxRankGH >= 1 and SpellIDsGH[1] then SpellID = SpellIDsGH[1]; HealSize = (838 + healMod30) * shMod           end
            if ManaLeft >= 455 * ihMod and maxRankGH >= 2 and SpellIDsGH[2] then SpellID = SpellIDsGH[2]; HealSize = (1066+ healMod30) * shMod           end
            if ManaLeft >= 545 * ihMod and maxRankGH >= 3 and SpellIDsGH[3] then SpellID = SpellIDsGH[3]; HealSize = (1328+ healMod30) * shMod           end
            if ManaLeft >= 655 * ihMod and maxRankGH >= 4 and SpellIDsGH[4] then SpellID = SpellIDsGH[4]; HealSize = (1632+ healMod30) * shMod           end
            if ManaLeft >= 710 * ihMod and maxRankGH >= 5 and SpellIDsGH[5] then SpellID = SpellIDsGH[5]; HealSize = (1768+ healMod30) * shMod           end

        elseif forceMaxRank then     -- Flash Heal (en combat, cible pas healthy)
            if ManaLeft >= 125 and maxRankFH >= 1 and SpellIDsFH[1] then SpellID = SpellIDsFH[1]; HealSize = (225 + healMod15) * shMod end
            if ManaLeft >= 155 and maxRankFH >= 2 and SpellIDsFH[2] then SpellID = SpellIDsFH[2]; HealSize = (297 + healMod15) * shMod end
            if ManaLeft >= 185 and maxRankFH >= 3 and SpellIDsFH[3] then SpellID = SpellIDsFH[3]; HealSize = (319 + healMod15) * shMod end
            if ManaLeft >= 215 and maxRankFH >= 4 and SpellIDsFH[4] then SpellID = SpellIDsFH[4]; HealSize = (387 + healMod15) * shMod end
            if ManaLeft >= 265 and maxRankFH >= 5 and SpellIDsFH[5] then SpellID = SpellIDsFH[5]; HealSize = (498 + healMod15) * shMod end
            if ManaLeft >= 315 and maxRankFH >= 6 and SpellIDsFH[6] then SpellID = SpellIDsFH[6]; HealSize = (618 + healMod15) * shMod end
            if ManaLeft >= 380 and maxRankFH >= 7 and SpellIDsFH[7] then SpellID = SpellIDsFH[7]; HealSize = (769 + healMod15) * shMod end
        else
            -- Palette normale : FH en combat si cible pas healthy, LH/H/GH sinon
            if not incombat or TargetIsHealthy or maxRankFH < 1 then
                -- Soins lents (hors combat ou cible "healthy")
                if                                                                                                       maxRankLH >= 1 and downRankNH >= 1 and SpellIDsLH[1]  then SpellID = SpellIDsLH[1]; HealSize = (53 + healMod15 * PF[1]) * shMod  end
                if (healneed > (84  + healMod20 * PF[4]) * shMod  * k or 2 <= minRankNH) and ManaLeft >= 45  * ihMod and maxRankLH >= 2 and downRankNH >= 2 and SpellIDsLH[2] then SpellID = SpellIDsLH[2]; HealSize = (84  + healMod20 * PF[4]) * shMod  end
                if (healneed > (154 + healMod25 * PF[10]) * shMod * K or 3 <= minRankNH) and ManaLeft >= 75  * ihMod and maxRankLH >= 3 and downRankNH >= 3 and SpellIDsLH[3] then SpellID = SpellIDsLH[3]; HealSize = (154 + healMod25 * PF[10]) * shMod end
                if (healneed > (330 + healMod30 * PF[18]) * shMod * K or 4 <= minRankNH) and ManaLeft >= 155 * ihMod and maxRankH  >= 1 and downRankNH >= 4 and SpellIDsH[1]  then SpellID = SpellIDsH[1];  HealSize = (330 + healMod30 * PF[18]) * shMod end
                if (healneed > (476 + healMod30) * shMod          * K or 5 <= minRankNH) and ManaLeft >= 205 * ihMod and maxRankH  >= 2 and downRankNH >= 5 and SpellIDsH[2]  then SpellID = SpellIDsH[2];  HealSize = (476 + healMod30) * shMod          end
                if (healneed > (624 + healMod30) * shMod          * K or 6 <= minRankNH) and ManaLeft >= 255 * ihMod and maxRankH  >= 3 and downRankNH >= 6 and SpellIDsH[3]  then SpellID = SpellIDsH[3];  HealSize = (624 + healMod30) * shMod          end
                if (healneed > (667 + healMod30) * shMod          * K or 7 <= minRankNH) and ManaLeft >= 305 * ihMod and maxRankH  >= 4 and downRankNH >= 7 and SpellIDsH[4]  then SpellID = SpellIDsH[4];  HealSize = (667 + healMod30) * shMod          end
                if (healneed > (838  + healMod30) * shMod         * K or 8  <= minRankNH) and ManaLeft >= 351 * ihMod and maxRankGH >= 1 and downRankNH >= 8  and SpellIDsGH[1] then SpellID = SpellIDsGH[1]; HealSize = (838 + healMod30)  * shMod end
                if (healneed > (1066 + healMod30) * shMod         * K or 9  <= minRankNH) and ManaLeft >= 432 * ihMod and maxRankGH >= 2 and downRankNH >= 9  and SpellIDsGH[2] then SpellID = SpellIDsGH[2]; HealSize = (1066 + healMod30) * shMod end
                if (healneed > (1328 + healMod30) * shMod         * K or 10 <= minRankNH) and ManaLeft >= 517 * ihMod and maxRankGH >= 3 and downRankNH >= 10 and SpellIDsGH[3] then SpellID = SpellIDsGH[3]; HealSize = (1328 + healMod30) * shMod end
                if (healneed > (1632 + healMod30) * shMod         * K or 11 <= minRankNH) and ManaLeft >= 622 * ihMod and maxRankGH >= 4 and downRankNH >= 11 and SpellIDsGH[4] then SpellID = SpellIDsGH[4]; HealSize = (1632 + healMod30) * shMod end
                if (healneed > (1768 + healMod30) * shMod         * K or 12 <= minRankNH) and ManaLeft >= 674 * ihMod and maxRankGH >= 5 and downRankNH >= 12 and SpellIDsGH[5] then SpellID = SpellIDsGH[5]; HealSize = (1768 + healMod30) * shMod end
            else
                -- Flash Heal (en combat, cible pas healthy)
                if                                                                   ManaLeft >= 125 and maxRankFH >= 1 and downRankFH >= 1 and SpellIDsFH[1] then SpellID = SpellIDsFH[1]; HealSize = (225 + healMod15) * shMod end
                if (healneed > (297 + healMod15) * shMod * k or 2 <= minRankFH) and ManaLeft >= 155 and maxRankFH >= 2 and downRankFH >= 2 and SpellIDsFH[2] then SpellID = SpellIDsFH[2]; HealSize = (297 + healMod15) * shMod end
                if (healneed > (319 + healMod15) * shMod * k or 3 <= minRankFH) and ManaLeft >= 185 and maxRankFH >= 3 and downRankFH >= 3 and SpellIDsFH[3] then SpellID = SpellIDsFH[3]; HealSize = (319 + healMod15) * shMod end
                if (healneed > (387 + healMod15) * shMod * k or 4 <= minRankFH) and ManaLeft >= 215 and maxRankFH >= 4 and downRankFH >= 4 and SpellIDsFH[4] then SpellID = SpellIDsFH[4]; HealSize = (387 + healMod15) * shMod end
                if (healneed > (498 + healMod15) * shMod * k or 5 <= minRankFH) and ManaLeft >= 265 and maxRankFH >= 5 and downRankFH >= 5 and SpellIDsFH[5] then SpellID = SpellIDsFH[5]; HealSize = (498 + healMod15) * shMod end
                if (healneed > (618 + healMod15) * shMod * k or 6 <= minRankFH) and ManaLeft >= 315 and maxRankFH >= 6 and downRankFH >= 6 and SpellIDsFH[6] then SpellID = SpellIDsFH[6]; HealSize = (618 + healMod15) * shMod  end
                if (healneed > (769 + healMod15) * shMod * k or 7 <= minRankFH) and ManaLeft >= 380 and maxRankFH >= 7 and downRankFH >= 7 and SpellIDsFH[7] then SpellID = SpellIDsFH[7]; HealSize = (769 + healMod15) * shMod end
            end
        end
    end

    return SpellID, HealSize * HDB
end

-- NoTarget wrapper
function QuickHeal_Priest_FindHealSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxRank,
                                                      forceMaxHPS, hdb, incombat)
    return QuickHeal_Priest_FindHealSpellToUse(nil, healType, multiplier, forceMaxRank,
                                                maxhealth, healDeficit, hdb, incombat)
end

-- ============================================================
-- HOT SELECTION (Renew)
-- forceMaxRank : true = max rank from mana
-- forceSpam    : true = ignore healneed (cible full OK)
-- ============================================================
function QuickHeal_Priest_FindHoTSpellToUse(target, healType, forceMaxRank,
                                             maxhealth, healDeficit, hdb, incombat)
    local SpellID = nil
    local HealSize = 0

    local healneed, Health, HDB
    if target then
        healneed, Health, HDB = QuickHeal_GetTargetHealth(target, nil, nil, 1, nil)
        incombat = UnitAffectingCombat('player') or UnitAffectingCombat(target)
    else
        healneed, Health, HDB = QuickHeal_GetTargetHealth(nil, maxhealth, healDeficit, 1, hdb)
        incombat = UnitAffectingCombat('player') or incombat
    end

    local mods     = GetPriestModifiers()
    local ManaLeft = QH_GetUnitMana('player')
    -- CheckPriestBuffs retourne 4 valeurs ; on ignore forceGH (sans objet pour un HoT)
    incombat, ManaLeft, healneed = CheckPriestBuffs(target, incombat, ManaLeft, healneed)

    local SpellIDsR = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_RENEW)
    local maxRankR  = table.getn(SpellIDsR)
    local k, K     = QuickHeal_GetCombatMultipliers(incombat)
    local shMod     = mods.shMod
    local hotMod35  = mods.hotMod35

    if healType == "hot" then
        if forceMaxRank then
            -- Rang max permis par le mana (spam ou hot max)
            if maxRankR >= 1  and SpellIDsR[1]  then SpellID = SpellIDsR[1];  HealSize = (45 + hotMod35) * shMod end
            if maxRankR >= 2  and ManaLeft >= 65  and SpellIDsR[2]  then SpellID = SpellIDsR[2];  HealSize = (100 + hotMod35) * shMod end
            if maxRankR >= 3  and ManaLeft >= 105 and SpellIDsR[3]  then SpellID = SpellIDsR[3];  HealSize = (175 + hotMod35) * shMod end
            if maxRankR >= 4  and ManaLeft >= 140 and SpellIDsR[4]  then SpellID = SpellIDsR[4];  HealSize = (245 + hotMod35) * shMod end
            if maxRankR >= 5  and ManaLeft >= 170 and SpellIDsR[5]  then SpellID = SpellIDsR[5];  HealSize = (270 + hotMod35) * shMod end
            if maxRankR >= 6  and ManaLeft >= 205 and SpellIDsR[6]  then SpellID = SpellIDsR[6];  HealSize = (340 + hotMod35) * shMod end
            if maxRankR >= 7  and ManaLeft >= 250 and SpellIDsR[7]  then SpellID = SpellIDsR[7];  HealSize = (435 + hotMod35) * shMod end
            if maxRankR >= 8  and ManaLeft >= 305 and SpellIDsR[8]  then SpellID = SpellIDsR[8];  HealSize = (555 + hotMod35) * shMod end
            if maxRankR >= 9  and ManaLeft >= 365 and SpellIDsR[9]  then SpellID = SpellIDsR[9];  HealSize = (690 + hotMod35) * shMod end
            if maxRankR >= 10 and ManaLeft >= 410 and SpellIDsR[10] then SpellID = SpellIDsR[10]; HealSize = (825 + hotMod35) * shMod end
        else
            -- Rang adapté au healneed
            if maxRankR >= 1  and SpellIDsR[1]  then SpellID = SpellIDsR[1];  HealSize = (45 + hotMod35) * shMod end
            if healneed > (100 + hotMod35) * shMod * k and ManaLeft >= 65  and maxRankR >= 2  and SpellIDsR[2]  then SpellID = SpellIDsR[2];  HealSize = (100 + hotMod35) * shMod end
            if healneed > (175 + hotMod35) * shMod * k and ManaLeft >= 105 and maxRankR >= 3  and SpellIDsR[3]  then SpellID = SpellIDsR[3];  HealSize = (175 + hotMod35) * shMod  end
            if healneed > (245 + hotMod35) * shMod * k and ManaLeft >= 140 and maxRankR >= 4  and SpellIDsR[4]  then SpellID = SpellIDsR[4];  HealSize = (245 + hotMod35) * shMod end
            if healneed > (270 + hotMod35) * shMod * k and ManaLeft >= 170 and maxRankR >= 5  and SpellIDsR[5]  then SpellID = SpellIDsR[5];  HealSize = (270 + hotMod35) * shMod end
            if healneed > (340 + hotMod35) * shMod * k and ManaLeft >= 205 and maxRankR >= 6  and SpellIDsR[6]  then SpellID = SpellIDsR[6];  HealSize = (340 + hotMod35) * shMod end
            if healneed > (435 + hotMod35) * shMod * k and ManaLeft >= 250 and maxRankR >= 7  and SpellIDsR[7]  then SpellID = SpellIDsR[7];  HealSize = (435 + hotMod35) * shMod end
            if healneed > (555 + hotMod35) * shMod * k and ManaLeft >= 305 and maxRankR >= 8  and SpellIDsR[8]  then SpellID = SpellIDsR[8];  HealSize = (555 + hotMod35) * shMod end
            if healneed > (690 + hotMod35) * shMod * k and ManaLeft >= 365 and maxRankR >= 9  and SpellIDsR[9]  then SpellID = SpellIDsR[9];  HealSize = (690 + hotMod35) * shMod end
            if healneed > (825 + hotMod35) * shMod * k and ManaLeft >= 410 and maxRankR >= 10 and SpellIDsR[10] then SpellID = SpellIDsR[10]; HealSize = (825 + hotMod35) * shMod  end
        end
    elseif healType == "channel" then
        return QuickHeal_Priest_FindHealSpellToUse(target, "heal", 1, false, maxhealth, healDeficit, hdb, incombat)
    end

    return SpellID, HealSize * HDB
end

-- Wrapper no target
function QuickHeal_Priest_FindHoTSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxHPS,
                                                     forceMaxRank, hdb, incombat)
    return QuickHeal_Priest_FindHoTSpellToUse(nil, healType, forceMaxRank,
                                               maxhealth, healDeficit, hdb, incombat)
end

-- Utility : spell info by healneed
function QuickHealSpellID(healneed)
    local SpellID, HealSize = QuickHeal_Priest_FindHealSpellToUse(nil, "channel", 1, false, 10000, healneed, 1, false)
    if not SpellID then return nil, nil end
    local SpellName, SpellRank = GetSpellName(SpellID, BOOKTYPE_SPELL)
    if SpellRank == "" then SpellRank = nil end
    local rankNum = SpellRank and string.gsub(SpellRank, "%a+", "") or "1"
    return SpellName, rankNum
end

-- ============================================================
-- COMMAND HANDLER
-- ============================================================
function QuickHeal_Command_Priest(msg)
    msg = string.lower(msg or "")

    -- Tokenize proprement
    local args = {}
    for w in string.gfind(msg, "%S+") do
        table.insert(args, w)
    end
    local a1, a2, a3 = args[1], args[2], args[3]

    local function isValidTarget(t)
        return t == "player" or t == "target" or t == "targettarget"
            or t == "party" or t == "subgroup" or t == "mt" or t == "nonmt"
    end

    -- ======= 3 tokens =======
    if a1 and a2 and a3 then
        if isValidTarget(a1) then
            if a2 == "heal" and a3 == "max" then QuickHeal(a1, nil, {healType="heal"}, true); return end
            if a2 == "gh"   and a3 == "max" then QuickHeal(a1, nil, {healType="gh"},   true); return end
            if a2 == "fh"   and a3 == "max" then QuickHeal(a1, nil, {healType="fh"},   true); return end
            if a2 == "hot"  and a3 == "max" then QuickHOT(a1, nil, nil, true, false);          return end
            if a2 == "hot"  and a3 == "spam" then QuickHOT(a1, nil, nil, true, true);           return end
        end
    end

    -- ======= 2 tokens =======
    if a1 and a2 then
        -- Debug
        if a1 == "debug" then
            if a2 == "on"  then QHV.DebugMode = true;  writeLine("QuickHeal: Debug mode enabled", 0, 1, 0); return end
            if a2 == "off" then QHV.DebugMode = false; writeLine("QuickHeal: Debug mode disabled", 1, 1, 0); return end
        end
        -- Test mode
        if a1 == "test" then
            if a2 == "on"  then QHV.TestMode = true;  writeLine("QuickHeal: Test mode enabled", 0, 1, 0); return end
            if a2 == "off" then QHV.TestMode = false; writeLine("QuickHeal: Test mode disabled", 1, 1, 0); return end
        end
        -- Commandes globales (pas de target)
        if a1 == "heal" and a2 == "max"  then QuickHeal(nil, nil, {healType="heal"}, true);   return end
        if a1 == "gh"   and a2 == "max"  then QuickHeal(nil, nil, {healType="gh"},   true);   return end
        if a1 == "fh"   and a2 == "max"  then QuickHeal(nil, nil, {healType="fh"},   true);   return end
        if a1 == "hot"  and a2 == "max"  then QuickHOT(nil, nil, nil, true, false);            return end
        if a1 == "hot"  and a2 == "spam" then QuickHOT(nil, nil, nil, true, true);             return end
        -- Target + type
        if isValidTarget(a1) then
            if a2 == "heal" then QuickHeal(a1, nil, {healType="heal"}, false); return end
            if a2 == "gh"   then QuickHeal(a1, nil, {healType="gh"},   false); return end
            if a2 == "fh"   then QuickHeal(a1, nil, {healType="fh"},   false); return end
            if a2 == "hot"  then QuickHOT(a1, nil, nil, false, false);          return end
        end
    end

    -- ======= 1 token =======
    if a1 then
        if a1 == "cfg"                                  then QuickHeal_ToggleConfigurationPanel(); return end
        if a1 == "toggle"                               then QuickHeal_Toggle_Healthy_Threshold(); return end
        if a1 == "downrank" or a1 == "dr"
           or a1 == "minrank" or a1 == "ranks"         then ToggleDownrankWindow(); return end
        if a1 == "tanklist" or a1 == "tl"              then QH_ShowHideMTListUI(); return end
        if a1 == "reset" then
            QuickHeal_SetDefaultParameters()
            writeLine(QuickHealData.name .. " reset to default configuration", 0, 0, 1)
            QuickHeal_ToggleConfigurationPanel(); QuickHeal_ToggleConfigurationPanel()
            return
        end
        if a1 == "dll"  then QuickHeal_ReportDLLStatus(); return end
        if a1 == "heal" then QuickHeal(nil, nil, {healType="heal"}, false); return end
        if a1 == "gh"   then QuickHeal(nil, nil, {healType="gh"},   false); return end
        if a1 == "fh"   then QuickHeal(nil, nil, {healType="fh"},   false); return end
        if a1 == "hot"  then QuickHOT(); return end
        if isValidTarget(a1) then QuickHeal(a1); return end
    end

    -- ======= token vide = heal par défaut =======
    if not a1 then
        QuickHeal(nil)
        return
    end

    -- ======= Help =======
    writeLine("== QUICKHEAL PRIEST ==")
    writeLine(" ")
    writeLine("Usage: /qh [target] [type] [mode]")
    writeLine(" ")
    writeLine("Targets: player | target | targettarget | party | mt | nonmt | subgroup")
    writeLine(" ")
    writeLine("Types:")
    writeLine("  heal   - Optimal LH,H,GH or FH from slider logic")
    writeLine("  gh     - Optimal GH only")
    writeLine("  fh     - Optimal FH only")
    writeLine("  hot    - Optimal Renew")
    writeLine(" ")
    writeLine("Modes:")
    writeLine("  max    - Max rank")
    writeLine("  spam   - Used for hot, Ignore HP, spam Renew max")
    writeLine(" ")
    writeLine("Examples:")
    writeLine("  /qh fh                 - Flash Heal only")
    writeLine("  /qh fh max             - Flash Heal max rank only")
    writeLine("  /qh gh                 - Greater Heal only")
    writeLine("  /qh gh max             - Greater Heal max rank only")
    writeLine("  /qh hot max            - Renew max rank")
    writeLine("  /qh hot spam           - Renew max rank (even full target)")
    writeLine("  /qh mt gh max          - GH max rank on MT")
    writeLine(" ")
    writeLine("Options:")
    writeLine("  /qh cfg | toggle | downrank | tanklist | reset | dll")
    writeLine("  /qh test on|off | debug on|off")
end
