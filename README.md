# KAKT-RarityColors

A visual mod for **King Arthur: Knight's Tale**. It recolours item rarities to the scheme
players know from Diablo-like games such as Path of Exile: white, blue, yellow, orange.
Only the way items look changes. Stats, prices, drop rates and everything else stay exactly
as in vanilla.

## What it does

| Tier | Game rarity | Vanilla colour | With the mod |
|---|---|---|---|
| T0 | basic items (starting gear) | grey / white | unchanged |
| T1 | common | green | blue `#8888FF` |
| T2 | uncommon | blue | yellow `#FFFF77` |
| T3 | relic | gold | orange `#AF6025` |

For T1–T3 the mod changes three things:

- **Item name colour** — everywhere the game colours a name by rarity.
- **Icon background** — the coloured backdrop behind the item picture.
- **Icon rune** — the glowing sign drawn over weapon and armour icons.

The tooltip background and the loot pop-up background follow the same colours.

Left untouched on purpose:

- **Purple endgame items** (Soul Merchant) and **red lares** keep their own colours, so they
  still stand out from relics.
- **The icon frame.** The game colours it to show whether the selected hero can equip the
  item; the mod does not draw over it.
- **Consumable icons** (potions, scrolls, tomes). Their names follow the new colours, as the
  game colours names by rarity for every item.

## Optional: tier prefixes

`Optional/TierPrefixes` adds a short tier tag in front of every item name, for example
`[T2] Seal of Valor`. It is handy for learning the new colours and for checking an item's
tier at a glance.

| Tag | Meaning |
|---|---|
| `[T0]` | basic item or consumable without a rarity |
| `[T1]` | common |
| `[T2]` | uncommon |
| `[T3]` | relic |
| `[TE]` | purple endgame item (a relic in the game data) |
| `[TL]` | lar |

The prefixes are included for all 10 game languages.

## Requirements

- King Arthur: Knight's Tale **2.0.1** (Steam build 18532639). Other versions may have
  different files; do not install the mod over a version it was not made for.
- No mod loader or other tools.

## Installation

1. Find the game folder. On Steam: right-click the game → *Manage* → *Browse local files*.
   The folder contains `KA_KT.exe`, `Cfg`, `UI` and `Strings`.
2. Back up the game's `Cfg`, `UI` and `Strings` folders (optional, but recommended).
3. Download this repository (*Code* → *Download ZIP*) and extract it.
4. Copy the `Cfg` and `UI` folders from the archive into the game folder and allow the
   files to be overwritten.
5. Optional: to get the tier prefixes, also copy the `Strings` folder from
   `Optional/TierPrefixes` into the game folder.

Only the folders above are copied; everything else in the archive (`README.md`, `LICENSE`,
the scripts, `installer`, `tools`, `tests`) stays out of the game folder.

## Installing with a script (optional)

Instead of copying by hand you can let a script do it. It finds the game through Steam,
checks that the game files are the ones the mod expects, backs up every file it replaces
and can later put them back.

- **Windows:** double-click `install.bat` (or `uninstall.bat`). If Windows warns about a
  downloaded file ("Windows protected your PC"), choose *More info* → *Run anyway*.
- **Linux and macOS:** in a terminal, in the extracted folder: `sh install.sh` (or
  `sh uninstall.sh`).

On the first run the installer asks whether to add the optional tier prefixes. To add them
later, uninstall and install again with `--with TierPrefixes`. Options (the same on every
system; on Windows add them after the `.bat` name in a command prompt):

| Option | Meaning |
|---|---|
| `--game PATH` | game folder, if it is not found automatically |
| `--with TierPrefixes` | install the tier prefixes without asking |
| `--yes` | confirm warnings without asking (optional components still need `--with`) |
| `--force` | install even over files changed by something else; they are backed up as they are |
| `--discard-backup` | uninstall: forget a backup that can no longer be restored |

How it keeps your game safe:

- The backup goes to `_mod_backups/KAKT-RarityColors` inside the game folder. Do not delete it
  while the mod is installed.
