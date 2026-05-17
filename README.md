# QuickHeal for octo wow

QuickHeal automates healing spell selection and targeting for healers. It finds the lowest health party or raid member, picks the best spell rank for the deficit and your mana, and casts it — no manual targeting required. Works with Priest, Druid, Paladin, and Shaman.

## Installation

Download QuickHeal into your `Interface/AddOns` folder. Ensure the folder is named `QuickHeal` (remove any `-octo` suffix).

## General Commands

| Command | Description |
|---------|-------------|
| `/qh` | Heal the lowest health target |
| `/qh cfg` | Open configuration panel |
| `/qh dr` or `/qh downrank` or `/qh ranks` | Open downrank/minrank slider window |
| `/qh toggle` | Toggle between Normal HPS and High HPS mode |
| `/qh tanklist` or `/qh tl` | Toggle main tank list display |
| `/qh dll` | Report DLL enhancement status |
| `/qh test on\|off` | Toggle test mode (ignores health thresholds) |
| `/qh debug on\|off` | Toggle debug output |
| `/qh reset` | Reset configuration to defaults |

### Heal Types

| Suffix | Effect |
|--------|--------|
| `heal` | Direct heal (default) |
| `hot` | HoT spell (Renew, Rejuvenation) |
| `hs` | Holy Shock for paladins |

### Modifiers

| Suffix | Effect |
|--------|--------|
| `max` | always use max rank regardless the healneed |
| `spam` | specific to HoT - Max Rank Spam ignoring HP check |

### Targets masks

Constrain who can be healed by adding a mask before the command:

| Mask | Targets |
|------|---------|
| `player` | Yourself only |
| `target` | Your current target |
| `targettarget` | Your target's target |
| `party` | Party members only |
| `subgroup` | Configured raid subgroups |
| `mt` | Main tanks only |
| `nonmt` | Non-tanks only |

Examples: 
`/qh mt` heals only tanks
`/qh party hot` casts a HoT on a party member.


### HPS Modes

**Normal HPS**: Uses the highest HPM spells (Lesser Heal / Heal / Greater Heal, Healing Touch, Flash of Light, Healing Wave) for mana efficiency.

**High HPS**: Restricted to High HPS spells (Flash Heal, Regrowth, Holy Light, Lesser Healing Wave) for maximum throughput at the cost of mana.

Toggle with `/qh toggle`.

---

## Priest

**Spells used**: Lesser Heal, Heal, Greater Heal, Flash Heal, Renew

### Recommended Macros

| Command | Description |
|---------|-------------|
| `/qh` or `/qh heal` | Optimal direct heal on lowest health target |
| `/qh gh` | Optimal Greater Heal (T2 8p bonus) |
| `/qh gh max` | Max rank Greater Heal |
| `/qh fl` | Optimal Flash Heal  |
| `/qh fl max` | Max rank Flash Heal  |
| `/qh hot` | Optimal Renew |
| `/qh hot max` | Max rank Renew  |
| `/qh hot spam` | Max rank Renew even if full HP |
| `/qh mt heal` | Optimal direct heal on MT only |

---

## Druid

**Spells used**: Healing Touch, Regrowth, Rejuvenation

### Recommended Macros

| Command | Description |
|---------|-------------|
| `/qh` or `/qh heal` | Optimal Healing Touch or Regrowth based on health threshold |
| `/qh heal max` | Max rank Healing Touch or Regrowth based on health threshold |
| `/qh ht` | Optimal Healing Touch only |
| `/qh ht max` | Max rank Healing Touch only |
| `/qh rg` | Optimal Regrowth only |
| `/qh rg max` | Max rank Regrowth only |
| `/qh hot` | Rejuvenation on lowest health target without an active HoT |
| `/qh hot max` | Rejuvenation Max rank on lowest health target without an active HoT |
| `/qh hot spam` | Rejuvenation Max rank Spam ignoring hp check |
| `/qh mt ht` | Optimal Healing Touch on mt only |

### Other useful Macros

