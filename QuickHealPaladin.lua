-- QuickHeal Paladin Module (Refactored) 
-- Consolidated spell selection with shared helper functions
local function writeLine(s, r, g, b)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(s, r or 1, g or 1, b or 0.5)
    end
end
-- Penalty Factors for low-level spells
local PF = {
    [1] = 0.2875,
    [6] = 0.475,
    [14] = 0.775,
}
function QuickHeal_Paladin_GetRatioHealthyExplanation()
    local RatioHealthy = QuickHeal_GetRatioHealthy()
    local RatioFull = QuickHealVariables["RatioFull"]
    if RatioHealthy >= RatioFull then
        return QUICKHEAL_SPELL_HOLY_LIGHT .. " will always be preferred if no " ..
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
-- Calculate all Paladin-specific modifiers
local function GetPaladinModifiers()
    local mods = {}
    -- Equipment healing bonus (cached)
    mods.bonus = QuickHeal_GetEquipmentBonus()
    -- Calculate healing modifiers by cast time
    mods.healMod15 = (1.5 / 3.5) * mods.bonus
    mods.healMod25 = (2.5 / 3.5) * mods.bonus
    -- Healing Light Talent - increases healing by 4% per rank
    local hlRank = QuickHeal_GetTalentRank(1, 5)
    mods.hlMod = 1 + 4 * hlRank / 100
    -- Holy Power Talent - increases Holy Spell crit chance by 1% per rank (crit is 50% bonus so 0.5 bonus per rank)
    local dfRank = QuickHeal_GetTalentRank(1, 13)
    mods.hpMod = 1 + 0.5 * dfRank / 100
    return mods
end
-- Check for Paladin-specific buffs that affect healing
-- Returns: forceHL flag
local function CheckPaladinBuffs()
    local forceHL = false
    local forceMaxHPS = false
    if QuickHeal_DetectBuff('player', "Spell_Holy_SearingLight$") and
       not QuickHeal_DetectBuff('player', "Spell_Holy_SearingLightPriest") then
        QuickHeal_debug("BUFF: Hand of Edward the Odd (texture fallback, HL forced)")
        forceHL = true
    end
    if QuickHeal_DetectBuff('player', "Spell_Holy_Heal$") then
        QuickHeal_debug("BUFF: Divine Favor detected, forceMaxHPS enabled")
        forceMaxHPS = true
    end
    return forceHL, forceMaxHPS
end

