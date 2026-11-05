# DELTARUNE Mod Manager

A native macOS SwiftUI launcher for GameBanana DELTARUNE mods. It reads
Deltamod archives and modern or legacy G3M packages, applies supported patches
to backed-up Windows chapter data, maps Mac-compatible overrides into the
matching Mac game resources, and creates a separate launchable instance for
each mod. Create a desktop shortcut for any instance to launch it through the
manager.

## Requirements

- macOS 13 or later
- Steam-installed Mac `DELTARUNE.app`
- A Windows DELTARUNE folder containing `chapterN_windows/data.win`
- `xdelta3` (`brew install xdelta`) for xdelta patches; BPS patches are applied natively

Install the games first. This project does not verify account ownership,
redistribute, or download game files. Choose your local Windows game folder and
installed Mac app during first-run setup. The project keeps the `Base Game`
directory out of source control.

## Build and run

```sh
./scripts/build-app.sh
open "Deltarune Mod Manager.app"
```

The app build also produces a macOS Installer package that installs only the
mod manager into `/Applications`:

```sh
./scripts/package-app.sh
```

The generated `Deltarune Mod Manager.pkg` does not include DELTARUNE files.
The app uses the supplied title-screen artwork as a darkened background and
your supplied red heart image as its app icon.
Use **Update** in the app header to check the latest GitHub release; when a
newer version is available, the release page opens so you can download and run
its installer.

Run the patcher/archive validation with:

```sh
./scripts/test-mod-builder.sh
```

The app backs up the Windows chapter `data.win` files into its Application
Support directory during setup. It does not patch the live Mac installation
when importing a mod. On launch, it saves the original Mac files, temporarily
installs the selected instance, opens the Mac game app, and restores the
originals when the game exits. A recovery record is kept so the app can restore
files on its next start if it was quit unexpectedly.

Use the native GameBanana catalog's search and category tabs to find DELTARUNE
mods. Sorting is applied by GameBanana before pagination, so relevance,
popularity, newest, and recently updated results stay in global order as more
pages load.
Choose **Launch Vanilla** in the app header to start DELTARUNE without applying
a mod instance.
The catalog loads 30 mods initially, then preloads 15 more when you reach the
middle of the loaded results. The GameBanana search API does not provide a
global sort by view count. Mod details show each supported release as an
expandable version choice, including archived versions.
My Mods opens in Library view by default. Change the preference in Settings or
use the view switcher at the top of My Mods.
The **My Mods** tab and the sidebar shortcuts are ordered by most recently
played. The tab also has a search field for filtering installed mods by name,
version, description, or author. Assign categories in a mod's **Edit** sheet;
category headings can be collapsed, and mods can be dragged onto a heading to
move them. Drop a mod on **Create a category** to name a category and move it
there. The **Library** button switches My Mods to a square-icon grid while
keeping the category groups and collapsed states.
Use **Add To Desktop** in a mod's options to create a small launcher app on the
Desktop. It opens that mod in the manager directly, and uses the mod's icon
when available. If the manager is already running, the shortcut launches the
mod without bringing the manager window to the front; otherwise it opens the
manager and launches the mod. Shortcuts use a native launcher and do not ask
for Desktop-folder access on each launch. In Settings,
**Install CLI** adds the `drmt` command to `~/.local/bin`; use `drmt list` to
see instances or `drmt launch "<mod name>"` to launch one. If your shell cannot
find `drmt`, add `~/.local/bin` to your `PATH`.
GameBanana-installed mods are checked for newer supported releases when
**My Mods** is opened. Available updates show an **Update Mod** button on that
instance and an **Update All** action; updating keeps the instance and its
custom files in place. Manually imported mods without GameBanana release
information are not update-tracked.
GameBanana G3M one-click links (`g3m://…/mmdl/<fileID>,Mod,<modID>`) and legacy
`deltahub://` links open this app and install the specific linked release.
Deltamod packages, modern G3M ZIPs containing `mod_config.json`, and legacy
G3M packages containing `modding.xml` plus `meta.toml` are detected and
imported automatically. G3M packages support DELTARUNE chapter patches using
xdelta or BPS, complete data-file replacements, supported `overwrite` file
actions, and package/source checksums. G3M resource patches (`.g3mpatch`),
scripts, directory/archive operations, and unsupported operation types are
reported instead of run.

Other manual ZIP, RAR, and xdelta releases are downloaded or selected first, then
analyzed for `.xdelta` patches, files named `data.win`, and `.dylib` files. RAR
archives are extracted with macOS's built-in archive utility.
Chapter and launcher names in their paths are selected automatically, and
assignments can still be changed or skipped before creating the instance.
Chapter xdelta patches apply to the selected chapter's backed-up Windows
`data.win`; launcher xdelta patches apply to the backed-up root `data.win` and
target the Mac app's root `Contents/Resources/game.ios`. An included
`data.win` replaces the selected chapter or launcher game data file. Dylibs
are placed in the selected chapter's Mac folder; the game may require a
compatible loader to use them. Manual patch archives with `lang_*.json` files also
apply those language overrides to each selected patch chapter. **Only compatible
mods** includes active Deltamod, G3M, and manual patch releases. You can
also import a `.deltamod`, G3M ZIP, regular ZIP or RAR, or xdelta manually. Windows-only
DLL overrides are skipped, but chapter DLLs with a safe Mac target include a
**Repatch with .dylib** action in the instance's compatibility notes. Choose a
compatible macOS library and the instance will use it at the matching
`chapterN_mac` path on its next launch. Other unsupported patch formats and
missing chapter sources are reported rather than silently applied.
For manual patch releases downloaded from GameBanana, the installed instance
uses the GameBanana mod image as its icon when the archive doesn't provide its
own icon. Existing archive-provided icons are kept. Unescaped ampersands in
`modding.xml` attributes are tolerated for older mod packages.

Downloaded archives are removed after successful installation and old failed
downloads are cleaned up after seven days. GameBanana responses and images use
a bounded URL cache to limit memory and cache-disk usage; installed instances
and Windows backups are retained until you remove them. Use an instance's
**Show in Finder** button to open its `CustomFiles` folder. It creates an empty
directory tree matching the installed game's `Contents/Resources` folders, but
does not copy any game files. Drop files into their matching paths, such as
`CustomFiles/chapter3_mac/helper.dylib` or `CustomFiles/mus/custom.ogg`.
**Music Folder** opens or creates `CustomFiles/mus` for songs. Custom files are
applied from this folder only while the instance runs, then originals are
restored; they are not duplicated in the instance's managed `Payloads`.
Use **Edit** on an instance to browse its managed files, rename it, and add a ZIP
or RAR archive, xdelta patch, or dylib with the **+** drop area. Files are assigned to the
launcher or a chapter before they're added; files that target an existing path
replace that instance's prior managed file for the same path. GameBanana
release rows expand from anywhere on the row, with the arrow indicating whether
the release is open.
