# Changelog

## 1.0.0

First public release of WiiCompiled DeckHelper.

- Steam Deck-focused GUI installation manager for WiiCompiled's native Linux workflow.
- Local verification and compilation from a user-supplied compatible PAL Mario Kart Wii dump.
- Base-game and Base + Retro Rewind installation flows.
- Save and Mii discovery/import with backups.
- Native Steam shortcut creation, readback verification, and optional GameTDB/SteamGridDB artwork.
- Live compiler progress with optional console visibility.
- SteamOS dependency checking and targeted repair for pruned development files.
- Safe interruption, cleanup, resume, background continuation, reattachment, and orphan recovery.
- Controller-friendly GUI navigation with a native Steam Deck input fallback when Steam is closed.
- WiiCompiled borderless display-mode launch default for Steam integration.
- Cached verification/source discovery to reduce unnecessary startup scanning and hashing.
- Conservative cleanup of obsolete DeckHelper-owned state without touching user ROMs, NAND, Miis, saves, or valid installs.

The 1.0.0 codebase is the stabilization of the RC19/RC20 hardware-validation series.
