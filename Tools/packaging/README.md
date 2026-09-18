# FastLang Installer Package

## Iterate on the installer

One command does uninstall + rebuild + install:

```bash
./Tools/packaging/build_pkg.sh
```

Flags:

```bash
./Tools/packaging/build_pkg.sh --build-only   # just build the pkg, don't touch anything
./Tools/packaging/build_pkg.sh --yes          # no prompts
VERSION=1.2.3 ./Tools/packaging/build_pkg.sh  # override version string
```

User data at `~/Library/Application Support/com.aws.fastlang/` is never
touched by this script — settings, history, cached models, and model
markers all survive rebuilds. If you want a true first-run experience,
remove that directory manually.

See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) when things break.

## What the installer does

Three components, one required and two optional:

1. **FastLang application** (required) — installs `FastLang.app` into `/Applications`.
2. **Gemma 4 E2B (~3 GB)** (optional, checked by default) — drops a marker.
3. **Gemma 4 E4B (~4.8 GB)** (optional, off by default) — drops a marker.

The `.pkg` stays small (~20 MB) — it doesn't bundle model files. Each
model choice just writes a tiny marker file into
`~/Library/Application Support/com.aws.fastlang/`.

On first launch the app:

1. Reads whichever marker exists.
2. Sets `config.llm.localModelId` and `config.llm.modelId`.
3. Saves `settings.json`.
4. Removes the marker.
5. Kicks off the in-app download (visible in Settings &rarr; Models).

If both markers somehow exist, E4B wins (the "larger choice" heuristic).
In practice this shouldn't happen because each model's postinstall
removes the counterpart's marker before writing its own.

## Layout

```
Tools/packaging/
├── README.md                      this file
├── TROUBLESHOOTING.md             symptom → fix playbook
├── Distribution.xml               installer UI
├── build_pkg.sh                   the one script
├── resources/
│   ├── welcome.html
│   └── conclusion.html
└── scripts/
    ├── model_e2b/postinstall      writes .download-e2b-on-launch
    └── model_e4b/postinstall      writes .download-e4b-on-launch
```

## Keeping things in sync

Marker filenames must match between the postinstall scripts and
`Sources/App/Storage.swift`. Model IDs used in
`AppState.applyPkgModelMarker()` must match the IDs in
`Sources/Providers/LlamaCpp/LlamaCppModels.swift` (`gemma-4-e2b`,
`gemma-4-e4b`).

## Known limitations (current Debug build)

- **Unsigned**: users see a Gatekeeper warning. Right-click → Open, or
  `xattr -cr <pkg-path>` before opening.
- **Debug config**: the build is larger and slower than Release.
  Release is blocked by an upstream LocalLLMClient issue; see
  TROUBLESHOOTING.md §8.
- **"0 KB" in model row size**: model components carry no payload, so
  the size column displays zero. The choice titles already include
  `(~3 GB)` / `(~4.8 GB)` so users know the real download size.
