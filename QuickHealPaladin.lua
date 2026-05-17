-- QuickHeal Paladin Module (Refactored)
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
    [14] = 0.775,
}

function QuickHeal_Paladin_GetRatioHealthyExplanation()
    local RatioHealthy = QuickHeal_GetRatioHealthy()
    local RatioFull    = QuickHealVariables["RatioFull"]
    if RatioHealthy >= RatioFull then
        return QUICKHEAL_SPELL_HOLY_LIGHT ..
            " will always be preferred if no " ..
            QUICKHEAL_SPELL_FLASH_OF_LIGHT .. " can fill the heal need. "
    else
        if RatioHealthy > 0 then
            return QUICKHEAL_SPELL_HOLY_LIGHT ..
                " will be preferred if the target has less than " ..
                RatioHealthy * 100 ..
                "% life, and no " ..
                QUICKHEAL_SPELL_FLASH_OF_LIGHT .. " can fill the heal need. "
        else
            return QUICKHEAL_SPELL_HOLY_LIGHT .. " is never used. " ..
                QUICKHEAL_SPELL_FLASH_OF_LIGHT .. " is used by default. "
        end
    end
end

-- =========================
-- PALADIN MODIFIERS
-- =========================
local function GetPaladinModifiers()
    local mods = {}
    mods.bonus     = QuickHeal_GetEquipmentBonus()
    mods.healMod15 = (1.5 / 3.5) * mods.bonus
    mods.healMod25 = (2.5 / 3.5) * mods.bonus
    
    -- Healing Light - increases healing by 4% per rank
    local hlRank   = QuickHeal_GetTalentRank(1, 6)
    mods.hlMod     = 1 + 4 * hlRank / 100

    -- Divine Favor - increases Holy Shock crit by 10% per rank (0.5 effective bonus per rank)
    local dfRank   = QuickHeal_GetTalentRank(1, 13)
    mods.dfMod     = 1 + 5 * dfRank / 100
    
    -- Holy Power - increases Holy Spell crit by 1% per rank (0.5 effective bonus per rank)
    local hpRank   = QuickHeal_GetTalentRank(1, 15)
    mods.hpMod     = 1 + 0.5 * hpRank / 100
    
    return mods
end

-- =========================
-- PALADIN BUFFS
-- Returns: forceHL, forceMax
-- =========================

-- Holy Judgement buff spell IDs (one per talent rank)
local HOLY_JUDGEMENT_BUFF_IDS = {
    [51305] = true, -- Rank 1
    [51307] = true, -- Rank 2
    [51309] = true, -- Rank 3
}

-- Check for Paladin-specific buffs that affect healing
-- Returns: forceHL flag
local function CheckPaladinBuffs()
    local forceHL = false
    
    -- Nampower: use aura spell ID array for reliable detection (no false positives)
    if GetUnitField then
        local success, auras = pcall(GetUnitField, "player", "aura")
        if success and auras then
            for i = 1, 31 do -- slots 1-31 are buffs
                local spellId = auras[i]
                if spellId and spellId > 0 then
                    if HOLY_JUDGEMENT_BUFF_IDS[spellId] then -- Holy Judgement
                        QuickHeal_debug("BUFF: Holy Judgement [" .. spellId .. "] (HL forced)")
                        forceHL = true
                    elseif spellId == 18803 then -- Focus (Hand of Edward the Odd)
                        QuickHeal_debug("BUFF: Hand of Edward the Odd [" .. spellId .. "] (HL forced)")
                        forceHL = true
                    end
                end
            end
        end
    end

    -- Hand of Edward the odd
    if not forceHL and QuickHeal_DetectBuff('player', "Spell_Holy_SearingLight$") and
       not QuickHeal_DetectBuff('player', "Spell_Holy_SearingLightPriest") then
        QuickHeal_debug("BUFF: Hand of Edward the Odd (texture fallback, HL forced)")
        forceHL = true
    end

    -- Holy Judgement
    if not forceHL and QuickHeal_DetectBuff('player', "ability_paladin_judgementblue$") then
        QuickHeal_debug("BUFF: Holy Judgement (texture fallback, HL forced)")
        forceHL = true
    end

    return forceHL
