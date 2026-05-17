-- QuickHeal Druid Module (Refactored) 
-- Consolidated spell selection with shared helper functions

local function writeLine(s, r, g, b)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(s, r or 1, g or 1, b or 0.5)
    end
end

-- Penalty Factors for low-level spells
local PF = {
    [1] = 0.2875,
    [8] = 0.55,
    [14] = 0.775,
    RG1 = 0.7 * 1.042, -- Rank 1 of RG (compensates for 0.50 factor that should be 0.48)
    RG2 = 0.925,
}

function QuickHeal_Druid_GetRatioHealthyExplanation()
    local RatioHealthy = QuickHeal_GetRatioHealthy()
    local RatioFull = QuickHealVariables["RatioFull"]

    if RatioHealthy >= RatioFull then
        return QUICKHEAL_SPELL_REGROWTH ..
            " will always be used in combat, and " .. QUICKHEAL_SPELL_HEALING_TOUCH .. " will be used out of combat. "
    else
        if RatioHealthy > 0 then
            return QUICKHEAL_SPELL_REGROWTH ..
                " will be used in combat if the target has less than " ..
                RatioHealthy * 100 .. "% life, and " .. QUICKHEAL_SPELL_HEALING_TOUCH .. " will be used otherwise. "
        else
            return QUICKHEAL_SPELL_REGROWTH ..
                " will never be used. " .. QUICKHEAL_SPELL_HEALING_TOUCH .. " will always be used in and out of combat. "
        end
    end
end

-- Calculate all Druid-specific modifiers
local function GetDruidModifiers()
    local mods = {}

    -- Equipment healing bonus (cached)
    mods.bonus = QuickHeal_GetEquipmentBonus()

    -- Calculate healing modifiers by cast time
    mods.healMod15 = (1.5 / 3.5) * mods.bonus
    mods.healMod20 = (2.0 / 3.5) * mods.bonus
    mods.healMod25 = (2.5 / 3.5) * mods.bonus
    mods.healMod30 = (3.0 / 3.5) * mods.bonus
    mods.healMod35 = mods.bonus
    mods.healModRG = (2.0 / 3.5) * mods.bonus * 0.5 -- DirectHeal/(DirectHeal+HoT) factor

    -- Gift of Nature - Increases healing by 2% per rank for HT, RG and RJ
    local gonRank = QuickHeal_GetTalentRank(3, 9)
    mods.gonMod = 1 + 2 * gonRank / 100

    -- Tranquil Spirit - Decreases mana usage by 2% per rank on HT and RG
    local tsRank = QuickHeal_GetTalentRank(3, 10)
    mods.tsMod = 1 - 2 * tsRank / 100

    -- Moonglow - Decrease mana usage by 3% per rank
    local mgRank = QuickHeal_GetTalentRank(1, 13)
    mods.mgMod = 1 - 3 * mgRank / 100

    -- Improved Regrowth - increases Regrowth effect by 5% per rank (crit is 50% bonus)
    local iregRank = QuickHeal_GetTalentRank(3, 14)
    mods.iregMod = 1 + 5 * iregRank / 100

    -- Genesis - Increases Rejuvenation effects by 5% per rank
    local genRank = QuickHeal_GetTalentRank(3, 7)
    mods.genMod = 1 + 5 * genRank / 100

    return mods
end