- Nothing is changed unless every file checks out. If the mod was already copied by hand,
  another mod changed the same files or they come from another game version, the installer stops and
  says why. If copying fails halfway, the original files are put back.
- The uninstaller restores only files that are still exactly as the mod left them. Files
  changed since then (a game update, a file verification, another mod) are left alone and
  listed.
- The game must be closed while the scripts run.
- Do not mix the two methods: remove a hand-copied mod with Steam, a script-installed one
  with the uninstaller. Steam *Verify integrity of game files* always works as a last resort;
  run the installer again afterwards and it cleans up its old backup.

## Updating and removing

- To remove the mod, use Steam: right-click the game → *Properties* → *Installed Files* →
  *Verify integrity of game files*. Steam restores the original files.
- If you installed with the script, run the uninstaller instead (see above).
- A game update or a file verification also removes the mod. Copy the files again
  (or run the installer) afterwards if you want to keep it.
- The mod does not touch save files. It can be installed or removed at any time, in the
  middle of a campaign too.

## Compatibility

The mod replaces whole files. It is **not compatible** with other mods that change any of
these files:

- `Cfg/GUI/Styles.xml`
- `UI/Items/*_C_*.dds`, `*_U_*.dds`, `*_R_*.dds` (440 weapon, armour and trinket icons)
- `UI/Inventory/ItemPopup/Itempopup_{common,uncommon,relic}_bg.dds`
- `UI/BattleUI/LootPopup/Lootpopup_bg_{common,uncommon,relic}.dds`
- with the optional prefixes: `Strings/*/Langs/Lang_ItemNames*.xml`

It shares no files with [KAKT-FreeSkillPoints](https://github.com/iiifx/KAKT-FreeSkillPoints),
so the two mods can be installed together.

## How it works

- **Name colours.** `Cfg/GUI/Styles.xml` defines `CommonColor`, `UncommonColor` and
  `RelicColor`; the game reads them to colour item names. The mod sets them to the palette
  above.
- **Icons.** Every weapon, armour and trinket icon exists in a separate copy per rarity
  (`_C_`, `_U_`, `_R_`). All icons of one rarity share the same background texture, so the
  mod recolours the pixels that match that background, including the shadows the item casts
  on it. On weapons and armour the rune is found by comparing the icon with its copies of
  the other rarities: the item itself is drawn identically in all of them, only the rune and
  the background differ. The item picture is left as it was.
- **Backgrounds.** The tooltip and loot pop-up backgrounds are recoloured the same way.
- **Prefixes.** The tier of each item is taken from the game's item data (`Rarity`), and the
  tag is added in front of its name in `Lang_ItemNames*.xml`.

## Installer manifest and tests

`tools/manifest.py` regenerates `installer/manifest.txt` (the file list with SHA-256 hashes the
scripts rely on). `tests/test_installer.py` runs the installer against a fake game folder:
`python3 tests/test_installer.py` for the shell script, `KAKT_IMPL=ps` for the PowerShell one.
The tests run on Linux, macOS and Windows through GitHub Actions.

## Building from the game files

`tools/build.py` regenerates every mod file from the original game files, for example after
a game update. It needs Python 3 with numpy and Pillow, and ImageMagick.

```
python3 tools/build.py --game "/path/to/King Arthur Knight's Tale" --out . --prefix-out Optional/TierPrefixes
```

The source files must be unmodified. If the game folder already has the mod installed, verify
the game files in Steam first, or pass a backup of the original files with `--originals`.
`python3 tools/build.py --help` lists all options. After a rebuild, regenerate the installer
manifest with `python3 tools/manifest.py --originals <folder with the original files>`.

## Known limits

- The game colours names by rarity only, so a purple endgame item has the same name colour
  as other relics (orange). Its icon stays purple.
- Names of Roman campaign items exist only in the English and Italian files of the game.
- Tested with the Russian language in the main campaign.

## License

The mod's own changes are released under the [MIT License](LICENSE).

King Arthur: Knight's Tale and its original game files, including the item artwork the
recoloured icons are based on, are the property of Neocore Games. This is an unofficial fan
mod and is not affiliated with or endorsed by Neocore Games.
