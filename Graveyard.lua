



function QuickHoTSingle(playerName, forceMaxRank)

    local _, class = UnitClass('player');
    class = string.lower(class);
    if class == "druid" then
        --
    elseif class == "paladin" then
        return;
    elseif class == "priest" then
        --
    elseif class == "shaman" then
        return;
    end

    -- Only one instance of QuickHeal allowed at a time
    if QuickHealBusy then
        if HealingTarget and MassiveOverhealInProgress then
            QuickHeal_debug("Massive overheal aborted.");
            SpellStopCasting();
        else
            QuickHeal_debug("Healing in progress, command ignored");
        end
        return ;
    end

    QuickHealBusy = true;
    local AutoSelfCast = GetCVar("autoSelfCast");
    SetCVar("autoSelfCast", 0);

    -- Protect against invalid extParam
    if not (type(extParam) == "table") then
        extParam = {}
    end

    Target = FindSingleToHOT(playerName);

    --QuickHeal_debug("********** BREAKPOINT: Well, we got this far. **********");
    --QuickHeal_debug(string.format("  Healing target grr:  (%s)",  Target));
    QuickHeal_debug(string.format("  Healing target grr: " .. tostring(Target)));

    if (Target == nil) or (Target == false) then
        jgpprint("ain't nobody to heal dude")
        SetCVar("autoSelfCast", AutoSelfCast);
        QuickHealBusy = false;
        return;
    end

    -- Target acquired
    --QuickHeal_debug(string.format("  Healing target: %s (%s)", UnitFullName(Target), Target));

    HealingSpellSize = 0;

    SpellID, HealingSpellSize = FindHoTSpellToUse(Target, "hot", forceMaxRank);

    if (SpellID == nil) then
        --jgpprint("ain't nobody to heal dude")
        SetCVar("autoSelfCast", AutoSelfCast);
        QuickHealBusy = false;
        return;
    end

    if SpellID then
        ExecuteHOT(Target, SpellID);
        QuickHealBusy = false;
    else
        Message("You have no healing spells to cast", "Error", 2);
    end

    SetCVar("autoSelfCast", AutoSelfCast);
end