-- Check for Druid-specific buffs that affect healing
-- Signature de retour : incombat, manaLeft, healneed, buffedHT, forceMax
local function CheckDruidBuffs(incombat, manaLeft, healneed, mods)
    local buffedHT = false
    local forceMax = false  

    if GetUnitField then
        local success, auras = pcall(GetUnitField, "player", "aura")
        if success and auras then
            for i = 1, 31 do
                local spellId = auras[i]
                if spellId and spellId > 0 then
                    if spellId == 16870 then -- Clearcasting
                        QuickHeal_debug("BUFF: Clearcasting [" .. spellId .. "] (forceMaxHPS activé)")
                        forceMax = true                          -- NOUVEAU
                        -- plus de manaLeft/healneed bidouillés ici
                    elseif spellId == 17116 then
                        QuickHeal_debug("BUFF: Nature's Swiftness")
                        incombat = false
                    elseif spellId == 18803 then
                        QuickHeal_debug("BUFF: Hand of Edward the Odd")
                        incombat = false
                    elseif spellId == 24542 then
                        QuickHeal_debug("BUFF: Wushoolay")
                        buffedHT = true
                    end
                end
            end
        end
    end

    -- Fallback texture : Clearcasting
    if not forceMax and QuickHeal_DetectBuff('player', "Spell_Shadow_ManaBurn", 1) then
        QuickHeal_debug("BUFF: Clearcasting (texture fallback, forceMaxHPS activé)")
        forceMax = true
    end

    -- Fallbacks texture restants (inchangés)
    if incombat and QuickHeal_DetectBuff('player', "Spell_Nature_RavenForm") then
        QuickHeal_debug("BUFF: Nature's Swiftness (texture fallback)")
        incombat = false
    end
    if incombat and QuickHeal_DetectBuff('player', "Spell_Holy_SearingLight") and
       not QuickHeal_DetectBuff('player', "Spell_Holy_SearingLightPriest") then
        QuickHeal_debug("BUFF: Hand of Edward the Odd (texture fallback)")
        incombat = false
    end
    if not buffedHT and QuickHeal_DetectBuff('player', "Spell_Nature_Regenerate") then
        QuickHeal_debug("BUFF: Wushoolay (texture fallback)")
        buffedHT = true
    end

    return incombat, manaLeft, healneed, buffedHT, forceMax  -- NOUVEAU : +forceMax
end

