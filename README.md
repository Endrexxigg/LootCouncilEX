# LootCouncil EX

A fast, clean, **TBC Classic Anniversary**-native loot council addon for World of
Warcraft — a from-scratch replacement for RCLootCouncil's clunky Classic build.

> **Status:** pre-implementation. The repo currently holds the project spec and tooling;
> the addon itself is built in phases (see the build map in [PROJECT.md](PROJECT.md) §7).

## What it does (v1 goal)

Run a full raid night's loot on a TBC-native tool: broadcast → respond → vote → award via
master loot, plus a persistent council toolkit (notes, item marks, award history,
self-reported gear/professions) that syncs between council members in and out of raid.

Two separate data planes:

- **Live session** — ephemeral, master-looter-authoritative voting (RAID / WHISPER).
- **Persistent council** — durable, replicated notes / marks / history over GUILD,
  last-write-wins.

See **[PROJECT.md](PROJECT.md)** for the full architecture, comms protocol, data shapes,
and phased build map.

## Tech

- Pure Lua 5.1 + embedded **Ace3** (AceAddon / Event / Comm / Serializer / DB / Timer /
  Console).
- **Native `CreateFrame` UI only — no AceGUI.**
- No build step: the repo folder *is* the addon. Symlink it into
  `World of Warcraft\_classic_era_\Interface\AddOns\LootCouncilEX` and `/reload`.

## Working in this repo

See **[CLAUDE.md](CLAUDE.md)** for conventions, the TBC API rules and gotchas, the git
workflow, and testing / linting.

- **Slash command:** `/lcex`  ·  **Comms prefix:** `LCEX`  ·  **Addon folder:** `LootCouncilEX`
- Lint: `luacheck .`