function FindSingleToHOT(playerName)
    local playerIds = {};
    local petIds = {};
    local i;
    local AllPlayersAreFull = true;
    local AllPetsAreFull = true;

    QuickHeal_debug("********** HoT Single **********");

    local healingTarget = nil;
    local healingTargetHealth = 100000;
    local healingTargetHealthPct = 1;
    local healingTargetMissinHealth = 0;
    local unit;

    --jgpprint("forceApplication == " .. tostring(forceApplication))

    if (InRaid()) then
        for i = 1, GetNumRaidMembers() do
            if UnitIsHealable("raid" .. i, true) then
                jgpprint("considering raid" .. i .. ":" .. UnitName("raid" .. i))
                if IsSingleTarget("raid" .. i, playerName) then
                    --if not UnitHasRenew("raid" .. i) then
                    --jgpprint("AAAAAAAAAAAAAAAAAAAAAAAAAA" .. UnitName("raid" .. i) .. " doesn't have renew.")
                    --playerIds["raid" .. i] = i;
                    healingTarget = "raid" .. i;
                    --end
                    --elseif forceApplication then
                    --    healingTarget = "raid" .. i;
                    --end

                    --healingTarget = "raid" .. 1;
                    --return healingTarget;

                    jgpprint(UnitName("raid" .. i) .. " :: " .. "raid" .. i)
                end
            end
        end
    else
        for i = 1, GetNumPartyMembers() do
            if UnitIsHealable("party" .. i, true) then
                if IsSingleTarget("party" .. i, playerName) then
                    --playerIds["party" .. i] = i;
                    --if not UnitHasRenew("party" .. i) then
                    healingTarget = "party" .. i;
                    --end

                    jgpprint(UnitName("party" .. i))
                end
            end
        end
    end

    --QuickHeal_debug("********** Done Scanning for single-target HoT **********");

    -- Clear any healable target
    local OldPlaySound = PlaySound;
    PlaySound = function()
    end
    local TargetWasCleared = false;
    if UnitIsHealable('target') then
        TargetWasCleared = true;
        ClearTarget();
    end

    --QuickHeal_debug("********** in the middle **********");

    -- Cast the checkspell
    local ok = CastCheckSpellHOT();
    if not (ok or SpellIsTargeting()) then
        -- Reacquire target if it was cleared
        if TargetWasCleared then
            TargetLastTarget();
        end
        -- Reinsert the PlaySound
        PlaySound = OldPlaySound;
        return false;
    end

    --QuickHeal_debug("********** And then this happens **********");

    -- Examine Healable Players
    --for unit, i in playerIds do
    --    QuickHeal_debug(string.format("%s (%s) : %d/%d", UnitFullName(unit), unit, UnitHealth(unit), UnitHealthMax(unit)));
    --    local SubGroup = false;
    --    if InRaid() and not RestrictParty and RestrictSubgroup and i <= GetNumRaidMembers() then
    --        _, _, SubGroup = GetRaidRosterInfo(i);
    --    end
    --    if not RestrictSubgroup or RestrictParty or not InRaid() or (SubGroup and not QHV["FilterRaidGroup" .. SubGroup]) then
    --        if not IsBlacklisted(UnitFullName(unit)) then
    --            if SpellCanTargetUnit(unit) then
    --                QuickHeal_debug(string.format("%s (%s) : %d/%d", UnitFullName(unit), unit, UnitHealth(unit), UnitHealthMax(unit)));
    --
    --                --Get who to heal for different classes
    --                local IncHeal = HealComm:getHeal(UnitName(unit))
    --                local PredictedHealth = (UnitHealth(unit) + IncHeal)
    --                local PredictedHealthPct = (UnitHealth(unit) + IncHeal) / UnitHealthMax(unit);
    --                local PredictedMissingHealth = UnitHealthMax(unit) - UnitHealth(unit) - IncHeal;
    --
    --                if PredictedHealthPct < QHV.RatioFull then
    --                    local _, PlayerClass = UnitClass('player');
    --                    PlayerClass = string.lower(PlayerClass);
    --
    --                    --if PlayerClass == "shaman" then
    --                    --    if PredictedHealthPct < healingTargetHealthPct then
    --                    --        healingTarget = unit;
    --                    --        healingTargetHealthPct = PredictedHealthPct;
    --                    --        AllPlayersAreFull = false;
    --                    --    end
    --                    if PlayerClass == "priest" then
    --                        --writeLine("Find who to heal for Priest");
    --                        if healPlayerWithLowestPercentageOfLife == 1 then
    --                            if PredictedHealthPct < healingTargetHealthPct then
    --                                --if not UnitHasRenew(unit) then
    --                                    --QuickHeal_debug("********** Hot target don't got HoT **********");
    --                                    healingTarget = unit;
    --                                    healingTargetHealthPct = PredictedHealthPct;
    --                                    AllPlayersAreFull = false;
    --                                --else
    --                                --    QuickHeal_debug("********** Hot target got HoT **********");
    --                                --end
    --                            end
    --                        else
    --                            if PredictedMissingHealth > healingTargetMissinHealth then
    --                                --if not UnitHasRenew(unit) then
    --                                    --QuickHeal_debug("********** Hot target don't got HoT **********");
    --                                    healingTarget = unit;
    --                                    healingTargetMissinHealth = PredictedMissingHealth;
    --                                    AllPlayersAreFull = false;
    --                                --else
    --                                --    QuickHeal_debug("********** Hot target got HoT **********");
    --                                --end
    --                            end
    --                        end
    --                    --elseif PlayerClass == "paladin" then
    --                    --    --writeLine("Find who to heal for Paladin")
    --                    --    if healPlayerWithLowestPercentageOfLife == 1 then
    --                    --        if PredictedHealthPct < healingTargetHealthPct then
    --                    --            healingTarget = unit;
    --                    --            healingTargetHealthPct = PredictedHealthPct;
    --                    --            AllPlayersAreFull = false;
    --                    --        end
    --                    --    else
    --                    --        if PredictedHealth < healingTargetHealth then
    --                    --            healingTarget = unit;
    --                    --            healingTargetHealth = PredictedHealth;
    --                    --            AllPlayersAreFull = false;
    --                    --        end
    --                    --    end
    --                    elseif PlayerClass == "druid" then
    --                        if PredictedHealthPct < healingTargetHealthPct then
    --                            healingTarget = unit;
    --                            healingTargetHealthPct = PredictedHealthPct;
    --                            AllPlayersAreFull = false;
    --                        end
    --                    else
    --                        writeLine(QuickHealData.name .. " " .. QuickHealData.version .. " does not support " .. UnitClass('player') .. ". " .. QuickHealData.name .. " not loaded.")
    --                        return ;
    --                    end
    --                end
    --
    --
    --                --writeLine("Values for "..UnitName(unit)..":")
    --                --writeLine("Health: "..UnitHealth(unit) / UnitHealthMax(unit).." | IncHeal: "..IncHeal / UnitHealthMax(unit).." | PredictedHealthPct: "..PredictedHealthPct) --Edelete
    --            else
    --                QuickHeal_debug(UnitFullName(unit) .. " (" .. unit .. ")", "is out-of-range or unhealable");
    --            end
    --        else
    --            QuickHeal_debug(UnitFullName(unit) .. " (" .. unit .. ")", "is blacklisted");
    --        end
    --    end
    --end
    --healPlayerWithLowestPercentageOfLife = 0

    -- Reacquire target if it was cleared earlier, and stop CheckSpell
    SpellStopTargeting();
    if TargetWasCleared then
        TargetLastTarget();
    end
    PlaySound = OldPlaySound;

    ---- Examine External Target
    --if AllPlayersAreFull and (AllPetsAreFull or QHV.PetPriority == 0) then
    --    if not QuickHeal_UnitHasHealthInfo('target') and UnitIsHealable('target', true) then
    --        QuickHeal_debug(string.format("%s (%s) : %d/%d", UnitFullName('target'), 'target', UnitHealth('target'), UnitHealthMax('target')));
    --        local Health;
    --        Health = UnitHealth('target') / 100;
    --        if Health < QHV.RatioFull then
    --            return 'target';
    --        end
    --    end
    --end

    if UnitHasRenew(healingTarget) then
        healingTarget = nil;
    end


    return healingTarget;