function QuickHeal_Druid_FindHealSpellToUse(target, healType, multiplier, forceMaxHPS, maxhealth, healDeficit, hdb, incombat)

    local SpellID = nil
    local HealSize = 0
    multiplier = multiplier or 1

    local RatioFull = QuickHealVariables["RatioFull"]
    local RatioHealthy = QuickHeal_GetRatioHealthy()
    local debug = QuickHeal_debug

    -- =========================
    -- HEALTH CALCULATION
    -- =========================
    local healneed, Health, HDB

    if target then
        if QuickHeal_UnitHasHealthInfo(target) then
            healneed = QH_GetUnitMaxHealth(target) - QH_GetUnitHealth(target)
            Health = QH_GetUnitHealth(target) / QH_GetUnitMaxHealth(target)
        else
            healneed = QuickHeal_EstimateUnitHealNeed(target, true)
            Health = QH_GetUnitHealth(target) / 100
        end

        HDB = QuickHeal_GetHealModifier(target)
        incombat = UnitAffectingCombat('player') or UnitAffectingCombat(target)
    else
        if not maxhealth or maxhealth <= 0 then return nil, 0 end
        healneed = healDeficit * multiplier
        Health = healDeficit / maxhealth
        HDB = hdb or 1
        incombat = UnitAffectingCombat('player') or incombat
    end

    healneed = healneed / HDB

    -- =========================
    -- MANA / BUFFS
    -- =========================
    local mods = GetDruidModifiers()
    local ManaLeft = QH_GetUnitMana('player')

    local ccForceMax
	incombat, ManaLeft, healneed, buffedHT, ccForceMax = CheckDruidBuffs(incombat, ManaLeft, healneed, mods)
	forceMaxHPS = forceMaxHPS or ccForceMax  -- Clearcasting active forceMaxHPS

    -- Nature's Grace tweak
    if not target and QuickHeal_DetectBuff('player', "Spell_Nature_NaturesBlessing") and
        healneed < ((219 + mods.healMod25 * PF[14]) * mods.gonMod * 2.8) and
        not QuickHeal_DetectBuff('player', "Spell_Nature_Regenerate") then
        ManaLeft = 110 * mods.tsMod * mods.mgMod
    end

    -- =========================
    -- SPELL TABLES
    -- =========================
    local SpellIDsHT = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HEALING_TOUCH)
    local SpellIDsRG = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_REGROWTH)

    local maxRankHT = table.getn(SpellIDsHT)
    local maxRankRG = table.getn(SpellIDsRG)

    local debugStr = string.format("HT %d / RG %d", maxRankHT, maxRankRG)
    debug(debugStr)

    -- =========================
    -- SETTINGS
    -- =========================
    local downRankFH = QuickHealVariables.DownrankValueFH or 0
    local downRankNH = QuickHealVariables.DownrankValueNH or 0
    local minRankFH = QuickHealVariables.MinrankValueFH or 1
    local minRankNH = QuickHealVariables.MinrankValueNH or 1

    local k, K = QuickHeal_GetCombatMultipliers(incombat)

    local TargetIsHealthy = Health > RatioHealthy

    local gonMod = mods.gonMod
    local tsMod = mods.tsMod
    local mgMod = mods.mgMod
    local iregMod = mods.iregMod

    local healMod15 = mods.healMod15
    local healMod20 = mods.healMod20
    local healMod25 = mods.healMod25
    local healMod30 = mods.healMod30
    local healMod35 = mods.healMod35
    local healModRG = mods.healModRG

    -- =========================
    -- HEAL TYPE RESOLUTION
    -- =========================

	local forceHT = (healType == "ht") or buffedHT
	local forceRG = (healType == "rg")
	
	local useHT
	
	if forceHT then
	    useHT = true
	
	elseif forceRG then
	    useHT = false
	
	else
	    if not incombat then
	        useHT = true
	    else
	        useHT = (TargetIsHealthy or maxRankRG < 1 or not target)
	    end
	end

    -- =========================
    -- HEALING TOUCH
    -- =========================
    if useHT then

        if Health < RatioFull or QHV.TestMode or (QHV.PrecastAggro and QuickHeal_UnitHasAggro(target)) then

            -- =========================
            -- HT MAX MODE
            -- =========================
            if forceMaxHPS and maxRankHT > 0 then
                debug("HT max mode")

                local manaHT = {
                    [1]=25,[2]=55,[3]=110,[4]=185,[5]=270,
                    [6]=335,[7]=405,[8]=495,[9]=600,[10]=720,[11]=800
                }

                local healHT = {
                    [1]=44,[2]=100,[3]=219,[4]=404,[5]=633,
                    [6]=818,[7]=1028,[8]=1313,[9]=1656,[10]=2060,[11]=2472
                }

                for i = maxRankHT, 1, -1 do
                    if SpellIDsHT[i] and ManaLeft >= manaHT[i] * tsMod * mgMod then
                        SpellID = SpellIDsHT[i]
                        HealSize = healHT[i] * gonMod
                        return SpellID, HealSize * HDB
                    end
                end
            end

            -- =========================
            -- HT NORMAL MODE
            -- =========================
            SpellID = SpellIDsHT[1]
            HealSize = (44 + healMod15 * PF[1]) * gonMod

            if (healneed > (100+ healMod20 * PF[8]) * gonMod * k or 2 <= minRankNH)
                and ManaLeft >= 55 * tsMod * mgMod and maxRankHT >= 2 and downRankNH >= 2 and SpellIDsHT[2] then
                SpellID = SpellIDsHT[2]
                HealSize = (100 + healMod20 * PF[8]) * gonMod
            end

            if (healneed > (219 + healMod25 * PF[14]) * gonMod * K or 3 <= minRankNH)
                and ManaLeft >= 110 * tsMod * mgMod and maxRankHT >= 3 and downRankNH >= 3 and SpellIDsHT[3] then
                SpellID = SpellIDsHT[3]
                HealSize = (219 + healMod25 * PF[14]) * gonMod
            end
	        if (healneed > (404 + healMod30) * gonMod * K or 4 <= minRankNH) 
                and ManaLeft >= 185 * tsMod * mgMod and maxRankHT >= 4 and downRankNH >= 4 and SpellIDsHT[4] then
                SpellID = SpellIDsHT[4]; HealSize = (404 + healMod30) * gonMod
            end
            if (healneed > (633 + healMod35) * gonMod * K or 5 <= minRankNH) 
                and ManaLeft >= 270 * tsMod * mgMod and maxRankHT >= 5 and downRankNH >= 5 and SpellIDsHT[5] then
                SpellID = SpellIDsHT[5]; HealSize = (633 + healMod35) * gonMod
            end
            if (healneed > (818 + healMod35) * gonMod * K or 6 <= minRankNH) 
                and ManaLeft >= 335 * tsMod * mgMod and maxRankHT >= 6 and downRankNH >= 6 and SpellIDsHT[6] then
                SpellID = SpellIDsHT[6]; HealSize = (818 + healMod35) * gonMod
            end
            if (healneed > (1028 + healMod35) * gonMod * K or 7 <= minRankNH) 
                and ManaLeft >= 405 * tsMod * mgMod and maxRankHT >= 7 and downRankNH >= 7 and SpellIDsHT[7] then
                SpellID = SpellIDsHT[7]; HealSize = (1028 + healMod35) * gonMod
            end
            if (healneed > (1313 + healMod35) * gonMod * K or 8 <= minRankNH) 
                and ManaLeft >= 495 * tsMod * mgMod and maxRankHT >= 8 and downRankNH >= 8 and SpellIDsHT[8] then
                SpellID = SpellIDsHT[8]; HealSize = (1313 + healMod35) * gonMod
            end
            if (healneed > (1656 + healMod35) * gonMod * K or 9 <= minRankNH) 
                and ManaLeft >= 600 * tsMod * mgMod and maxRankHT >= 9 and downRankNH >= 9 and SpellIDsHT[9] then
                SpellID = SpellIDsHT[9]; HealSize = (1656 + healMod35) * gonMod
            end
            if (healneed > (2060 + healMod35) * gonMod * K or 10 <= minRankNH) 
                and ManaLeft >= 720 * tsMod * mgMod and maxRankHT >= 10 and downRankNH >= 10 and SpellIDsHT[10] then
                SpellID = SpellIDsHT[10]; HealSize = (2060 + healMod35) * gonMod
            end
            if (healneed > (2472 + healMod35) * gonMod * K or 11 <= minRankNH) 
                and ManaLeft >= 800 * tsMod * mgMod and maxRankHT >= 11 and downRankNH >= 11 and SpellIDsHT[11] then
                SpellID = SpellIDsHT[11]; HealSize = (2472 + healMod35) * gonMod
            end

        end

    -- =========================
    -- REGROWTH
    -- =========================
    else

        if Health < RatioFull or QHV.TestMode or (QHV.PrecastAggro and QuickHeal_UnitHasAggro(target)) then

            -- =========================
            -- RG MAX MODE
            -- =========================
            if forceMaxHPS and maxRankRG > 0 then
                debug("RG max mode")

                local manaRG = {
                    [1]=96,[2]=164,[3]=224,[4]=280,[5]=336,
                    [6]=408,[7]=492,[8]=592,[9]=704
                }

                local healRG = {
                    [1]=91,[2]=176,[3]=257,[4]=339,[5]=431,
                    [6]=543,[7]=686,[8]=857,[9]=1061
                }

                for i = maxRankRG, 1, -1 do
                    if SpellIDsRG[i] and ManaLeft >= manaRG[i] * tsMod * mgMod then
                        SpellID = SpellIDsRG[i]
                        HealSize = (healRG[i] * gonMod + healModRG) * iregMod
                        return SpellID, HealSize * HDB
                    end
                end
            end

            -- =========================
            -- RG NORMAL MODE
            -- =========================
            SpellID = SpellIDsRG[1]
            HealSize = (91 * gonMod + healModRG * PF.RG1) * iregMod

            if (healneed > (176 * gonMod + healModRG * PF.RG2) * iregMod * k or 2 <= minRankFH)
                and ManaLeft >= 164 * tsMod * mgMod and maxRankRG >= 2 and downRankFH >= 2 and SpellIDsRG[2] then
                SpellID = SpellIDsRG[2]; HealSize = (176 * gonMod + healModRG * PF.RG2) * iregMod
            end

            if (healneed > (257 * gonMod + healModRG) * iregMod * k or 3 <= minRankFH)
                and ManaLeft >= 224 * tsMod * mgMod and maxRankRG >= 3 and downRankFH >= 3 and SpellIDsRG[3] then
                SpellID = SpellIDsRG[3]; HealSize = (257 * gonMod + healModRG) * iregMod
            end
            if (healneed > (339 * gonMod + healModRG) * iregMod * k or 4 <= minRankFH)
                and ManaLeft >= 280 * tsMod * mgMod and maxRankRG >= 4 and downRankFH >= 4 and SpellIDsRG[4] then
                SpellID = SpellIDsRG[4]; HealSize = (339 * gonMod + healModRG) * iregMod
            end

            if (healneed > (431 * gonMod + healModRG) * iregMod * k or 5 <= minRankFH)
                and ManaLeft >= 336 * tsMod * mgMod and maxRankRG >= 5 and downRankFH >= 5 and SpellIDsRG[5] then
                SpellID = SpellIDsRG[5]; HealSize = (431 * gonMod + healModRG) * iregMod
            end

            if (healneed > (543 * gonMod + healModRG) * iregMod * k or 6 <= minRankFH)
                and ManaLeft >= 408 * tsMod * mgMod and maxRankRG >= 6 and downRankFH >= 6 and SpellIDsRG[6] then
                SpellID = SpellIDsRG[6]; HealSize = (543 * gonMod + healModRG) * iregMod
            end

            if (healneed > (686 * gonMod + healModRG) * iregMod * k or 7 <= minRankFH)
                and ManaLeft >= 492 * tsMod * mgMod and maxRankRG >= 7 and downRankFH >= 7 and SpellIDsRG[7] then
                SpellID = SpellIDsRG[7]; HealSize = (686 * gonMod + healModRG) * iregMod
            end
            
            if (healneed > (857 * gonMod + healModRG) * iregMod * k or 8 <= minRankFH)
                and ManaLeft >= 592 * tsMod * mgMod and maxRankRG >= 8 and downRankFH >= 8 and SpellIDsRG[8] then
                SpellID = SpellIDsRG[8]; HealSize = (857 * gonMod + healModRG) * iregMod
            end

            if (healneed > (1061 * gonMod + healModRG) * iregMod * k or 9 <= minRankFH)
                and ManaLeft >= 704 * tsMod * mgMod and maxRankRG >= 9 and downRankFH >= 9 and SpellIDsRG[9] then
                SpellID = SpellIDsRG[9]; HealSize = (1061 * gonMod + healModRG) * iregMod
            end
        end
    end

    return SpellID, HealSize * HDB
