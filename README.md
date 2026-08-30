# MapOfScars (Enhanced)

A lightweight top-of-screen compass AddOn for World of Warcraft 1.12.1, forked from
[yutsuku/MapOfScars](https://github.com/yutsuku/MapOfScars) (itself a backport of
[Lanrutcon/MapOfScars](https://github.com/Lanrutcon/MapOfScars)).

This revision keeps the exact same look and behavior, but replaces the original's
facing-detection hack with a native call when available, and adds optional
unit-tracking with accurate distance/line-of-sight — both driven by client-side
mods that are common on 1.12/Turtle-style servers.

## Optional DLLs

None of these are required — the addon behaves identically to stock `MapOfScars`
with nothing extra installed. Grab only the ones whose feature you want. All of
them (except SuperWoW) are loaded by adding a line to a `dlls.txt` used by a
DLL-loading launcher such as [VanillaFixes](https://github.com/hannesmann/vanillafixes).

| DLL file | Project | Used by this addon for | Load method |
|---|---|---|---|
| `ClassicAPI.dll` | [ClassicAPI](https://github.com/brues-code/ClassicAPI) | Native `GetPlayerFacing()`, removing the hidden-model hack | Add to `dlls.txt` |
| `UnitXP_SP3.dll` | [UnitXP_SP3](https://codeberg.org/konaka/UnitXP_SP3) | Accurate `distanceBetween` and `inSight` for unit-tracked POIs | Add to `dlls.txt` |
| `SuperWoWhook.dll` | [SuperWoW](https://github.com/balakethelock/SuperWoW) | GUID-stable unit-tracked POIs | Its own launcher: `SuperWoWlauncher.exe` (place next to a `WoW.exe`-named executable) |

Run `/mosstatus` in-game any time to confirm what's actually detected and loaded.

## Screenshot

<img width="883" height="216" alt="image" src="https://github.com/user-attachments/assets/a3f68a4c-67f3-436d-bc54-b7364ae26b22" />


The compass bar sits centered at the top of the screen. Cardinal letters (`N`/`S`/`E`/`W`)
slide left/right along the bar as you turn, and POI icons (quest markers, pings, tracked
units) slide in from either edge as they come into your forward arc.

## What changed vs. the original addon

| Area | Original `MapOfScars` | This version |
|---|---|---|
| Player facing | Spawns a hidden, 0-scale `Minimap` frame, digs out its `Model` child, and reads `:GetFacing()` off the player-arrow model. Works, but fragile and a bit absurd. | Uses **ClassicAPI**'s native `GetPlayerFacing()` when detected. Falls back to the original hack automatically if ClassicAPI isn't loaded — nothing breaks either way. |
| POI tracking | Only fixed x/y points (e.g. minimap pings), distance computed with a manual `sqrt` on map-percent coordinates. | Adds `addPOIForUnit(unit, ...)` to pin a marker to a *live unit*. With **UnitXP_SP3** loaded, distance comes from `UnitXP("distanceBetween", ...)` and off-screen/behind-terrain markers are hidden using `UnitXP("inSight", "camera", unit)`. Without UnitXP_SP3, it quietly falls back to the original map-percent math. |
| Unit identity | N/A | If **SuperWoW** is loaded, unit-tracked POIs are keyed by the unit's GUID (from `UnitExists()`'s 2nd return) instead of its transient unit id, so a marker can't get silently reassigned to a different mob. |
| Diagnostics | None | `/mosstatus` slash command prints which supported mods are detected and exactly what each one is (or isn't) being used for. |
| Everything else | — | Unchanged: same compass texture, same fonts, same ping-marker behavior, same `.toc` structure. |

## Slash Commands

- `/mosstatus` — prints detected mods and what this addon is doing with each.
- `/run MapOfScars_AddPOIForUnit("target")` — pin a compass marker to your current
  target (or any other unit token: `"mouseover"`, `"party1"`, etc.).

## Known Issues (inherited from upstream)

- No support for map "blips" beyond the basic POI icon system.
- Icons can occasionally flicker near the edge of the forward arc.

## Credits

- Original addon: Lanrutcon
- 1.12.1 backport: yutsuku / moh
- ClassicAPI / UnitXP_SP3 / SuperWoW integration: this fork