end

function QuickHealSingle(playerName, multiplier)

    if multiplier == nil then
        multiplier = 1.0;
    end

    -- Only one instance of QuickHeal allowed at a time
    if QuickHealBusy then
        if HealingTarget and MassiveOverhealInProgress then
            QuickHeal_debug("Massive overheal aborted.");
            SpellStopCasting();
        else
            QuickHeal_debug("Healing in progress, command ignored");
        end
        return ;
    end

    QuickHealBusy = true;
    local AutoSelfCast = GetCVar("autoSelfCast");
    SetCVar("autoSelfCast", 0);

    -- Protect against invalid extParam
    if not (type(extParam) == "table") then
        extParam = {}
    end

    Target = FindSingleToHeal(playerName, multiplier);

    if (Target == nil) then
        --jgpprint("ain't nobody to heal dude")
        SetCVar("autoSelfCast", AutoSelfCast);
        QuickHealBusy = false;
        return;
    end

    -- Target acquired
    QuickHeal_debug(string.format("  Healing target: %s (%s)", UnitFullName(Target), Target));


    HealingSpellSize = 0;

    SpellID, HealingSpellSize = FindHealSpellToUse(Target, "channel", multiplier, nil);

    if (SpellID == nil) then
        --jgpprint("ain't nobody to heal dude")
        SetCVar("autoSelfCast", AutoSelfCast);
        QuickHealBusy = false;
        return;
    end

    -- Spell acquired
    QuickHeal_debug(string.format("  Spell & Size: %s (%s)", SpellID, HealingSpellSize));

    if SpellID then
        ExecuteSingleHeal(Target, SpellID, multiplier);
    else
        Message("You have no healing spells to cast", "Error", 2);
    end

    SetCVar("autoSelfCast", AutoSelfCast);
end