end

-- NoTarget wrapper for backwards compatibility
function QuickHeal_Druid_FindHealSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxHPS,
                                                    forceMaxRank, hdb, incombat)
    return QuickHeal_Druid_FindHealSpellToUse(nil, healType, multiplier, forceMaxHPS, maxhealth, healDeficit, hdb,
        incombat)
end

-- Unified HoT spell selection (Rejuvenation)
function QuickHeal_Druid_FindHoTSpellToUse(target, healType, forceMaxRank, maxhealth, healDeficit, hdb, incombat)
    local SpellID = nil
    local HealSize = 0

    local RatioHealthy = QuickHeal_GetRatioHealthy()
    local debug = QuickHeal_debug

    -- Get health info
    local healneed, Health, HDB
    if target then
        if QuickHeal_UnitHasHealthInfo(target) then
            healneed = QH_GetUnitMaxHealth(target) - QH_GetUnitHealth(target)
            Health = QH_GetUnitHealth(target) / QH_GetUnitMaxHealth(target)
        else
            healneed = QuickHeal_EstimateUnitHealNeed(target, true)
            Health = QH_GetUnitHealth(target) / 100
        end
        HDB = QuickHeal_GetHealModifier(target)
        incombat = UnitAffectingCombat('player') or UnitAffectingCombat(target)
    else
        if not maxhealth or maxhealth <= 0 then return nil, 0 end
        healneed = (healDeficit or 0) * (1) -- multiplier not used for HoT
        Health = (healDeficit or 0) / maxhealth
        HDB = hdb or 1
        incombat = UnitAffectingCombat('player') or incombat
    end

    debug("Target debuff healing modifier", HDB)
    healneed = healneed / HDB

    -- Return if no target
    if target == nil and maxhealth == nil then
        return nil, 0
    end

    -- Get modifiers
    local mods = GetDruidModifiers()
    local ManaLeft = QH_GetUnitMana('player')

    -- Detect Clearcasting (from Omen of Clarity)
    if QuickHeal_DetectBuff('player', "Spell_Shadow_ManaBurn", 1) then
        debug("BUFF: Clearcasting (Omen of Clarity)")
        ManaLeft = QH_GetUnitMaxMana('player')
        healneed = 10 ^ 6
    end

    -- Get spell IDs
    local SpellIDsRJ = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_REJUVENATION)
    local maxRankRJ = table.getn(SpellIDsRJ)

    debug(string.format("Found RJ up to rank %d", maxRankRJ))

    -- Combat multipliers
    local k, K = QuickHeal_GetCombatMultipliers(incombat)

    local gonMod = mods.gonMod
    local mgMod = mods.mgMod
    local genMod = mods.genMod
    local healMod15 = mods.healMod15

    local TargetIsHealthy = Health >= RatioHealthy
    if TargetIsHealthy then
        debug("Target is healthy", Health)
    end

    if healType == "hot" then
        if not forceMaxRank then
            -- Select rank based on healneed
            SpellID = SpellIDsRJ[1]; HealSize = (36* genMod * gonMod + healMod15) 
            if healneed > (60* genMod * gonMod + healMod15) * k and ManaLeft >= 40 * mgMod and maxRankRJ >= 2 and SpellIDsRJ[2] then
                SpellID = SpellIDsRJ[2]; HealSize = (60* genMod * gonMod + healMod15) 
            end
            if healneed > (120* genMod * gonMod + healMod15) * k and ManaLeft >= 75 * mgMod and maxRankRJ >= 3 and SpellIDsRJ[3] then
                SpellID = SpellIDsRJ[3]; HealSize = (120* genMod * gonMod + healMod15) 
            end
            if healneed > (180* genMod * gonMod + healMod15) * k and ManaLeft >= 105 * mgMod and maxRankRJ >= 4 and SpellIDsRJ[4] then
                SpellID = SpellIDsRJ[4]; HealSize = (180* genMod * gonMod + healMod15) 
            end
            if healneed > (246* genMod * gonMod + healMod15) * k and ManaLeft >= 135 * mgMod and maxRankRJ >= 5 and SpellIDsRJ[5] then
                SpellID = SpellIDsRJ[5]; HealSize = (246* genMod * gonMod + healMod15) 
            end
            if healneed > (306* genMod * gonMod + healMod15) * k and ManaLeft >= 160 * mgMod and maxRankRJ >= 6 and SpellIDsRJ[6] then
                SpellID = SpellIDsRJ[6]; HealSize = (306* genMod * gonMod + healMod15) 
            end
            if healneed > (390* genMod * gonMod + healMod15) * k and ManaLeft >= 195 * mgMod and maxRankRJ >= 7 and SpellIDsRJ[7] then
                SpellID = SpellIDsRJ[7]; HealSize = (390* genMod * gonMod + healMod15) 
            end
            if healneed > (492* genMod * gonMod + healMod15) * k and ManaLeft >= 235 * mgMod and maxRankRJ >= 8 and SpellIDsRJ[8] then
                SpellID = SpellIDsRJ[8]; HealSize = (492* genMod * gonMod + healMod15) 
            end
            if healneed > (612* genMod * gonMod + healMod15) * k and ManaLeft >= 280 * mgMod and maxRankRJ >= 9 and SpellIDsRJ[9] then
                SpellID = SpellIDsRJ[9]; HealSize = (612* genMod * gonMod + healMod15) 
            end
            if healneed > (756* genMod * gonMod + healMod15) * k and ManaLeft >= 335 * mgMod and maxRankRJ >= 10 and SpellIDsRJ[10] then
                SpellID = SpellIDsRJ[10]; HealSize = (756* genMod * gonMod + healMod15) 
            end
            if healneed > (888* genMod * gonMod + healMod15) * k and ManaLeft >= 360 * mgMod and maxRankRJ >= 11 and SpellIDsRJ[11] then
                SpellID = SpellIDsRJ[11]; HealSize = (888* genMod * gonMod + healMod15) 
            end
        else
            -- Force max rank
            if maxRankRJ >= 1 and SpellIDsRJ[1] then
                SpellID = SpellIDsRJ[1]; HealSize = (36* genMod * gonMod + healMod15) 
            end
            if maxRankRJ >= 2 and SpellIDsRJ[2] then
                SpellID = SpellIDsRJ[2]; HealSize = (60* genMod * gonMod + healMod15) 
            end
            if maxRankRJ >= 3 and SpellIDsRJ[3] then
                SpellID = SpellIDsRJ[3]; HealSize = (120* genMod * gonMod + healMod15) 
            end
            if maxRankRJ >= 4 and SpellIDsRJ[4] then
                SpellID = SpellIDsRJ[4]; HealSize = (180* genMod * gonMod + healMod15) 
            end
            if maxRankRJ >= 5 and SpellIDsRJ[5] then
                SpellID = SpellIDsRJ[5]; HealSize = (246* genMod * gonMod + healMod15) 
            end
            if maxRankRJ >= 6 and SpellIDsRJ[6] then
                SpellID = SpellIDsRJ[6]; HealSize = (306* genMod * gonMod + healMod15) 
            end
            if maxRankRJ >= 7 and SpellIDsRJ[7] then
                SpellID = SpellIDsRJ[7]; HealSize = (390* genMod * gonMod + healMod15) 
            end
            if maxRankRJ >= 8 and SpellIDsRJ[8] then
                SpellID = SpellIDsRJ[8]; HealSize = (492* genMod * gonMod + healMod15) 
            end
            if maxRankRJ >= 9 and SpellIDsRJ[9] then
                SpellID = SpellIDsRJ[9]; HealSize = (612* genMod * gonMod + healMod15) 
            end
            if maxRankRJ >= 10 and SpellIDsRJ[10] then
                SpellID = SpellIDsRJ[10]; HealSize = (756* genMod * gonMod + healMod15) 
            end
            if maxRankRJ >= 11 and SpellIDsRJ[11] then
                SpellID = SpellIDsRJ[11]; HealSize = (888* genMod * gonMod + healMod15) 
            end
        end
    end

    return SpellID, HealSize * HDB
