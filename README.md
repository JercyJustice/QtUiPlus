# QtUiPlus

An interface addon for the Unreal Azeroth / Emberveil client (Interface 11200).

QtUiPlus is **UnrealUI's interface with QtUI's feature set**. UnrealUI supplies
the look and the module architecture; the features QtUI had and UnrealUI did not
are ported in on top.

## Credits

- Base: [UnrealUI](https://github.com/Tom75VN/UnrealUI) by Tom75VN, MIT licensed.
  The layout, styling, edit mode, quick binding and stock-frame replacements are
  its work, as is the accumulated knowledge of this client's quirks recorded
  throughout `core/`.
- Ported features: [QtUI](https://github.com/JercyJustice/QtUI) by JercyJustice.
- Vendor price data originates from ShaguValue by Shagu; creature health data
  from the CMaNGOS classic-db.

## Install

Place the `QtUiPlus` folder in `Interface\AddOns` and confirm `QtUiPlus.toc`
sits directly inside it.

**Disable QtUI while running QtUiPlus.** Both replace the same native frames and
will fight over them. QtUiPlus deliberately uses its own global names
(`QtUiPlus`, `QtP`, `QtUiPlusDB`) and its own `qtp*` frame fields so that having
both *installed* is harmless — but having both *enabled* is not.

## Commands

| Command | Effect |
| --- | --- |
| `/qtp` | Open settings (`/qtuiplus` also works) |
| `/qtp unlock` / `/qtp lock` | Edit mode for moving frames |
| `/qtp reset` | Reset all frame positions |
| `/qtp bind` | Quick binding |
| `/qtp profile list\|save\|load\|delete <name>` | Layout profiles |
| `/qtp meter show\|hide\|add\|close` | Damage meter windows |
| `/qtp check` | Runtime self-check |
| `/qtp debug` | Toggle debug output |

## What was ported from QtUI

Everything QtUI had that the base did not:

- **Auto loot** — empties corpses, containers and nodes; hold Shift to suppress.
- **Auto-sell greys** — sells poor-quality items at a merchant and reports the total.
- **Damage meter** — segmented damage/healing with per-fight drilldown.
- **Equipped-item compare** — shows your equipped item beside an item tooltip.
- **Creature health table** — real hit points for enemies reported as a percentage.
- **Vendor prices** — static sell-price database behind the auto-sell totals.
- **Chat extras** — timestamps, class-coloured names, working mouse-wheel scrolling.
- **Clock and bag space** — added to the existing status strip.
- **Profiles** — named config snapshots that survive a resolution change.

Cooldown text was *not* ported: the base already renders it on action buttons and
auras, with colour tiers.

## Architecture notes

`core/qtcompat.lua` is the bridge. The ported QtUI modules keep their original
shape and call a small `QtP` table backed by QtUiPlus internals, rather than being
rewritten into the module registry — the damage meter alone is ~3400 lines of
behaviour already proven on this client. The bridge surface is deliberately tiny:
`Print`, `media`, `ApplyFont`, `PlaceAlignedText`, `CreatePanel`, `GetLayout`,
`EnsureLayoutDefaults`, `IsFeatureEnabled`.

Ported settings live under `QtUiPlusDB.qt`, not in the per-module store, because
`core/config.lua` caps a module's settings at one level of nesting and would
flatten the damage meter's per-window config on every load.

`modules/damagemeter.lua` sits at 199 top-level locals against Lua 5.1's cap of
200. Anything added to that file must be a field on an existing table, not a new
`local`.

## Verification

There is no way to run code inside the client, so changes are checked outside it
with a genuine Lua 5.1 interpreter (`lupa.lua51`):

1. **Parse** every file listed in the `.toc`.
2. **Behaviour tests** for the ported logic — layout clamping, the mob-health
   bracket search, vendor price parsing, and the profile resolution remap —
   against a stub that only defines APIs documented at
   [emberveil.org/wiki/lua](https://emberveil.org/wiki/lua).

A stub must never define an API the client lacks: that makes a broken change pass
its tests while doing nothing in game.

## Known uncertainty

`modules/autoloot.lua` calls `LootSlot`, which the client wiki documents as
*confirming a bind-on-pickup prompt* rather than picking up an item — and it
documents no other pickup function. QtUI ships this same loop against this client
today, so shipping behaviour was preferred over a doc line offering no
alternative. If auto-loot does nothing in game, that is the first place to look.