function FindSingleToHeal(playerName, multiplier)
    local playerIds = {};
    local petIds = {};
    local i;
    local AllPlayersAreFull = true;
    local AllPetsAreFull = true;

    QuickHeal_debug("********** Heal Single **********");

    local healingTarget = nil;
    local healingTargetHealth = 100000;
    local healingTargetHealthPct = 1;
    local healingTargetMissinHealth = 0;
    local unit;

    if (InRaid()) then
        for i = 1, GetNumRaidMembers() do
            if UnitIsHealable("raid" .. i, true) then
                jgpprint("considering raid" .. i .. ":" .. UnitName("raid" .. i))
                if IsSingleTarget("raid" .. i, playerName) then
                    --playerIds["raid" .. i] = i;  -- every one that will be considered for heal
                    healingTarget = "raid" .. i;
                    --jgpprint(UnitName("raid" .. i))
                end
            end
        end
    else
        for i = 1, GetNumPartyMembers() do
            if UnitIsHealable("party" .. i, true) then
                if IsSingleTarget("party" .. i, playerName) then
                    --playerIds["party" .. i] = i;  -- every one that will be considered for heal
                    healingTarget = "party" .. i;
                    --jgpprint(UnitName("party" .. i))
                end
            end
        end
    end



    QuickHeal_debug("********** Done Scanning for single-target Heal **********");

    -- Clear any healable target
    local OldPlaySound = PlaySound;
    PlaySound = function()
    end
    local TargetWasCleared = false;
    if UnitIsHealable('target') then
        TargetWasCleared = true;
        ClearTarget();
    end

    -- Cast the checkspell
    CastCheckSpell();
    if not SpellIsTargeting() then
        -- Reacquire target if it was cleared
        if TargetWasCleared then
            TargetLastTarget();
        end
        -- Reinsert the PlaySound
        PlaySound = OldPlaySound;
        return false;
    end

    --for unit, i in playerIds do
    --    local SubGroup = false;
    --    if InRaid() and not RestrictParty and RestrictSubgroup and i <= GetNumRaidMembers() then
    --        _, _, SubGroup = GetRaidRosterInfo(i);
    --    end
    --    if not RestrictSubgroup or RestrictParty or not InRaid() or (SubGroup and not QHV["FilterRaidGroup" .. SubGroup]) then
    --        if not IsBlacklisted(UnitFullName(unit)) then
    --            if SpellCanTargetUnit(unit) then
    --                QuickHeal_debug(string.format("%s (%s) : %d/%d", UnitFullName(unit), unit, UnitHealth(unit), UnitHealthMax(unit)));
    --
    --                --Get who to heal for different classes
    --                local IncHeal = HealComm:getHeal(UnitName(unit))
    --                local PredictedHealth = (UnitHealth(unit) + IncHeal)
    --                local PredictedHealthPct = (UnitHealth(unit) + IncHeal) / UnitHealthMax(unit);
    --                local PredictedMissingHealth = UnitHealthMax(unit) - UnitHealth(unit) - IncHeal;
    --
    --                if PredictedHealthPct < QHV.RatioFull then
    --                    local _, PlayerClass = UnitClass('player');
    --                    PlayerClass = string.lower(PlayerClass);
    --
    --                    if PlayerClass == "shaman" then
    --                        if PredictedHealthPct < healingTargetHealthPct then
    --                            healingTarget = unit;
    --                            healingTargetHealthPct = PredictedHealthPct;
    --                            AllPlayersAreFull = false;
    --                        end
    --                    elseif PlayerClass == "priest" then
    --                        --writeLine("Find who to heal for Priest");
    --                        if healPlayerWithLowestPercentageOfLife == 1 then
    --                            if PredictedHealthPct < healingTargetHealthPct then
    --                                healingTarget = unit;
    --                                healingTargetHealthPct = PredictedHealthPct;
    --                                AllPlayersAreFull = false;
    --                            end
    --                        else
    --                            if PredictedMissingHealth > healingTargetMissinHealth then
    --                                healingTarget = unit;
    --                                healingTargetMissinHealth = PredictedMissingHealth;
    --                                AllPlayersAreFull = false;
    --                            end
    --                        end
    --                    elseif PlayerClass == "paladin" then
    --                        --writeLine("Find who to heal for Paladin")
    --                        if healPlayerWithLowestPercentageOfLife == 1 then
    --                            if PredictedHealthPct < healingTargetHealthPct then
    --                                healingTarget = unit;
    --                                healingTargetHealthPct = PredictedHealthPct;
    --                                AllPlayersAreFull = false;
    --                            end
    --                        else
    --                            if PredictedHealth < healingTargetHealth then
    --                                healingTarget = unit;
    --                                healingTargetHealth = PredictedHealth;
    --                                AllPlayersAreFull = false;
    --                            end
    --                        end
    --                    elseif PlayerClass == "druid" then
    --                        if PredictedHealthPct < healingTargetHealthPct then
    --                            healingTarget = unit;
    --                            healingTargetHealthPct = PredictedHealthPct;
    --                            AllPlayersAreFull = false;
    --                        end
    --                    else
    --                        writeLine(QuickHealData.name .. " " .. QuickHealData.version .. " does not support " .. UnitClass('player') .. ". " .. QuickHealData.name .. " not loaded.")
    --                        return ;
    --                    end
    --                end
    --
    --
    --                --writeLine("Values for "..UnitName(unit)..":")
    --                --writeLine("Health: "..UnitHealth(unit) / UnitHealthMax(unit).." | IncHeal: "..IncHeal / UnitHealthMax(unit).." | PredictedHealthPct: "..PredictedHealthPct) --Edelete
    --            else
    --                QuickHeal_debug(UnitFullName(unit) .. " (" .. unit .. ")", "is out-of-range or unhealable");
    --            end
    --        else
    --            QuickHeal_debug(UnitFullName(unit) .. " (" .. unit .. ")", "is blacklisted");
    --        end
    --    end
    --end




    healPlayerWithLowestPercentageOfLife = 0



    -- Reacquire target if it was cleared earlier, and stop CheckSpell
    SpellStopTargeting();
    if TargetWasCleared then
        TargetLastTarget();
    end
    PlaySound = OldPlaySound;

    ---- Examine External Target
    --if AllPlayersAreFull and (AllPetsAreFull or QHV.PetPriority == 0) then
    --    if not QuickHeal_UnitHasHealthInfo('target') and UnitIsHealable('target', true) then
    --        QuickHeal_debug(string.format("%s (%s) : %d/%d", UnitFullName('target'), 'target', UnitHealth('target'), UnitHealthMax('target')));
    --        local Health;
    --        Health = UnitHealth('target') / 100;
    --        if Health < QHV.RatioFull then
    --            return 'target';
    --        end
    --    end
    --end

    return healingTarget;