```
/script QuickHeal(nil,'Swiftmend')
```
Cast Swiftmend (works while moving).

---

## Paladin

**Spells used**: Holy Light, Flash of Light, Holy Shock

### Recommended Macros

| Command | Description |
|---------|-------------|
| `/qh` or `/qh heal` | Optimal Holy Light or Flash of Light with slider logic |
| `/qh heal max` | Max rank Holy Light or Flash of Light with slider logic |
| `/qh hl` | Optimal Holy Light |
| `/qh hl max` | Max rank Holy Light |
| `/qh fl` | Optimal Flash of light |
| `/qh fl` | Max rank Flash of light |
| `/qh hs` | Optimal Holy Shock |
| `/qh hs max` | Max rank Holy Shock |
| `/qh mt heal` | Optimal HL or FL on mt only |

---

## Shaman

**Spells used**: Healing Wave, Lesser Healing Wave, Chain Heal

### Recommended Macros

| Command | Description |
|---------|-------------|
| `/qh` or `/qh heal` | Optimal Healing Wave or Lesser Healing Wave with slider logic |
| `/qh heal max` | Max Healing Wave or Lesser Healing Wave with slider logic  |
| `/qh hw` | Optimal Healing Wave |
| `/qh hw max` | Max rank Healing Wave |
| `/qh lhw` | Optimal Lesser Healing Wave |
| `/qh lhw max` | Max rank Lesser Healing Wave |
| `/qh chainheal` | Optimal Chain Heal |
| `/qh chainheal max` | Max rank Chain Heal |

---

## Configuration

Open the config panel with `/qh cfg`. Key settings:

- **Healthy Threshold**: HP percentage above which targets are skipped. Below this threshold, fast heals (Flash Heal, Regrowth, etc.) are used in combat; above it, slow efficient heals are used.
- **Force Self-Heal**: Prioritize self when below this HP percentage.
- **Target Priority**: Always heal current target first if they need healing.
- **Subgroups**: Select which raid groups to include when healing.
- **Tank List**: Add tanks via `/qh tanklist` then click `+` with a tank targeted.

### Downranking

Open the downrank window with `/qh dr`. Two sliders control the rank range:

- **Max rank**: Upper bound on spell rank QuickHeal will use.
- **Min rank**: Lower bound — QuickHeal will never pick a rank below this.

This lets you cap mana usage or force higher ranks for throughput.

### QuickClick (Mouse-Click Healing)

QuickClick lets you heal by Ctrl+clicking unit frames instead of using slash commands. When enabled, holding **Ctrl** and **left-clicking** any supported unit frame calls QuickHeal directly on that unit — it picks the best spell rank for their deficit and casts it immediately, bypassing the normal "find lowest health" search.

If Ctrl is not held, the click behaves normally (targeting, selecting, etc.).

**Supported unit frames:**
- Blizzard default frames (player, pet, target, target-of-target, party)
- pfUI
- CT Raid Assist
- EasyRaid
- Discord Unit Frames
- Perl Classic / X-Perl

Enable or disable QuickClick in the configuration panel (`/qh cfg`).

---

## Stopcasting

QuickHeal includes intelligent stopcasting to prevent wasted heals. When a heal is in progress, it monitors conditions and can cancel the cast.

### Stop Conditions

1. **Target dies** — always stops immediately.
2. **Line of Sight lost** — stops if target moves behind a wall (requires UnitXP).
3. **Overheal threshold exceeded** — stops if the heal would waste too much health.

### Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `StopcastCheckWindow` | 0 | Only check stop conditions when this many seconds or fewer remain in the cast. 0 = always check. |
| `MaxOverhealPercent` | 50 | Stop the cast if overheal would exceed this percentage. 0 = never stop for overheal. 100 = stop only at full health. |

### Tips

- **PvP**: Low `StopcastCheckWindow` (0–0.5) to react quickly.
- **Raid healing**: Moderate `MaxOverhealPercent` (30–50) for efficiency.
- **Tank healing**: High `MaxOverhealPercent` (70–100) to ensure heals land.