-- Unified heal spell selection (works with or without target)
-- target: unit ID or nil (for NoTarget mode)
-- maxhealth, healDeficit, hdb, incombat: used when target is nil
function QuickHeal_Paladin_FindSpellToUse(target, healType, multiplier, forceMaxHPS, maxhealth, healDeficit, hdb,
                                          incombat)
    local SpellID = nil
    local HealSize = 0
    multiplier = multiplier or 1
    local RatioFull = QuickHealVariables["RatioFull"]
    local RatioHealthy = QuickHeal_GetRatioHealthy()
    local debug = QuickHeal_debug
    -- Get health info
    local healneed, Health, HDB
    if target then
        if QuickHeal_UnitHasHealthInfo(target) and QH_GetUnitMaxHealth(target) > 0 then
            healneed = QH_GetUnitMaxHealth(target) - QH_GetUnitHealth(target)
            if multiplier > 1.0 then
                healneed = healneed * multiplier
            end
            Health = QH_GetUnitHealth(target) / QH_GetUnitMaxHealth(target)
        else
            healneed = QuickHeal_EstimateUnitHealNeed(target, true)
            if multiplier > 1.0 then
                healneed = healneed * multiplier
            end
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
    if target == nil and maxhealth == nil then
        return nil, 0
    end
    debug("Target debuff healing modifier", HDB)
    healneed = healneed / HDB
    if healneed <= 0 then return nil, 0 end
    if multiplier and multiplier > 1.0 then
        jgpprint(">>> multiplier is " .. multiplier .. " <<<")
    end
    -- Get modifiers
    local mods = GetPaladinModifiers()
    local ManaLeft = QH_GetUnitMana('player')
    -- Check buffs
    local ForceHL, BuffForceMaxHPS = CheckPaladinBuffs()
    forceMaxHPS = forceMaxHPS or BuffForceMaxHPS
    -- Get spell IDs
    local SpellIDsHL = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HOLY_LIGHT)
    local SpellIDsFL = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_FLASH_OF_LIGHT)
    local maxRankHL = table.getn(SpellIDsHL)
    local maxRankFL = table.getn(SpellIDsFL)
    local NoFL = maxRankFL < 1
    debug(string.format("Found HL up to rank %d, and found FL up to rank %d", maxRankHL, maxRankFL))
    -- Downrank settings
    local downRankFH = QuickHealVariables.DownrankValueFH or 0
    local downRankNH = QuickHealVariables.DownrankValueNH or 0
    local minRankFH = QuickHealVariables.MinrankValueFH or 1
    local minRankNH = QuickHealVariables.MinrankValueNH or 1
    -- Combat multipliers
    local k, K = QuickHeal_GetCombatMultipliers(incombat)
    local TargetIsHealthy = Health >= RatioHealthy
    local hlMod = mods.hlMod
    local hpMod = mods.hpMod
    local healMod15, healMod25 = mods.healMod15, mods.healMod25
    if TargetIsHealthy then
        debug("Target is healthy", Health)
    end
    if not (Health < RatioFull or QHV.TestMode or not target or (QHV.PrecastAggro and QuickHeal_UnitHasAggro(target))) then
        return nil, 0
    end
    -- Calcul du heal max que FL peut fournir (rank max disponible)
    local maxFLHeal = 0
    if maxRankFL >= 6 and SpellIDsFL[6] then
        maxFLHeal = (348 * hlMod + healMod15) * hpMod
    elseif maxRankFL >= 5 and SpellIDsFL[5] then
        maxFLHeal = (278 * hlMod + healMod15) * hpMod
    elseif maxRankFL >= 4 and SpellIDsFL[4] then
        maxFLHeal = (206 * hlMod + healMod15) * hpMod
    elseif maxRankFL >= 3 and SpellIDsFL[3] then
        maxFLHeal = (153 * hlMod + healMod15) * hpMod
    elseif maxRankFL >= 2 and SpellIDsFL[2] then
        maxFLHeal = (102 * hlMod + healMod15) * hpMod
    elseif maxRankFL >= 1 and SpellIDsFL[1] then
        maxFLHeal = (67 * hlMod + healMod15) * hpMod
    end
    -- FL couvre le besoin si son heal max >= healneed (healneed est déjà divisé par HDB)
    local FLCoversNeed = (maxRankFL >= 1) and (maxFLHeal >= healneed)
    -- NoFL force HL directement (paladin a toujours HL rank 1, FL est appris plus tard)
    -- Sinon HL-priority si target unhealthy, ForceHL buff, ou forceMaxHPS, SAUF si FL couvre le besoin
    local useHLPriority = NoFL or ((forceMaxHPS or ForceHL or not TargetIsHealthy) and not FLCoversNeed)
    debug(string.format("FLCoversNeed=%s useHLPriority=%s maxFLHeal=%.0f healneed=%.0f",
        tostring(FLCoversNeed), tostring(useHLPriority), maxFLHeal, healneed))
    if useHLPriority then
        -- HL-priority: escalade HL pure uniquement (ranks 1→9)
        -- En forceMaxHPS: on ignore healneed, on prend le max rank affordable
        if maxRankHL >= 1 and SpellIDsHL[1] then
            SpellID = SpellIDsHL[1]; HealSize = (43 * hlMod + healMod25 * PF[1]) * hpMod
        end
        if (forceMaxHPS or healneed > (83 * hlMod + healMod25 * PF[6]) * hpMod * K or 2 <= minRankNH) and ManaLeft >= 60 and maxRankHL >= 2 and downRankNH >= 2 and SpellIDsHL[2] then
            SpellID = SpellIDsHL[2]; HealSize = (83 * hlMod + healMod25 * PF[6]) * hpMod
        end
        if (forceMaxHPS or healneed > (173 * hlMod + healMod25 * PF[14]) * hpMod * K or 3 <= minRankNH) and ManaLeft >= 110 and maxRankHL >= 3 and downRankNH >= 3 and SpellIDsHL[3] then
            SpellID = SpellIDsHL[3]; HealSize = (173 * hlMod + healMod25 * PF[14]) * hpMod
        end
        if (forceMaxHPS or healneed > (333 * hlMod + healMod25) * hpMod * K or 4 <= minRankNH) and ManaLeft >= 190 and maxRankHL >= 4 and downRankNH >= 4 and SpellIDsHL[4] then
            SpellID = SpellIDsHL[4]; HealSize = (333 * hlMod + healMod25) * hpMod
        end
        if (forceMaxHPS or healneed > (522 * hlMod + healMod25) * hpMod * K or 5 <= minRankNH) and ManaLeft >= 275 and maxRankHL >= 5 and downRankNH >= 5 and SpellIDsHL[5] then
            SpellID = SpellIDsHL[5]; HealSize = (522 * hlMod + healMod25) * hpMod
        end
        if (forceMaxHPS or healneed > (739 * hlMod + healMod25) * hpMod * K or 6 <= minRankNH) and ManaLeft >= 365 and maxRankHL >= 6 and downRankNH >= 6 and SpellIDsHL[6] then
            SpellID = SpellIDsHL[6]; HealSize = (739 * hlMod + healMod25) * hpMod
        end
        if (forceMaxHPS or healneed > (999 * hlMod + healMod25) * hpMod * K or 7 <= minRankNH) and ManaLeft >= 465 and maxRankHL >= 7 and downRankNH >= 7 and SpellIDsHL[7] then
            SpellID = SpellIDsHL[7]; HealSize = (999 * hlMod + healMod25) * hpMod
        end
        if (forceMaxHPS or healneed > (1317 * hlMod + healMod25) * hpMod * K or 8 <= minRankNH) and ManaLeft >= 580 and maxRankHL >= 8 and downRankNH >= 8 and SpellIDsHL[8] then
            SpellID = SpellIDsHL[8]; HealSize = (1317 * hlMod + healMod25) * hpMod
        end
        if (forceMaxHPS or healneed > (1680 * hlMod + healMod25) * hpMod * K or 9 <= minRankNH) and ManaLeft >= 660 and maxRankHL >= 9 and downRankNH >= 9 and SpellIDsHL[9] then
            SpellID = SpellIDsHL[9]; HealSize = (1680 * hlMod + healMod25) * hpMod
        end
    else
        -- FL-priority: target healthy, ou FL suffit pour couvrir healneed
        -- Si on est ici, maxRankFL >= 1 est garanti (NoFL aurait déclenché useHLPriority)
        if SpellIDsFL[1] then
            SpellID = SpellIDsFL[1]; HealSize = (67 * hlMod + healMod15) * hpMod
        end
        if (healneed > (102 * hlMod + healMod15) * hpMod * k or 2 <= minRankFH) and ManaLeft >= 50 and maxRankFL >= 2 and downRankFH >= 2 and SpellIDsFL[2] then
            SpellID = SpellIDsFL[2]; HealSize = (102 * hlMod + healMod15) * hpMod
        end
        if (healneed > (153 * hlMod + healMod15) * hpMod * k or 3 <= minRankFH) and ManaLeft >= 70 and maxRankFL >= 3 and downRankFH >= 3 and SpellIDsFL[3] then
            SpellID = SpellIDsFL[3]; HealSize = (153 * hlMod + healMod15) * hpMod
        end
        if (healneed > (206 * hlMod + healMod15) * hpMod * k or 4 <= minRankFH) and ManaLeft >= 90 and maxRankFL >= 4 and downRankFH >= 4 and SpellIDsFL[4] then
            SpellID = SpellIDsFL[4]; HealSize = (206 * hlMod + healMod15) * hpMod
        end
        if (healneed > (278 * hlMod + healMod15) * hpMod * k or 5 <= minRankFH) and ManaLeft >= 115 and maxRankFL >= 5 and downRankFH >= 5 and SpellIDsFL[5] then
            SpellID = SpellIDsFL[5]; HealSize = (278 * hlMod + healMod15) * hpMod
        end
        if (healneed > (348 * hlMod + healMod15) * hpMod * k or 6 <= minRankFH) and ManaLeft >= 140 and maxRankFL >= 6 and downRankFH >= 6 and SpellIDsFL[6] then
            SpellID = SpellIDsFL[6]; HealSize = (348 * hlMod + healMod15) * hpMod
        end
    end
    return SpellID, HealSize * HDB
