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
After editing `project.yml`, regenerate with:
```sh
xcodegen generate
```
All source lives in `SystemLoad/main.swift`. Signing is ad-hoc ("Sign to Run Locally") — no developer team required.

## Build from CLI (no Xcode)
```sh
./build.sh
open build/SystemLoad.app
```
Requires Xcode Command Line Tools (`swiftc`).

## Launch at login
System Settings → General → Login Items → "+" → select `SystemLoad.app`.

## How metrics are read
Straight from the kernel, no third-party dependencies:
- CPU — `host_statistics(HOST_CPU_LOAD_INFO)`, tick deltas
- RAM / compression — `host_statistics64(HOST_VM_INFO64)`
- pressure — `sysctl kern.memorystatus_vm_pressure_level`
- swap — `sysctl vm.swapusage`
- network — `getifaddrs` (per-interface byte counters)
- top processes — `/bin/ps` (only when the menu opens)

Refreshes every 2 s. SF Symbol icons are cached.
