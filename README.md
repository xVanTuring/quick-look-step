# QuickLookStep.app

> **_Fast_** QuickLook & Finder thumbnail support for STEP (`.step` / `.stp`) 3d model files on macOS.
>
> Built with Swift + SwiftUI, SceneKit, and [Formlabs/foxtrot](https://github.com/Formlabs/foxtrot).
>
> This is a fork of [johnboiles/quick-look-step](https://github.com/johnboiles/quick-look-step) that adds lit shading and STEP colours, and ships builds signed with a Developer ID and notarized by Apple.

## ✨ What does it do?

This allows you to **quickly** preview STEP files from Finder before opening them in your CAD tool. It will not render your STEP files as well as your CAD tool, but it will almost certainly open them faster!

* Interactive Quick Look preview (spacebar) and Finder thumbnails.
* **Colours:** solids are drawn in the colours stored in the STEP file (per-solid `STYLED_ITEM` / `COLOUR_RGB`). Solids without a colour use a neutral light grey-blue.
* Shaded with a camera-following key light plus fill light, so faces and edges stay readable while you orbit.
* Thumbnails are framed to the model's bounding box, so small parts still fill the icon.

https://github.com/user-attachments/assets/339781d5-3b7b-41c0-b411-d992e49ae5bc

## 🚧 Requirements

* macOS 14.6 (Sonoma) or newer
* M1 or above CPU (Apple Silicon)

## 💻 Installing

Download `QuickLookStep.app` from this fork's [Releases page](https://github.com/xVanTuring/quick-look-step/releases), unzip it, move it to `/Applications`, and open it once to enable the extensions.

The `johnboiles/homebrew-tap` formula installs the original upstream app, which uses different bundle identifiers. Keep only one of the two installed so Finder does not pick between competing extensions.

If for some reason the extensions aren't enabled automatically:
* Open `System Settings` > `General` > `Login Items and Extensions`
* Click the (i) next to `QuickLookStep`
* Turn the switch on for both options under `QuickLookStep`
* Cick `Done`

## 🕶️ Usage

Open a Finder window and select a `.step` or `.stp` file. You should be able to preview it from Finder with Quick Look (using spacebar) or see the thumbnail in the sidebar in column view. `QuickLookStep.app` does _not_ need to be open for the extensions to work.

## 🐞 Known issues

* Some STEP files don't load. The underlying [Foxtrot](https://github.com/Formlabs/foxtrot) library doesn't like them.
* Some STEP files have holes. Probably this is also a [Foxtrot](https://github.com/Formlabs/foxtrot) thing, but I could also be making a mistake in how I'm loading geometry to SceneKit. More testing against [Foxtrot](https://github.com/Formlabs/foxtrot) is needed. For this app, it's always better to be fast than perfect, but ideally it can be both 😀
* Only per-solid colours are read. Colours assigned to individual faces (common in KiCad and some other CAD exports) are not supported by Foxtrot, so those parts fall back to the default colour.
* Very large assemblies can take a long time to load and the extensions get stuck for a bit. Better timeouts could probably protect against this.

## 🔫 Troubleshooting

If you used older versions of `QuickLookStep.app` (especially <v1.5), make sure to delete them and to empty trash (`Finder` -> `Empty Trash...`). I've noticed macOS will sometimes try to use old extensions from the Trash! Then you should restart Finder:

```sh
killall Finder
```

If restarting Finder doesn't make it work, I run this to do everything I know to do to clear the macOS cache:

```sh
pluginkit -r -u tech.xvanturing.QuickLookStep.StepThumbnail
pluginkit -r -u tech.xvanturing.QuickLookStep.StepPreview
pluginkit -a /Applications/QuickLookStep.app
qlmanage -r
qlmanage -r cache
pluginkit -e use -i tech.xvanturing.QuickLookStep.StepThumbnail
pluginkit -e use -i tech.xvanturing.QuickLookStep.StepPreview
killall QuickLookUIService
killall Finder
```

`scripts/install-local.sh` does all of the above, and also unregisters every other copy of the app (build folders, older versions with the upstream `com.johnboiles.*` identifiers).

And of course rebooting is also worth trying!

## 🛠️ Building and releasing

* `make libfoxtrot_universal.a` rebuilds the Rust static library for Apple Silicon (needs the `aarch64-apple-darwin` Rust target; despite its name the file is arm64-only, matching the project's `ARCHS = arm64`). Run `make foxtrot.h` after changing the FFI in `ffi/src/lib.rs`.
* `bash scripts/release.sh <version>` bumps the version, archives, exports with the Developer ID, notarizes, staples, tags `release/v<version>`, and publishes a GitHub release. `bash scripts/release.sh --dry-run` only checks that archiving and signing work.
* `bash scripts/install-local.sh [--user] [path to .app or .zip]` installs a build to `/Applications` (or `~/Applications`) and registers the Quick Look extensions.

## 🤝 Contributing

Let's make this better together. Issues and PRs are welcome.

This project is licensed under the terms of the **MIT License**. Do what you want with it but I don't guarantee it works. If you do something neat with it, I'd always appreciate a shoutout!