end

-- Returns true if the unit matches playerName string
function IsSingleTarget(unit, playerName)
    if playerName == UnitName(unit) then
        return true;
    end
end

-- === Execute a single-target heal (SuperWoW/Nampower-native) ===
function ExecuteSingleHeal(Target, SpellID, multiplier)
    -- small local helpers
    local function SpellLabelFromId(id)
        if type(GetSpellNameAndRankForId) == "function" then
            local n, r = GetSpellNameAndRankForId(id)
            if n then return r and (n .. " (" .. r .. ")") or n end
        end
        if type(SpellInfo) == "function" then
            local n, r = SpellInfo(id) -- SuperWoW
            if n then return r and (n .. " (" .. r .. ")") or n end
        end
        if type(GetSpellName) == "function" then
            local n, r = GetSpellName(id, BOOKTYPE_SPELL)
            if r == "" then r = nil end
            if n then return r and (n .. " (" .. r .. ")") or n end
        end
        return tostring(id)
    end
    local function UnitFullNameSafe(unit)
        if type(UnitFullName) == "function" then return UnitFullName(unit) end
        return UnitName(unit)
    end
    local function HasSW() return (type(SUPERWOW_VERSION) == "string") or (type(SpellInfo) == "function") end

    local spellLabel = SpellLabelFromId(SpellID)

    -- your original behavior: start the cast monitor
    StartMonitor(Target, multiplier)

    -- prechecks (Nampower-aware if present)
    if type(IsSpellUsable) == "function" then
        local usable, oom = IsSpellUsable(SpellID)
        if usable ~= 1 then
            Message(oom == 1 and "Out of mana" or "Spell not usable right now", "Error", 2)
            StopMonitor("not usable")
            return
        end
    end
    if type(IsSpellInRange) == "function" then
        local r = IsSpellInRange(SpellID, Target) -- 1=in, 0=out, -1=not applicable
        if r == 0 then
            Message("Out of range", "Blacklist", 2)
            StopMonitor("out of range")
            return
        end
    end

    -- announce (preserves your UI messages)
    Notification(Target, spellLabel)
    if UnitIsUnit(Target, "player") then
        Message(string.format("Casting %s on yourself", spellLabel), "Healing", 3)
    else
        Message(string.format("Casting %s on %s", spellLabel, UnitFullNameSafe(Target) or Target), "Healing", 3)
    end

    -- cast: direct-to-unit on SuperWoW, vanilla fallback otherwise
    if type(CastSpellByName) == "function" and HasSW() then
        -- SuperWoW: 2nd arg is a UNIT token (or GUID) so no targeting mode needed
        CastSpellByName(spellLabel, Target)
    else
        -- vanilla fallback: minimal targeting-mode dance
        if type(SpellIsTargeting) == "function" and SpellIsTargeting() then SpellStopTargeting() end
        CastSpell(SpellID, BOOKTYPE_SPELL)
        if type(SpellIsTargeting) == "function" and SpellIsTargeting() then
            if type(SpellCanTargetUnit) ~= "function" or SpellCanTargetUnit(Target) then
                SpellTargetUnit(Target)
            else
                StopMonitor("Spell cannot target " .. (UnitFullNameSafe(Target) or "unit"))
                SpellStopTargeting()
            end
        end
    end
end
