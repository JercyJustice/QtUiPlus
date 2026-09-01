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
| `/qtp profile list\|create\|select\|copy\|delete\|reset <name>` | Layout profiles |
| `/qtp theme <style>` | Visual style |
| `/qtp shift <n>` | Change to druid form n in one press |
| `/startattack`, `/stopattack` | Start or stop auto attack without toggling it off |
| `/qtp startattack`, `/qtp stopattack` | The same, under the addon prefix |
| `/qtp attack` | Target the nearest enemy if there is none, then attack |
| `/qtp firsttarget` | Target the nearest enemy and keep it until it dies |
| `/qtp macro <name>` | Write a macro for one of those commands and put it on the cursor |
| `/qtp check` | Runtime self-check |
| `/qtp frames <text>` | Find stock frames by name and see which are still shown |
| `/qtp debug` | Toggle debug output |

## What was ported from QtUI

Everything QtUI had that the base did not:

- **Auto loot** — empties corpses, containers and nodes; hold Shift to suppress.
- **Auto-sell greys** — sells poor-quality items at a merchant and reports the total.
- **Equipped-item compare** — shows your equipped item beside an item tooltip.
- **Creature health table** — real hit points for enemies reported as a percentage.
- **Vendor prices** — static sell-price database behind the auto-sell totals.
- **`/startattack` and `/stopattack`** — the client only has the toggling
  `AttackTarget`, so a macro meant to make sure auto attack is running just as
  happily stops the swing that already was. These read the real state back from
  the Attack action instead, and never toggle it the wrong way.
- **One-press druid forms** — switch straight from one form to another instead
  of dropping to caster form first. Pressing the form you are already in leaves
  it, and a press in the moment right after a shift lands is ignored, so
  spamming the button through a transition cannot throw you back out; that
  toggle can be turned off so only Ctrl leaves a form. Off by default; Stance
  Bar settings. Ported from
  [SmartShapeshift](https://github.com/robertwallin86/SmartShapeshift).
- **Chat extras** — timestamps, class-coloured names, working mouse-wheel scrolling.
- **Clock and bag space** — added to the existing status strip.
- **Profiles** — named, account-wide settings profiles. Each character
  remembers which one it uses, so characters can share a layout or keep their
  own, and a profile laid out at another resolution is rescaled on the way in.

Cooldown text was *not* ported: the base already renders it on action buttons and
auras, with colour tiers.

## Changed from the base

**Combo points are no longer rogue-only.** A druid gets combo points in cat
form, but the pips and the stock `ComboFrame` suppression were both gated on
`ROGUE`, so a druid saw the native gems at `TargetFrame`'s stock top-left
position instead. Rogues still see five slots at all times; a druid sees the
strip only while holding points. Filled pips take the player's class colour.

**Stock target health/mana bars.** The suppression list carried only the
`$parent`-named `TargetFrameHealthBar` / `TargetFrameManaBar`. This client also
exposes them as bare `Target*` names — the same rename that once left the yellow
level number on screen — so both spellings are now listed. Use
`/qtp frames Target` to see which names actually resolve here, and whether any
of them is still SHOWN.

**Stance bar is no longer warrior-only.** UnrealUI built `modules/stancebar.lua`
only for warriors, leaving druids, rogues, priests and paladins with no bar at
all. QtUiPlus gates on the form count instead of the class, which the client wiki
supports directly: `GetNumShapeshiftForms()` returns the slots the player
actually has, and `0` for a class with no stance bar. A class with no forms still
never gets a frame, a button or a mover built.

## Settings

`/qtp` opens the panel. Pages: General (incl. edit-mode grid size), Frame Sizes
(Player / Target / Target of Target / Pet / Party), Unit Frames, Combo Points,
Energy Tick, Experience Bar, Bags, Chat, Profiles, Extras, and the
ActionBars group (General Options, Bar 1-10, Stance Bar).

## Architecture notes

`core/qtcompat.lua` is the bridge. The ported QtUI modules keep their original
shape and call a small `QtP` table backed by QtUiPlus internals, rather than being
rewritten into the module registry. The bridge surface is deliberately tiny:
`Print`, `media`, `ApplyFont`, `PlaceAlignedText`, `CreatePanel`, `GetLayout`,
`EnsureLayoutDefaults`, `IsFeatureEnabled`.

Ported settings live under `QtUiPlusDB.qt`, not in the per-module store, because
`core/config.lua` caps a module's settings at one level of nesting.

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
