# WiiCompiled DeckHelper

**Version:** 1.0.0  
**Maintainer:** `cranialprolapse`

WiiCompiled DeckHelper is an independent Steam Deck installation manager and frontend for WiiCompiled's native Linux build. It is designed to take a compatible Mario Kart Wii dump from verification through local compilation, save/Mii migration, optional Retro Rewind setup, and native Steam integration without requiring the user to manually reproduce the command-line workflow.

## What DeckHelper does

- Verifies the SteamOS build environment using real headers/files and compile checks.
- Repairs known SteamOS development-package pruning issues when permitted.
- Verifies the tested PAL Mario Kart Wii `RMCP01` image.
- Builds native WiiCompiled Mario Kart Wii locally from the user's own compatible dump.
- Builds **Base + Retro Rewind** in prerequisite order.
- Shows live compiler `current/total` progress in the GUI.
- Can discover and import compatible save/Mii data with backups.
- Adds the resulting native executables to Steam.
- Retrieves artwork from GameTDB and SteamGridDB.
- Verifies Steam shortcuts after writing them and retries a failed first write.
- Avoids scripted Steam relaunch on KDE/Wayland to prevent the Desktop Mode screen-share chooser.
- Keeps ordinary builds quiet by default; **View Console** can be toggled without affecting the build.
- Keeps interactive sudo/dependency repair visible when user input is required.
- Supports safe interruption, resume, background continuation, and reattachment to active installs.
- Reuses unchanged verified source state to avoid needless rescanning and rehashing on later launches.
- Preserves backend and per-action logs for support/debugging.

## Compatible game image

DeckHelper currently validates the tested PAL Mario Kart Wii disc identity:

- Game ID: `RMCP01`
- Exact ISO size: `4,699,979,776` bytes
- CRC32: `3a70d78b`
- MD5: `e7b1ff1fabb0789482ce2cb0661d986e`
- SHA-1: `4fde5ce38d68f632d92c5b0d52bbab0b1d355a95`
- SHA-256: `2fc548bad45f373bad953d410a32e042e7efeef86a90f9ff63ddc5b62f9e6971`

WiiCompiled supports several input container formats. Raw ISO/GCM images can be checked directly against the canonical disc fingerprints above. Compressed/container formats are handled conservatively; DeckHelper does not pretend that a container-file hash is equivalent to the raw-disc hash.

Users must provide their own legally dumped compatible game image. **No Nintendo game image, Nintendo code, Nintendo assets, or translated Mario Kart Wii executable is distributed with DeckHelper.** Translation/compilation happens locally on the user's machine.

## Installation

1. Extract the entire release folder.
2. Launch `WiiCompiled DeckHelper.desktop` or `WiiCompiled DeckHelper Launcher.sh`.
3. Run **Verify / Repair Dependencies** if needed.
4. Select or allow DeckHelper to discover the compatible Mario Kart Wii image.
5. Choose **Install Base Game** or **Install Base + Retro Rewind**.
6. Leave **Add to Steam** enabled if Steam integration is wanted.
7. In KDE/Wayland Desktop Mode, DeckHelper intentionally leaves Steam closed after editing shortcuts. Open Steam normally or return to Gaming Mode afterward.

## Credits

### WiiCompiled DeckHelper

Project direction, Steam Deck workflow, UX/integration decisions, real-hardware testing, and maintenance:

**`cranialprolapse`**

Implementation was developed with **OpenAI ChatGPT** as a coding assistant.

### Upstream projects and services

- **WiiCompiled** — patchzyy and WiiCompiled contributors — https://github.com/patchzyy/Wiicompiled
- **Native Linux support** — prominent special credit to **theofficialgman** for WiiCompiled PR #37 and the native Linux installer/build/runtime work used by this DeckHelper workflow — https://github.com/patchzyy/Wiicompiled/pull/37
- **Retro Rewind** — ZPL, the Retro Rewind Team, and contributors — https://github.com/Retro-Rewind-Team/rr-pulsar
- **GameTDB** — artwork source used by Steam integration — https://www.gametdb.com/
- **SteamGridDB** — community Steam artwork source used by Steam integration — https://www.steamgriddb.com/
- **OpenAI ChatGPT** — coding assistance — https://openai.com/

No endorsement by any credited project, service, person, or organization is implied.

## License

WiiCompiled DeckHelper is released under the **GNU General Public License v3.0**.

See `LICENSE` and `THIRD-PARTY-NOTICES.md`.

DeckHelper does not bundle WiiCompiled, Retro Rewind, Nintendo game data, or downloaded artwork in this release archive. Software and content retrieved from upstream sources remain subject to their respective licenses and terms.

## Affiliation notice

WiiCompiled DeckHelper is an independent community project. It is not affiliated with, sponsored by, approved by, or endorsed by Nintendo, Valve, Steam, WiiCompiled, Retro Rewind, GameTDB, SteamGridDB, or OpenAI.

Mario Kart Wii, Wii, Nintendo, and related names/assets are property of Nintendo and their respective rights holders.