end

-- =========================
-- MAIN HEAL SPELL SELECTION
-- target : unit ID or nil (NoTarget mode)
-- healType : "hl" | "fl" | nil (auto)
-- =========================
function QuickHeal_Paladin_FindSpellToUse(target, healType, multiplier, forceMaxHPS,
                                          maxhealth, healDeficit, hdb, incombat)
    local SpellID  = nil
    local HealSize = 0
    multiplier     = multiplier or 1

    local RatioFull    = QuickHealVariables["RatioFull"]
    local RatioHealthy = QuickHeal_GetRatioHealthy()
    local debug        = QuickHeal_debug

    -- =========================
    -- HEALTH CALCULATION
    -- =========================
    local healneed, Health, HDB
    if target then
        if QuickHeal_UnitHasHealthInfo(target) and QH_GetUnitMaxHealth(target) > 0 then
            healneed = QH_GetUnitMaxHealth(target) - QH_GetUnitHealth(target)
            if multiplier > 1.0 then healneed = healneed * multiplier end
            Health   = QH_GetUnitHealth(target) / QH_GetUnitMaxHealth(target)
        else
            healneed = QuickHeal_EstimateUnitHealNeed(target, true)
            if multiplier > 1.0 then healneed = healneed * multiplier end
            Health   = QH_GetUnitHealth(target) / 100
        end
        HDB      = QuickHeal_GetHealModifier(target)
        incombat = UnitAffectingCombat('player') or UnitAffectingCombat(target)
    else
        if not maxhealth or maxhealth <= 0 then return nil, 0 end
        healneed = healDeficit * multiplier
        Health   = healDeficit / maxhealth
        HDB      = hdb or 1
        incombat = UnitAffectingCombat('player') or incombat
    end

    if target == nil and maxhealth == nil then return nil, 0 end

    debug("Target debuff healing modifier", HDB)
    healneed = healneed / HDB
    if healneed <= 0 then return nil, 0 end

    -- Guard: don't heal a full target (unless test mode, no target, or aggro precast)
    if not (Health < RatioFull or QHV.TestMode or not target or
            (QHV.PrecastAggro and QuickHeal_UnitHasAggro(target))) then
        return nil, 0
    end

    -- =========================
    -- MANA / BUFFS
    -- =========================
    local mods     = GetPaladinModifiers()
    local ManaLeft = QH_GetUnitMana('player')

    local buffForceHL, buffForceMax = CheckPaladinBuffs()
    forceMaxHPS = forceMaxHPS or buffForceMax

    -- =========================
    -- SPELL TABLES
    -- =========================
    local SpellIDsHL = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HOLY_LIGHT)
    local SpellIDsFL = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_FLASH_OF_LIGHT)
    local maxRankHL  = table.getn(SpellIDsHL)
    local maxRankFL  = table.getn(SpellIDsFL)
    debug(string.format("HL %d / FL %d", maxRankHL, maxRankFL))

    -- =========================
    -- SETTINGS
    -- =========================
    local downRankFH = QuickHealVariables.DownrankValueFH or 0
    local downRankNH = QuickHealVariables.DownrankValueNH or 0
    local minRankFH  = QuickHealVariables.MinrankValueFH  or 1
    local minRankNH  = QuickHealVariables.MinrankValueNH  or 1

    local k, K = QuickHeal_GetCombatMultipliers(incombat)

    local TargetIsHealthy = Health >= RatioHealthy
    local hlMod           = mods.hlMod
    local hpMod           = mods.hpMod
    local healMod15       = mods.healMod15
    local healMod25       = mods.healMod25

    -- =========================
    -- HEAL TYPE RESOLUTION
    -- =========================
    local forceHL = (healType == "hl") or buffForceHL
    local forceFL = (healType == "fl")

    -- Max heal FL can provide at current max rank
    local maxFLHeal = 0
    if maxRankFL >= 7 and SpellIDsFL[7] then
        maxFLHeal = (428 + healMod15) * hlMod * hpMod
    elseif maxRankFL >= 6 and SpellIDsFL[6] then
        maxFLHeal = (348 + healMod15) * hlMod * hpMod
    elseif maxRankFL >= 5 and SpellIDsFL[5] then
        maxFLHeal = (278 + healMod15) * hlMod * hpMod
    elseif maxRankFL >= 4 and SpellIDsFL[4] then
        maxFLHeal = (206 + healMod15) * hlMod * hpMod
    elseif maxRankFL >= 3 and SpellIDsFL[3] then
        maxFLHeal = (153 + healMod15) * hlMod * hpMod
    elseif maxRankFL >= 2 and SpellIDsFL[2] then
        maxFLHeal = (102 + healMod15) * hlMod * hpMod
    elseif maxRankFL >= 1 and SpellIDsFL[1] then
        maxFLHeal = (67  + healMod15) * hlMod * hpMod
    end

    local FLCoversNeed = (maxRankFL >= 1) and (maxFLHeal >= healneed)

    -- useHL = true  → Holy Light branch
    -- useHL = false → Flash of Light branch
    
    local useHL
    if forceHL then
        useHL = true
    elseif forceFL then
        useHL = false
    else
        -- Auto mode: same logic than normal mode, with slider respect
        -- HL if : no fl, unhealthy target, or fl not enough to heal
        local NoFL = (maxRankFL < 1)
        useHL = NoFL or (not TargetIsHealthy and not FLCoversNeed)
    end

    debug(string.format(
        "FLCoversNeed=%s useHL=%s maxFLHeal=%.0f healneed=%.0f",
        tostring(FLCoversNeed), tostring(useHL), maxFLHeal, healneed))

    -- =========================
    -- HOLY LIGHT
    -- =========================
    if useHL then
        -- HL MAX MODE (forceMaxHPS)
        if forceMaxHPS and maxRankHL > 0 then
            debug("HL max mode")
            local manaHL = {
                [1]=35,[2]=60,[3]=110,[4]=190,[5]=275,
                [6]=365,[7]=465,[8]=580,[9]=660
            }
            local healHL = {
                [1]=43,[2]=83,[3]=173,[4]=333,[5]=522,
                [6]=739,[7]=999,[8]=1317,[9]=1680
            }
            for i = maxRankHL, 1, -1 do
                if SpellIDsHL[i] and ManaLeft >= manaHL[i] then
                    SpellID  = SpellIDsHL[i]
                    HealSize = healHL[i] * hlMod * hpMod
                    return SpellID, HealSize * HDB
                end
            end
        end

        -- HL NORMAL MODE
        if maxRankHL >= 1 and SpellIDsHL[1] then
            SpellID  = SpellIDsHL[1]
            HealSize = (43 + healMod25 * PF[1]) * hlMod * hpMod
        end
        if (healneed > (83 + healMod25 * PF[6]) * hlMod * hpMod * K or 2 <= minRankNH)
            and ManaLeft >= 60 and maxRankHL >= 2 and downRankNH >= 2 and SpellIDsHL[2] then
            SpellID  = SpellIDsHL[2]
            HealSize = (83 + healMod25 * PF[6])  * hlMod * hpMod
        end
        if (healneed > (173 + healMod25 * PF[14]) * hlMod * hpMod * K or 3 <= minRankNH)
            and ManaLeft >= 110 and maxRankHL >= 3 and downRankNH >= 3 and SpellIDsHL[3] then
            SpellID  = SpellIDsHL[3]
            HealSize = (173 + healMod25 * PF[14]) * hlMod * hpMod
        end
        if (healneed > (333 + healMod25) * hlMod * hpMod * K or 4 <= minRankNH)
            and ManaLeft >= 190 and maxRankHL >= 4 and downRankNH >= 4 and SpellIDsHL[4] then
            SpellID  = SpellIDsHL[4]
            HealSize = (333 + healMod25) * hlMod * hpMod
        end
        if (healneed > (522 + healMod25) * hlMod * hpMod * K or 5 <= minRankNH)
            and ManaLeft >= 275 and maxRankHL >= 5 and downRankNH >= 5 and SpellIDsHL[5] then
            SpellID  = SpellIDsHL[5]
            HealSize = (522 + healMod25) * hlMod * hpMod
        end
        if (healneed > (739 + healMod25) * hlMod * hpMod * K or 6 <= minRankNH)
            and ManaLeft >= 365 and maxRankHL >= 6 and downRankNH >= 6 and SpellIDsHL[6] then
            SpellID  = SpellIDsHL[6]
            HealSize = (739 + healMod25) * hlMod * hpMod
        end
        if (healneed > (999 + healMod25) * hlMod * hpMod * K or 7 <= minRankNH)
            and ManaLeft >= 465 and maxRankHL >= 7 and downRankNH >= 7 and SpellIDsHL[7] then
            SpellID  = SpellIDsHL[7]
            HealSize = (999 + healMod25) * hlMod * hpMod
        end
        if (healneed > (1317 + healMod25) * hlMod * hpMod * K or 8 <= minRankNH)
            and ManaLeft >= 580 and maxRankHL >= 8 and downRankNH >= 8 and SpellIDsHL[8] then
            SpellID  = SpellIDsHL[8]
            HealSize = (1317 + healMod25) * hlMod * hpMod
        end
        if (healneed > (1680 + healMod25) * hlMod * hpMod * K or 9 <= minRankNH)
            and ManaLeft >= 660 and maxRankHL >= 9 and downRankNH >= 9 and SpellIDsHL[9] then
            SpellID  = SpellIDsHL[9]
            HealSize = (1680 + healMod25) * hlMod * hpMod
        end

    -- =========================
    -- FLASH OF LIGHT
    -- =========================
    else
        -- FL MAX MODE (forceMaxHPS)
        if forceMaxHPS and maxRankFL > 0 then
            debug("FL max mode")
            local manaFL = {
                [1]=30,[2]=50,[3]=70,[4]=90,[5]=115,[6]=140,[7]=180
            }
            local healFL = {
                [1]=67,[2]=102,[3]=153,[4]=206,[5]=278,[6]=348,[7]=428
            }
            for i = maxRankFL, 1, -1 do
                if SpellIDsFL[i] and ManaLeft >= manaFL[i] then
                    SpellID  = SpellIDsFL[i]
                    HealSize = healFL[i] * hlMod * hpMod
                    return SpellID, HealSize * HDB
                end
            end
        end

        -- FL NORMAL MODE
        if maxRankFL >= 1 and SpellIDsFL[1] then
            SpellID  = SpellIDsFL[1]
            HealSize = (67 + healMod15) * hlMod * hpMod
        end
        if (healneed > (102 + healMod15) * hlMod * hpMod * k or 2 <= minRankFH)
            and ManaLeft >= 50 and maxRankFL >= 2 and downRankFH >= 2 and SpellIDsFL[2] then
            SpellID  = SpellIDsFL[2]
            HealSize = (102 + healMod15) * hlMod * hpMod
        end
        if (healneed > (153 + healMod15) * hlMod * hpMod * k or 3 <= minRankFH)
            and ManaLeft >= 70 and maxRankFL >= 3 and downRankFH >= 3 and SpellIDsFL[3] then
            SpellID  = SpellIDsFL[3]
            HealSize = (153 + healMod15) * hlMod * hpMod
        end
        if (healneed > (206 + healMod15) * hlMod * hpMod * k or 4 <= minRankFH)
            and ManaLeft >= 90 and maxRankFL >= 4 and downRankFH >= 4 and SpellIDsFL[4] then
            SpellID  = SpellIDsFL[4]
            HealSize = (206 + healMod15) * hlMod * hpMod
        end
        if (healneed > (278 + healMod15) * hlMod * hpMod * k or 5 <= minRankFH)
            and ManaLeft >= 115 and maxRankFL >= 5 and downRankFH >= 5 and SpellIDsFL[5] then
            SpellID  = SpellIDsFL[5]
            HealSize = (278 + healMod15) * hlMod * hpMod
        end
        if (healneed > (348+ healMod15) * hlMod  * hpMod * k or 6 <= minRankFH)
            and ManaLeft >= 140 and maxRankFL >= 6 and downRankFH >= 6 and SpellIDsFL[6] then
            SpellID  = SpellIDsFL[6]
            HealSize = (348 + healMod15) * hlMod * hpMod
        end
        if (healneed > (428 + healMod15) * hlMod * hpMod * k or 7 <= minRankFH)
            and ManaLeft >= 180 and maxRankFL >= 7 and downRankFH >= 7 and SpellIDsFL[7] then
            SpellID  = SpellIDsFL[7]
            HealSize = (428 + healMod15) * hlMod * hpMod
        end
    end

    return SpellID, HealSize * HDB
