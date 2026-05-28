# System Load

A lightweight native macOS menu-bar resource monitor. Swift + AppKit — no Electron, no web view (~40 MB RAM, ~0% CPU at idle).

Menu bar shows `􀫥 CPU%  􀫦 RAM%`. Click to open a details popup.

## What it shows
- **CPU** — load % + a history sparkline (~2 min), color-coded green/orange/red
- **RAM** — used % and GB. Computed the Activity Monitor way (App + Wired + Compressed), not "everything but free" — so the number is meaningful instead of pinned near 99%
- **Compressed / Pressure** — compressor size and memory-pressure level (🟢 Normal / 🟡 Warning / 🔴 Critical) — the real low-memory signal
- **Swap** — used / total
- **Network** — ↓ / ↑ throughput
- **Top 3 by CPU** and **Top 3 by RAM** (sampled via `ps` when the menu opens)

## Develop (Xcode)
```sh
open SystemLoad.xcodeproj    # then ⌘R to build & run
```
The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
After editing `project.yml` — or adding/removing a source file — regenerate with:
```sh
xcodegen generate
```
Source lives in `SystemLoad/` (`main.swift` — metrics + menu bar; `Settings.swift` — preferences store + window; `Updater.swift` — Sparkle). Dev/CI builds are ad-hoc signed ("Sign to Run Locally") — no developer team required. Auto-updates come from [Sparkle](https://sparkle-project.org) (added via Swift Package Manager).

## Build from CLI
```sh
./build.sh
open build/SystemLoad.app
```
`build.sh` wraps `xcodebuild` (a quick unsigned Release build). Sparkle is a Swift Package, so the Xcode toolchain is required — the old raw-`swiftc` path is gone.

## Releasing
Signed, notarized releases (ZIP + DMG) with a Sparkle appcast are produced by `scripts/release.sh` and shipped by `scripts/publish.sh`. See [`scripts/RELEASE.md`](scripts/RELEASE.md).

## Settings
Open from the menu → **Settings…** (⌘,):
- **Launch at login** — registers the app as a login item via `SMAppService` (macOS 13+). Takes effect when the app runs from a stable location like `/Applications`; from a `build/` or `DerivedData` copy macOS may refuse to register it.
- **Refresh interval** — 1 / 2 / 3 / 5 / 10 s.
- **Menu bar** — show CPU and/or RAM (at least one stays on), and SF Symbol icons vs. plain `CPU`/`RAM` text labels.
- **Software Update** — toggle automatic update checks (daily) and check now. There's also a **Check for Updates…** item in the menu.

Preferences are stored in `UserDefaults`; launch-at-login state lives in the system (also editable in System Settings → General → Login Items). Update checks use Sparkle against the appcast feed.

## How metrics are read
Straight from the kernel, no third-party dependencies:
- CPU — `host_statistics(HOST_CPU_LOAD_INFO)`, tick deltas
- RAM / compression — `host_statistics64(HOST_VM_INFO64)`
- pressure — `sysctl kern.memorystatus_vm_pressure_level`
- swap — `sysctl vm.swapusage`
- network — `getifaddrs` (per-interface byte counters)
- top processes — `/bin/ps` (only when the menu opens)

Refreshes every 2 s by default (configurable in Settings). SF Symbol icons are cached.
