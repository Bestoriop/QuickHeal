-- SWNPCompat.lua — SuperWoW + NamPower helpers for WoW 1.12 (Lua 5.0 safe)

local SWNP = {}

-- Feature flags
SWNP.hasSW = (type(SUPERWOW_VERSION) == "string")
             or (type(SpellInfo) == "function")
             or (type(GetSpellNameAndRankForId) == "function")
SWNP.hasNP = (type(GetNampowerVersion) == "function")
             or (type(CastSpellByNameNoQueue) == "function")

-----------------------------------------------------------------------
-- Safe wrappers: guard SuperWoW functions so bad ids never hard-error
-----------------------------------------------------------------------
do
  -- GetSpellNameAndRankForId(id) -> name, "Rank X"
  local orig_GetSpellNameAndRankForId = GetSpellNameAndRankForId
  if type(orig_GetSpellNameAndRankForId) == "function" then
    GetSpellNameAndRankForId = function(id)
      local ok, n, r = pcall(orig_GetSpellNameAndRankForId, id)
      if ok and n then return n, r end
      return nil, nil
    end
  end

  -- SpellInfo(id) -> name, "Rank X", texture, minRange, maxRange
  local orig_SpellInfo = SpellInfo
  if type(orig_SpellInfo) == "function" then
    SpellInfo = function(id)
      local ok, n, r, t, minR, maxR = pcall(orig_SpellInfo, id)
      if ok and n then return n, r, t, minR, maxR end
      return nil, nil, nil, nil, nil
    end
  end
end

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

-- "Name(Rank X)" from global spell id or spellbook slot
local function _label_for_id(id)
  if type(GetSpellNameAndRankForId) == "function" then
    local n, r = GetSpellNameAndRankForId(id)
    if n then
      if r and r ~= "" then return n .. "(" .. r .. ")" else return n end
    end
  end
  if type(SpellInfo) == "function" then
    local n, r = SpellInfo(id)
    if n then
      if r and r ~= "" then return n .. "(" .. r .. ")" else return n end
    end
  end
  if type(GetSpellName) == "function" then
    local n, r = GetSpellName(id, BOOKTYPE_SPELL)
    if n then
      if r and r ~= "" then return n .. "(" .. r .. ")" else return n end
    end
  end
  return nil
end