end

-- NoTarget wrapper for backwards compatibility
function QuickHeal_Paladin_FindHealSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier,
                                                      forceMaxHPS, forceMaxRank, hdb, incombat)
    return QuickHeal_Paladin_FindSpellToUse(nil, healType, multiplier, forceMaxHPS,
                                            maxhealth, healDeficit, hdb, incombat)
end

-- =========================
-- HOLY SHOCK 
-- =========================
function QuickHeal_Paladin_FindHoTSpellToUse(target, healType, forceMaxRank,
                                              maxhealth, healDeficit, hdb, incombat)
    local SpellID  = nil
    local HealSize = 0
    local debug    = QuickHeal_debug

    -- Health info
    local healneed, Health, HDB
    if target then
        if QuickHeal_UnitHasHealthInfo(target) then
            healneed = QH_GetUnitMaxHealth(target) - QH_GetUnitHealth(target)
            Health   = QH_GetUnitHealth(target) / QH_GetUnitMaxHealth(target)
        else
            healneed = QuickHeal_EstimateUnitHealNeed(target, true)
            Health   = QH_GetUnitHealth(target) / 100
        end
        HDB = QuickHeal_GetHealModifier(target)
    else
        if not healDeficit or healDeficit <= 0 then return nil, 0 end
        healneed = healDeficit
        Health   = 1 - (healDeficit / maxhealth)
        HDB      = hdb or 1
    end

    if target == nil and maxhealth == nil then return nil, 0 end

    debug("Target debuff healing modifier", HDB)
    healneed = healneed / HDB

    local mods     = GetPaladinModifiers()
    local ManaLeft = QH_GetUnitMana('player')

    local SpellIDsHS = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HOLY_SHOCK)
    local maxRankHS  = table.getn(SpellIDsHS)
    debug(string.format("Found HS up to rank %d", maxRankHS))

    -- Cooldown check (Nampower)
    if maxRankHS >= 1 and GetSpellIdForName then
        local ok, dbcId = pcall(GetSpellIdForName, QUICKHEAL_SPELL_HOLY_SHOCK)
        if ok and dbcId and QH_IsSpellOnCooldown(dbcId) then
            debug("Holy Shock is on cooldown, skipping")
            return nil, 0
        end
    end

    local hlMod    = mods.hlMod
    local hpMod    = mods.hpMod
    local dfMod    = mods.dfMod
    local healMod15 = mods.healMod15

    debug(string.format(
        "healneed: %f  target: %s  healType: %s  forceMaxRank: %s",
        healneed, tostring(target), tostring(healType), tostring(forceMaxRank)))

    if forceMaxRank then
        if maxRankHS >= 1 then
            SpellID  = SpellIDsHS[maxRankHS]
            HealSize = (655 + healMod15) * hlMod * dfMod
        end
    else
        if maxRankHS >= 1 and SpellIDsHS[1] then
            SpellID  = SpellIDsHS[1]
            HealSize = (315 + healMod15) * hlMod * dfMod
        end
        if healneed > (360 + healMod15) * hlMod * dfMod
            and ManaLeft >= 335 and maxRankHS >= 2 and SpellIDsHS[2] then
            SpellID  = SpellIDsHS[2]
            HealSize = (360 + healMod15) * hlMod * dfMod
        end
        if healneed > (500 + healMod15) * hlMod * dfMod
            and ManaLeft >= 410 and maxRankHS >= 3 and SpellIDsHS[3] then
            SpellID  = SpellIDsHS[3]
            HealSize = (500 + healMod15) * hlMod * dfMod
        end
        if healneed > (655 + healMod15) * hlMod * dfMod
            and ManaLeft >= 485 and maxRankHS >= 4 and SpellIDsHS[4] then
            SpellID  = SpellIDsHS[4]
            HealSize = (655 + healMod15) * hlMod * dfMod
        end
    end

    return SpellID, HealSize * HDB