end

-- NoTarget wrapper for backwards compatibility
function QuickHeal_Druid_FindHoTSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxHPS,
                                                   forceMaxRank, hdb, incombat)
    return QuickHeal_Druid_FindHoTSpellToUse(nil, healType, forceMaxRank, maxhealth, healDeficit, hdb, incombat)
end

function QuickHeal_Command_Druid(msg)

    local args = {}
    for word in string.gfind(string.lower(msg), "%S+") do
        table.insert(args, word)
    end

    local a1, a2, a3 = args[1], args[2], args[3]

    -- =========================================================
    -- 3 ARGS (mask + action + mod)
    -- =========================================================
    if a1 and a2 and a3 then

        local mask = a1

        if mask == "player"
        or mask == "target"
        or mask == "targettarget"
        or mask == "party"
        or mask == "subgroup"
        or mask == "mt"
        or mask == "nonmt" then

            -- /qh mask heal max
            if a2 == "heal" and a3 == "max" then
                QuickHeal(mask, nil, nil, true)
                return
            end

            -- /qh mask ht max
            if a2 == "ht" and a3 == "max" then
                QuickHeal(mask, nil, { healType = "ht" }, true)
                return
            end

            -- /qh mask rg max
            if a2 == "rg" and a3 == "max" then
                QuickHeal(mask, nil, { healType = "rg" }, true)
                return
            end

            -- /qh mask hot spam
            if a2 == "hot" and a3 == "spam" then
                QuickHOT(mask, nil, nil, true, true)
                return
            end

            -- /qh mask hot max
            if a2 == "hot" and a3 == "max" then
                QuickHOT(mask, nil, nil, true, false)
                return
            end
        end
    end

    -- =========================================================
    -- 2 ARGS (global commands)
    -- =========================================================
    if a1 and a2 then

        -- debug
        if a1 == "debug" then
            QHV.DebugMode = (a2 == "on")
            return
        end

        -- test mode
        if a1 == "test" then
            QHV.TestMode = (a2 == "on")
            writeLine("QuickHeal: Test mode " .. (QHV.TestMode and "ON" or "OFF"))
            return
        end

        -- GLOBAL HEAL MAX (AUTO MODE)
        if a1 == "heal" and a2 == "max" then
            QuickHeal(nil, nil, nil, true)
            return
        end

        -- HOT MODES
        if a1 == "hot" and a2 == "max" then
            QuickHOT(nil, nil, nil, true, false)
            return
        end

        if a1 == "hot" and a2 == "spam" then
            QuickHOT(nil, nil, nil, true, true)
            return
        end

        -- DIRECT TARGET TYPE COMMANDS
        if a1 == "player"
        or a1 == "target"
        or a1 == "targettarget"
        or a1 == "party"
        or a1 == "subgroup"
        or a1 == "mt"
        or a1 == "nonmt" then

            if a2 == "heal" then
                QuickHeal(a1, nil, nil, false)
                return
            end

            if a2 == "ht" then
                QuickHeal(a1, nil, { healType = "ht" }, false)
                return
            end

            if a2 == "rg" then
                QuickHeal(a1, nil, { healType = "rg" }, false)
                return
            end

            if a2 == "hot" then
                QuickHOT(a1, nil, nil, false, false)
                return
            end
        end
    end

    -- =========================================================
    -- 1 ARG (simple commands)
    -- =========================================================
    local cmd = string.lower(msg)

    if cmd == "" then
        QuickHeal(nil)
        return
    end

    if cmd == "heal" then
        QuickHeal()
        return
    end

    if cmd == "ht" then
        QuickHeal(nil, nil, { healType = "ht" })
        return
    end

    if cmd == "rg" then
        QuickHeal(nil, nil, { healType = "rg" })
        return
    end

    if cmd == "hot" then
        QuickHOT()
        return
    end

    if cmd == "ht max" then
        QuickHeal(nil, nil, { healType = "ht" }, true)
        return
    end

    if cmd == "rg max" then
        QuickHeal(nil, nil, { healType = "rg" }, true)
        return
    end

    if cmd == "heal max" then
        QuickHeal(nil, nil, nil, true)
        return
    end

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
        writeLine(QuickHealData.name .. " reset to default configuration")
        return
    end

    if cmd == "dll" then
        QuickHeal_ReportDLLStatus()
        return
    end

	
    -- Print usage
    writeLine("== QUICKHEAL DRUID ==")
    -- =========================================================
    -- BASIC USAGE
    -- =========================================================
    writeLine(" ")
    writeLine("Basic usage:")
    writeLine("/qh [target] [type] [mode]")
    writeLine(" ")
    writeLine("Targets:")
    writeLine(" player | target | targettarget | party | mt | nonmt | subgroup")
    writeLine(" ")
    writeLine("Types:")
    writeLine(" heal  - Smart heal (HT or RG via slider)")
    writeLine(" ht    - Force Healing Touch")
    writeLine(" rg    - Force Regrowth")
    writeLine(" hot   - Rejuvenation")
    writeLine(" ")
    writeLine("Modes:")
    writeLine(" max   - Use highest rank available")
    writeLine(" spam  - (HOT only) spam max rank without HP check")
    -- =========================================================
    -- EXAMPLES
    -- =========================================================
    writeLine(" ")
    writeLine("Examples:")
    writeLine("/qh                 - Smart heal (slider decides HT or RG)")
    writeLine("/qh heal max        - Smart heal using max ranks")
    writeLine("/qh ht              - Force Healing Touch (normal rank)")
    writeLine("/qh ht max          - Force max rank Healing Touch")
    writeLine("/qh rg              - Force Regrowth (normal rank)")
    writeLine("/qh rg max          - Force max rank Regrowth")
    writeLine("/qh hot spam        - Spam max Rejuvenation")
    -- =========================================================
    -- SETTINGS
    -- =========================================================
    writeLine(" ")
    writeLine("Settings:")
    writeLine("/qh cfg             - Open configuration panel")
    writeLine("/qh toggle          - Toggle heal threshold mode (slider)")
    writeLine("/qh downrank | dr   - Limit usable spell ranks")
    writeLine("/qh tanklist | tl   - Toggle main tank list")
    writeLine("/qh reset           - Reset all settings")
    -- =========================================================
    -- DEBUG / DEV
    -- =========================================================
    writeLine(" ")
    writeLine("Debug:")
    writeLine("/qh test on|off     - Test mode (ignore HP thresholds)")
    writeLine("/qh debug on|off    - Debug logs")
    writeLine("/qh dll             - DLL status report")
end