end

-- NoTarget wrapper for backwards compatibility
function QuickHeal_Paladin_FindHealSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxHPS,
                                                      forceMaxRank, hdb, incombat)
    return QuickHeal_Paladin_FindSpellToUse(nil, healType, multiplier, forceMaxHPS, maxhealth, healDeficit, hdb, incombat)
end

-- Unified HoT/Holy Shock spell selection
function QuickHeal_Paladin_FindHoTSpellToUse(target, healType, forceMaxRank, maxhealth, healDeficit, hdb, incombat)
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
    else
        if not healDeficit or healDeficit <= 0 then
            return nil, 0
        end
        healneed = healDeficit * 1
        Health = 1 - (healDeficit / maxhealth)
        HDB = hdb or 1
    end

    debug("Target debuff healing modifier", HDB)
    healneed = healneed / HDB

    -- Return if no target
    if target == nil and maxhealth == nil then
        return nil, 0
    end

    -- Get modifiers
    local mods = GetPaladinModifiers()
    local ManaLeft = QH_GetUnitMana('player')

    -- Get Holy Shock spell IDs
    local SpellIDsHS = QuickHeal_GetSpellIDs(QUICKHEAL_SPELL_HOLY_SHOCK)
    local maxRankHS = table.getn(SpellIDsHS)

    debug(string.format("Found HS up to rank %d", maxRankHS))

    -- Check if Holy Shock is on cooldown (Nampower)
    if maxRankHS >= 1 and GetSpellIdForName then
        local ok, dbcId = pcall(GetSpellIdForName, QUICKHEAL_SPELL_HOLY_SHOCK)
        if ok and dbcId and QH_IsSpellOnCooldown(dbcId) then
            debug("Holy Shock is on cooldown, skipping")
            return nil, 0
        end
    end

    local hlMod = mods.hlMod
    local hpMod = mods.hpMod
    local healMod15 = mods.healMod15

    local TargetIsHealthy = Health >= RatioHealthy
    if TargetIsHealthy then
        debug("Target is healthy", Health)
    end

    QuickHeal_debug(string.format(
        "healneed: %f  target: %s  healType: %s  forceMaxRank: %s",
        healneed, tostring(target), tostring(healType), tostring(forceMaxRank)
    ))

    if forceMaxRank then
        -- Force max rank
        if maxRankHS >= 1 then
            SpellID = SpellIDsHS[maxRankHS]
            HealSize = (381* hlMod + healMod15) * hpMod
        end
    else
        -- Select rank based on healneed
        SpellID = SpellIDsHS[1]; HealSize = (213 + healMod15) * hlMod * hpMod
        if healneed > (291 + healMod15) * hlMod * hpMod and ManaLeft >= 275 and maxRankHS >= 2 and SpellIDsHS[2] then
            SpellID = SpellIDsHS[2]; HealSize = (291 + healMod15) * hpMod
        end
        if healneed > (381 + healMod15) * hlMod * hpMod and ManaLeft >= 325 and maxRankHS >= 3 and SpellIDsHS[3] then
            SpellID = SpellIDsHS[3]; HealSize = (381 + healMod15) * hpMod
        end
    end

    return SpellID, HealSize * HDB