-- Resolve a spell **slot** and **book** from:
--  - a spellbook slot index (1..#spellbook)
--  - OR a global spell id (via name → slot lookup)
local function _resolve_slot_and_book(id)
  -- If it's already a valid spellbook slot, take it
  if type(GetSpellName) == "function" then
    local n = GetSpellName(id, BOOKTYPE_SPELL)
    if n then
      return id, BOOKTYPE_SPELL
    end
  end

  -- Otherwise, try via label/name using NP's helper (preferred)
  local label = _label_for_id(id)
  if label and type(GetSpellSlotTypeIdForName) == "function" then
    local slot, bookType = GetSpellSlotTypeIdForName(label)
    if slot and slot > 0 and (bookType == "spell" or bookType == BOOKTYPE_SPELL) then
      return slot, BOOKTYPE_SPELL
    end
    -- Try without rank if first attempt failed
    -- Extract base name if it was "Name(Rank X)"
    local base = string.gsub(label, "%(Rank%s*%d+%)", "")
    if base ~= label then
      local slot2, bookType2 = GetSpellSlotTypeIdForName(base)
      if slot2 and slot2 > 0 and (bookType2 == "spell" or bookType2 == BOOKTYPE_SPELL) then
        return slot2, BOOKTYPE_SPELL
      end
    end
  end

  -- Last resort: brute-force scan of spellbook (kept tiny & safe)
  if type(GetSpellName) == "function" then
    local i = 1
    while true do
      local n, r = GetSpellName(i, BOOKTYPE_SPELL)
      if not n then break end
      -- Compare against both "Name" and "Name(Rank X)"
      local want = _label_for_id(id)
      if want then
        if want == n or string.find(want, "^" .. string.gsub(n, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")) then
          return i, BOOKTYPE_SPELL
        end
      end
      i = i + 1
    end
  end

  return nil, nil
end

-- Basic GUID detection
local function _looks_like_guid(s)
  return type(s) == "string" and (string.find(s, "^0x") or string.find(s, "^[%x]+$"))
end

-----------------------------------------------------------------------
-- Patch global probes so QuickHeal can pass spellbook indices safely
-----------------------------------------------------------------------
do
  -- IsSpellUsable(idOrLabel) -> usable(1/0), oom(1/0)
  local orig_IsSpellUsable = IsSpellUsable
  if type(orig_IsSpellUsable) == "function" then
    IsSpellUsable = function(arg1)
      local ok, u, oom = pcall(orig_IsSpellUsable, arg1)
      if ok then return u, oom end
      if type(arg1) == "number" then
        local label = _label_for_id(arg1)
        if label then
          local ok2, u2, oom2 = pcall(orig_IsSpellUsable, label)
          if ok2 then return u2, oom2 end
        end
      end
      return 1, 0
    end
  end

  -- IsSpellInRange(idOrLabel, unit) -> 1(in) / 0(out) / -1(n/a)
  local orig_IsSpellInRange = IsSpellInRange
  if type(orig_IsSpellInRange) == "function" then
    IsSpellInRange = function(arg1, unit)
      local ok, r = pcall(orig_IsSpellInRange, arg1, unit)
      if ok then return r end
      if type(arg1) == "number" then
        local label = _label_for_id(arg1)
        if label then
          local ok2, r2 = pcall(orig_IsSpellInRange, label, unit)
          if ok2 then return r2 end
        end
      end
      return 1
    end
  end
end

-----------------------------------------------------------------------
-- Public helpers used by QuickHeal
-----------------------------------------------------------------------

-- Player GUID (SuperWoW: UnitExists returns exists,guid)
local _player_guid_cached
function SWNP.PlayerGUID()
  if _player_guid_cached then return _player_guid_cached end
  if type(UnitExists) == "function" then
    local _, g = UnitExists("player")
    if type(g) == "string" and g ~= "" then
      _player_guid_cached = g
      return g
    end
  end
end

-- Return a GUID for unit or pass-through if already a GUID
function SWNP.UnitGUID(unit_or_guid)
  if _looks_like_guid(unit_or_guid) then return unit_or_guid end
  if type(UnitExists) == "function" and unit_or_guid then
    local _, g = UnitExists(unit_or_guid)
    if type(g) == "string" and g ~= "" then return g end
  end
end

-- Convert id/spellbook slot to "Name(Rank X)" label
function SWNP.LabelForId(id)
  return _label_for_id(id) or tostring(id)
end

-- Robust cast by id (global id or spellbook slot) onto unit/guid.
-- Strategy: resolve to spellbook slot → CastSpell(slot, "spell") → SpellTargetUnit(unit/guid)
function SWNP.CastByIdOnUnit(id, unit_or_guid)
  -- Resolve to a spellbook slot
  local slot, book = _resolve_slot_and_book(id)
  if not slot or book ~= BOOKTYPE_SPELL then
    -- As a very last ditch, try SuperWoW name cast (may fail silently)
    local label = _label_for_id(id)
    if label and type(CastSpellByName) == "function" and SWNP.hasSW then
      -- Prefer no-queue if NP is present
      if SWNP.hasNP and type(CastSpellByNameNoQueue) == "function" then
        return CastSpellByNameNoQueue(label, unit_or_guid)
      else
        return CastSpellByName(label, unit_or_guid)
      end
    end
    return
  end

  -- Clean any previous targeting
  if type(SpellIsTargeting) == "function" and SpellIsTargeting() then
    SpellStopTargeting()
  end

  -- Cast from spellbook (always reliable in 1.12)
  if type(CastSpell) == "function" then
    CastSpell(slot, BOOKTYPE_SPELL)
  end

  -- Target the desired unit (unit token or GUID both supported on SW)
  if type(SpellIsTargeting) == "function" and SpellIsTargeting() then
    -- If SpellCanTargetUnit exists and says no, abort cleanly
    if type(SpellCanTargetUnit) == "function" then
      local ok = SpellCanTargetUnit(unit_or_guid)
      if ok == 0 then
        SpellStopTargeting()
        return
      end
    end

    -- Try direct targeting
    local before = 1
    if type(SpellIsTargeting) == "function" then
      before = SpellIsTargeting() and 1 or 0
    end

    if type(SpellTargetUnit) == "function" then
      SpellTargetUnit(unit_or_guid)
    end

    -- If still in targeting mode, try mouseover bridge (for GUID edge-cases)
    if type(SpellIsTargeting) == "function" and SpellIsTargeting() then
      if type(SetMouseoverUnit) == "function" then
        SetMouseoverUnit(unit_or_guid)
        SpellTargetUnit("mouseover")
        SetMouseoverUnit()
      end
    end

    -- If STILL targeting, give up gracefully
    if type(SpellIsTargeting) == "function" and SpellIsTargeting() then
      SpellStopTargeting()
    end
  end
end

_G.SWNP = SWNP