end

-- NoTarget wrapper for backwards compatibility
function QuickHeal_Paladin_FindHoTSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier,
                                                      forceMaxHPS, forceMaxRank, hdb, incombat)
    return QuickHeal_Paladin_FindHoTSpellToUse(nil, healType, forceMaxRank,
                                               maxhealth, healDeficit, hdb, incombat)
end

-- =========================
-- COMMAND HANDLER
-- =========================
function QuickHeal_Command_Paladin(msg)
    local args = {}
    for word in string.gfind(string.lower(msg), "%S+") do
        table.insert(args, word)
    end
    local a1, a2, a3 = args[1], args[2], args[3]

    -- =========================================================
    -- 3 ARGS  (mask + type + mode)
    -- =========================================================
    if a1 and a2 and a3 then
        local validMask = (a1 == "player" or a1 == "target" or a1 == "targettarget"
                        or a1 == "party"  or a1 == "subgroup"
                        or a1 == "mt"     or a1 == "nonmt")
        if validMask then
            -- /qh <mask> heal max
            if a2 == "heal" and a3 == "max" then
                QuickHeal(a1, nil, nil, true)
                return
            end
            -- /qh <mask> hl max
            if a2 == "hl" and a3 == "max" then
                QuickHeal(a1, nil, { healType = "hl" }, true)
                return
            end
            -- /qh <mask> fl max
            if a2 == "fl" and a3 == "max" then
                QuickHeal(a1, nil, { healType = "fl" }, true)
                return
            end
            -- /qh <mask> hs max
            if a2 == "hs" and a3 == "max" then
                QuickHOT(a1, nil, nil, true, false)
                return
            end
        end
    end

    -- =========================================================
    -- 2 ARGS
    -- =========================================================
    if a1 and a2 then
        -- debug on/off
        if a1 == "debug" then
            QHV.DebugMode = (a2 == "on")
            return
        end
        -- test on/off
        if a1 == "test" then
            QHV.TestMode = (a2 == "on")
            writeLine("QuickHeal: Test mode " .. (QHV.TestMode and "ON" or "OFF"))
            return
        end

        -- Global heal max
        if a1 == "heal" and a2 == "max" then
            QuickHeal(nil, nil, nil, true)
            return
        end
        -- /qh hl max
        if a1 == "hl" and a2 == "max" then
            QuickHeal(nil, nil, { healType = "hl" }, true)
            return
        end
        -- /qh fl max
        if a1 == "fl" and a2 == "max" then
            QuickHeal(nil, nil, { healType = "fl" }, true)
            return
        end
        -- /qh hs max
        if a1 == "hs" and a2 == "max" then
            QuickHOT(nil, nil, nil, true, false)
            return
        end

        -- <mask> + type
        local validMask = (a1 == "player" or a1 == "target" or a1 == "targettarget"
                        or a1 == "party"  or a1 == "subgroup"
                        or a1 == "mt"     or a1 == "nonmt")
        if validMask then
            if a2 == "heal" then
                QuickHeal(a1, nil, nil, false)
                return
            end
            if a2 == "hl" then
                QuickHeal(a1, nil, { healType = "hl" }, false)
                return
            end
            if a2 == "fl" then
                QuickHeal(a1, nil, { healType = "fl" }, false)
                return
            end
            if a2 == "hs" then
                QuickHOT(a1, nil, nil, false, false)
                return
            end
        end
    end

    -- =========================================================
    -- 1 ARG / bare command
    -- =========================================================
    local cmd = string.lower(msg)

    if cmd == "" then
        QuickHeal(nil, nil, nil, false)
        return
    end
    if cmd == "heal" then
        QuickHeal(nil, nil, nil, false)
        return
    end
    if cmd == "hl" then
        QuickHeal(nil, nil, { healType = "hl" }, false)
        return
    end
    if cmd == "fl" then
        QuickHeal(nil, nil, { healType = "fl" }, false)
        return
    end
    if cmd == "hs" then
        QuickHOT()
        return
    end
    if cmd == "hot" then
        writeLine("The command /qh hot is disabled for Paladins. Use /qh hs instead.", 1, 0, 0)
        return
    end

    -- Target-only shorthand  /qh player  /qh target …
    if cmd == "player" or cmd == "target" or cmd == "targettarget"
    or cmd == "party"  or cmd == "subgroup"
    or cmd == "mt"     or cmd == "nonmt" then
        QuickHeal(cmd, nil, nil, false)
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

    -- =========================
    -- HELP
    -- =========================
    writeLine("== QUICKHEAL PALADIN ==")
    writeLine(" ")
    writeLine("Basic usage:")
    writeLine("/qh [target] [type] [mode]")
    writeLine(" ")
    writeLine("Targets:")
    writeLine(" player | target | targettarget | party | mt | nonmt | subgroup")
    writeLine(" ")
    writeLine("Types:")
    writeLine(" heal  - Smart heal (HL or FL via slider)")
    writeLine(" hl    - Force Holy Light")
    writeLine(" fl    - Force Flash of Light")
    writeLine(" hs    - Holy Shock")
    writeLine(" ")
    writeLine("Modes:")
    writeLine(" max   - Use highest rank available")
    writeLine(" ")
    writeLine("Examples:")
    writeLine("/qh              - Smart heal (slider decides HL or FL)")
    writeLine("/qh heal max     - Smart heal using max ranks")
    writeLine("/qh hl           - Force Holy Light (optimal rank)")
    writeLine("/qh hl max       - Force max rank Holy Light")
    writeLine("/qh fl           - Force Flash of Light (optimal rank)")
    writeLine("/qh fl max       - Force max rank Flash of Light")
    writeLine("/qh hs           - Holy Shock (optimal rank)")
    writeLine("/qh hs max       - Holy Shock max rank")
    writeLine("/qh target hl    - Holy Light on target")
    writeLine("/qh target fl max - Max Flash of Light on target")
    writeLine(" ")
    writeLine("Settings:")
    writeLine("/qh cfg              - Open configuration panel")
    writeLine("/qh toggle           - Toggle heal threshold mode (slider)")
    writeLine("/qh downrank | dr    - Limit usable spell ranks")
    writeLine("/qh tanklist | tl    - Toggle main tank list")
    writeLine("/qh reset            - Reset all settings")
    writeLine(" ")
    writeLine("Debug:")
    writeLine("/qh test on|off      - Test mode (ignore HP thresholds)")
    writeLine("/qh debug on|off     - Debug logs")
    writeLine("/qh dll              - DLL status report")
end