end

-- NoTarget wrapper for backwards compatibility
function QuickHeal_Paladin_FindHoTSpellToUseNoTarget(maxhealth, healDeficit, healType, multiplier, forceMaxHPS,
                                                     forceMaxRank, hdb, incombat)
    return QuickHeal_Paladin_FindHoTSpellToUse(nil, healType, forceMaxRank, maxhealth, healDeficit, hdb, incombat)
end

-- Command handler
function QuickHeal_Command_Paladin(msg)
    local _, _, arg1, arg2, arg3 = string.find(msg, "%s?(%w+)%s?(%w+)%s?(%w+)")
    -- Match 3 arguments
    if arg1 and arg2 and arg3 then
        if arg1 == "player" or arg1 == "target" or arg1 == "targettarget" or arg1 == "party" or arg1 == "subgroup" or arg1 == "mt" or arg1 == "nonmt" then
            if arg2 == "heal" and arg3 == "max" then
                QuickHeal(arg1, nil, nil, true)
                return
            end
            if arg2 == "hs" and arg3 == "max" then
                QuickHOT(arg1, nil, nil, true, false)
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
        if arg4 == "heal" and arg5 == "max" then
            QuickHeal(nil, nil, nil, true)
            return
        end
        if arg4 == "hs" and arg5 == "max" then
            QuickHOT(nil, nil, nil, true, false)
            return
        end
        if arg4 == "player" or arg4 == "target" or arg4 == "targettarget" or arg4 == "party" or arg4 == "subgroup" or arg4 == "mt" or arg4 == "nonmt" then
            if arg5 == "hs" then
                QuickHOT(arg4, nil, nil, false, false)
                return
            end
            if arg5 == "heal" then
                QuickHeal(arg4, nil, nil, false)
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
    if cmd == "heal" then
        QuickHeal(nil, nil, nil, false)
        return
    end
    if cmd == "hs" then
        QuickHOT()
        return
    end
    if cmd == "hot" then
        writeLine("The command /qh hot is disabled for paladins. Use /qh hs instead.", 1, 0, 0)
        return
    end
    if cmd == "" then
        QuickHeal(nil, nil, nil, false)
        return
    elseif cmd == "player" or cmd == "target" or cmd == "targettarget" or cmd == "party" or cmd == "subgroup" or cmd == "mt" or cmd == "nonmt" then
        QuickHeal(cmd, nil, nil, false)
        return
    end
    -- =========================
    -- Help
    -- =========================
    writeLine("== QUICKHEAL PALADIN ==")

    writeLine(" ")
    writeLine("Basic usage:")
    writeLine("/qh [target] [type] [mode]")

    writeLine("Targets:")
    writeLine(" player | target | targettarget | party | mt | nonmt | subgroup")

    writeLine("Types:")
    writeLine(" heal  - Smart heal from slider logic")
    writeLine(" hs    - Holy Shock")

    writeLine("Modes:")
    writeLine(" max   - Force max rank (for HL or HS)")

    writeLine(" ")
    writeLine("Examples:")
    writeLine("/qh              - Auto: HL if unhealthy, or FL")
    writeLine("/qh heal         - Same")
    writeLine("/qh heal max     - HL max rank")
    writeLine("/qh hs           - Holy Shock auto")
    writeLine("/qh hs max       - Holy Shock max rank")
    writeLine("/qh target heal  - Heal on target")
    writeLine("/qh target heal max - Force HL max on target")
    writeLine("/qh target hs max   - HS max on target")

    writeLine(" ")
    writeLine("Settings:")
    writeLine("/qh cfg              - Open config")
    writeLine("/qh toggle           - Toggle slider HL/FL (RatioHealthy)")
    writeLine("/qh downrank | dr    - Force downrank")
    writeLine("/qh tanklist | tl    - Toggle tank list")
    writeLine("/qh reset            - Reset settings")

    writeLine(" ")
    writeLine("Other:")
    writeLine("/qh test on|off      - Test mode")
    writeLine("/qh debug on|off     - Debug mode")
    writeLine("/qh dll              - DLL status")
end