---

## Aggro Detection and Pre-Healing

QuickHeal detects when friendly units are being targeted by enemies and can pre-heal them before damage lands.

### Detection Methods

- **GUID-based tracking**: Compares enemy target GUIDs with friendly unit GUIDs (requires Nampower DLL).
- **UnitIsUnit fallback**: Traditional method using unit ID comparison.

### Settings

Configure in the configuration panel:

- **Precast Aggro Targets**: Heal targets with aggro even above the normal healthy threshold.
- **Pre-HOT Aggro Targets**: Cast HoTs on aggro targets preemptively.
- **Aggro Target Preference**: Heal highest or lowest max-health aggro target first.

---

## Keybindings

Accessible through the WoW keybinding menu:

| Keybind | Action |
|---------|--------|
| QuickHeal Heal | Main healing function |
| QuickHeal HoT | HoT casting |
| QuickHeal HoT Firehose | HoT firehose mode |
| QuickHeal Heal Subgroup | Heal configured raid subgroups |
| QuickHeal HoT Subgroup | HoT configured raid subgroups |
| QuickHeal Heal Party | Heal party members only |
| QuickHeal Heal MT | Heal main tanks only |
| QuickHeal HoT MT | HoT main tanks only |
| QuickHeal Heal NonMT | Heal non-tanks only |
| QuickHeal Heal Self | Heal yourself |
| QuickHeal Heal Target | Heal current target |
| QuickHeal Heal Target's Target | Heal your target's target |
| QuickHeal Toggle Healthy Threshold | Toggle HPS mode |
| QuickHeal Show/Hide Downrank Window | Toggle downrank slider |

---

## DLL Enhancements

QuickHeal can utilize optional DLL enhancements for improved functionality. Run `/qh dll` to check which are detected.

### Nampower

- `GetCastInfo` — accurate cast time tracking
- `IsSpellInRange` — reliable range checking
- `GetUnitField` — read unit health/mana directly from memory
- `GetSpellModifiers` — spell coefficient and modifier data
- `GetPlayerAuraDuration` — buff/debuff duration tracking
- Spell pushback and failure event handling

### UnitXP_SP3

- `UnitXP("distanceBetween")` — accurate distance measurement (40-yard range check)
- `UnitXP("inSight")` — line of sight detection

### SuperWoW

- `SpellInfo` — spell information lookup
- GUID-based targeting — cast on specific units without switching target

---

## HealComm Integration

QuickHeal includes QHealComm, a HealComm-compatible library that broadcasts incoming heal information to other healers. When pfUI is loaded, QHealComm delegates to pfUI's libpredict for seamless interop. When pfUI is absent, QHealComm runs a standalone implementation that sends and receives the same HealComm messages.

This means:
- Other healers using pfUI, HealComm, or QuickHeal can see your incoming heals.
- QuickHeal subtracts other healers' incoming heals when selecting targets, reducing overheal.
- HoT durations (Renew, Rejuvenation, Regrowth) and resurrections are tracked.

---

## Troubleshooting

**Heals not stopping when they should:**
- Check that `StopcastCheckWindow` is not too high.
- Verify `MaxOverhealPercent` is set appropriately.
- Ensure stopcasting is enabled in config.

**Heals stopping too often:**
- Increase `MaxOverhealPercent` to allow more overheal.
- Decrease `StopcastCheckWindow` to check later in the cast.

**AddOn not working:**
- Make sure folder is named `QuickHeal` (not `QuickHeal-main`).
- Check that all required libraries are present in the `libs` folder.
- Try `/reload` to refresh the UI.
- Run `/qh dll` to check DLL status.

**Unit frames not responding to click healing:**
- Ensure QuickClick is enabled in configuration.
- Check that your unit frame addon is supported.
- Verify Ctrl key is being held while clicking.

---

## Credits

QuickHeal was originally created by Thomas Thorsen, Scott Geeding, and Kostas Karachalios, with contributions from the Turtle WoW community.
