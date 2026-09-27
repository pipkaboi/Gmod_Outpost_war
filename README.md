# GMod_forpost — Outpost War

Addon for Garry's Mod: outposts that spawn squads of NPCs. Squads march together to capture enemy outposts, while a garrison stays behind to guard home.

## Features
- Outposts spawn any NPC from the spawn menu (including addon NPCs) in waves, with a chosen weapon.
- A garrison stays to defend; the rest form a squad and go capture the nearest enemy or neutral outpost.
- Capture zone with progress bar; captured outposts switch team and start spawning the captor's NPCs.
- Teams 1–10+ are hostile to each other even if they use the same NPC class. Team 0 = neutral outpost.
- Works on maps without AI nodes (step-by-step fallback movement).

## Usage
Spawn menu (Q) → **Outpost War** tab → **Outpost Creator**.
- LMB — place outpost, RMB — remove, R — apply current settings to an outpost.
- Server settings: Outpost War → Settings → Server Settings.

Console variables: `outpost_war_capture_time`, `outpost_war_ignore_players`, `outpost_war_tint`, `outpost_war_debug` (needs `developer 1`), command `outpost_war_clear_npcs`.

## Repository layout
- `test_mod/` — the addon itself (this is what gets published to the Workshop).
