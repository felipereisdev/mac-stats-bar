<p align="center">
  <img src="docs/icon.png" width="128" alt="MacStatsBar icon">
</p>

<h1 align="center">MacStatsBar</h1>

<p align="center">
  Your Mac's CPU, GPU, RAM, swap, disk, network and thermal state, right in the menu bar — with Docker cleanup and suggestions to free memory.
</p>

<p align="center">
  <a href="https://github.com/felipereisdev/mac-stats-bar/releases/latest"><img src="https://img.shields.io/github/v/release/felipereisdev/mac-stats-bar?label=download&color=4c6bff" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-7b5cff" alt="Universal">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/felipereisdev/mac-stats-bar?color=22b39a" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://buymeacoffee.com/felipereisdev"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" height="44" alt="Buy Me a Coffee"></a>
</p>

<p align="center">
  <img src="docs/screenshot.png" width="760" alt="MacStatsBar open in the menu bar">
</p>

Available in **English** and **Brazilian Portuguese**, following your system language.

## Features

- **Compact menu bar item:** each metric shows a small label on top and its value below. Columns have a fixed width, so nothing jumps around as values change.
- **Color alerts:** a value turns orange, then red, once it crosses thresholds you choose. RAM follows macOS **memory pressure** (the same indicator Activity Monitor uses) rather than the percentage used, which is always high on macOS and misleading.
- **Detailed menu:** GB used out of total, swap, performance and efficiency cores, disk reads and writes, network download and upload, and the thermal state.
- **Top consumers:** the 5 apps using the most memory or CPU, with helper processes added to their app (all of Chrome shows up as one row).
- **Quit from the menu:** hover over an app and click **Quit**. A confirmation shows the app's observed memory usage. System processes are marked with 🔒 and can't be quit.
- **Discreet thermometer:** a 🌡 only appears in the menu bar when the Mac gets hot enough to throttle.
- **Docker cleanup:** one recommended action removes unused images and old build cache while preserving all containers, their images, volumes and networks.
- **Activity suggestions:** optional local observations identify apps and containers with little activity. Review the evidence, quit or stop manually, ignore for 24 hours, or exclude a resource.
- **Lightweight by default:** the top process list is collected only while the menu is open. Optional activity observation samples apps in the background every 30 seconds; container metrics are collected only when observation is enabled.
- **Private:** nothing leaves your Mac. The app makes no network requests and collects no usage data.

<p align="center">
  <img src="docs/menubar-all.png" width="560" alt="Menu bar with every column enabled"><br>
  <sub>Every column enabled, including the optional network (↓/↑) and disk activity (R/W) columns.</sub>
</p>

## Settings

Open them from the menu with **Settings…** (⌘,). You can choose:

- which columns appear in the menu bar;
- the percentages at which values turn orange and red;
- whether the RAM color follows memory pressure or the percentage used;
- the refresh interval (1, 2 or 5 seconds);
- whether the app opens at login;
- the Docker CLI path, activity observation window, and resources excluded from suggestions.

## Docker and activity

Open **Clean Docker…** or **Free memory…** from the menu. The resource window contains only these two tools. Docker integration requires an existing Docker-compatible engine and its docker CLI; the app does not install or start an engine. Local Unix socket contexts are supported, including Docker Desktop and OrbStack. Remote contexts are rejected before connecting.

**Clean Docker** offers one action: **Clean up images and cache…**. It removes images that no running or stopped container references, including tagged images, when the daemon's 24-hour filter allows them. It also cleans eligible build cache unused for 7 days, targeting a 2 GB reserve. All containers, their referenced images, volumes and networks are preserved. Removed images may need to be downloaded or built again; future builds can take longer.

Before cleanup, the app shows a conservative estimate from read-only metadata on the same local engine. It applies the daemon's image age filter and container references, cache age and type rules, transitive dependencies, shared-size information and the cache reserve. Old cache needed by retained recent cache is excluded. Aggregate reclaimable totals are never used as a fallback. Partial or unsupported metadata is identified; shared data and whole-record deletion can change the actual recovery.

When a complete analysis estimates no significant recovery, the action becomes **Refresh analysis**, which reads metadata without pruning. A useful estimate offers **Clean up images and cache…**. The confirmed last cleanup result is displayed separately, including explicit zero-byte, missing-measurement and failed outcomes.

Analysis refreshes at most once per minute while its tab is visible, and is forced by Refresh, before cleanup review and after cleanup. Reviews expire after 60 seconds, and actions recheck the context and engine. Estimates and prior results are cleared when the engine or CLI changes. Free space on the Mac may update later. A timeout can leave an uncertain result; refresh before repeating an action.

Cache cleanup targets the displayed engine. CLI versions that cannot guarantee that scope report the category as unavailable. Application activity includes attributable descendant work processes, such as compilers and interpreters, and identifiable bundle-clone helpers.

**Free memory** suggests running apps and containers with little activity and observed memory usage. Activity observation is **off by default**. When enabled, it continues with the window closed and keeps only a bounded in-memory history. Choose a 15, 30 or 60 minute window. Suggestions require adequate observations, CPU below 1%, and, for running containers, low network and block I/O. App suggestions also require at least 256 MiB of observed memory and no foreground activation. System apps, other users, persistent container mounts, protected infrastructure and resources marked “Never suggest” are excluded. Generic groups such as node are never offered for bulk termination.

Low activity does not prove a resource is unused. Every action is manual and confirmed. Sleep/wake, process reuse, container recreation and engine changes restart observations. Stopped containers are not suggested for removal because deleting them does not free running memory. Container memory is measured inside the Linux VM and does not guarantee the same amount of recoverable Mac RAM.

<p align="center">
  <img src="docs/preferences.png" width="400" alt="Settings window">
</p>

## Installation

1. Download `MacStatsBar-x.y.z.zip` from the [releases page](https://github.com/felipereisdev/mac-stats-bar/releases/latest).
2. Unzip it and drag **MacStatsBar.app** into your **Applications** folder.
3. Open the app. It shows up in the menu bar, with no Dock icon.

> [!NOTE]
> The app is ad-hoc signed and not notarized by Apple, so the first time you open it macOS warns that it can't verify the developer. To allow it, go to **System Settings › Privacy & Security** and click **Open Anyway**. Alternatively, run this in Terminal:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/MacStatsBar.app
> ```

To stop the app from opening at login, use its Settings or **System Settings › General › Login Items**.

## Building from source

You need Swift 5.9 or later. The Command Line Tools are enough (`xcode-select --install`); Xcode isn't required.

```bash
git clone https://github.com/felipereisdev/mac-stats-bar.git
cd mac-stats-bar
./install.sh            # builds, installs to /Applications and opens the app
```

Other scripts:

| Command | What it does |
| --- | --- |
| `Scripts/build-app.sh` | Builds `build/MacStatsBar.app` (`--universal` for arm64 and x86_64) |
| `Scripts/package.sh` | Creates the universal `.zip` used for releases |
| `script/build_and_run.sh` | Builds and launches the local app bundle |
| `script/build_and_run.sh --resources` | Builds and opens the Docker cleanup window |
| `swift Scripts/make-icon.swift` | Redraws the icon (`Resources/AppIcon.icns` and `docs/icon.png`) |

Run the XCTest suite with Xcode selected (the app itself still builds with Command Line Tools):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Read-only integration tests against your current **local** Docker engine are opt-in:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  MACSTATS_DOCKER_READ_ONLY_TESTS=1 swift test --filter DockerIntegrationTests
```

The ordinary suite uses scripted Docker responses for mutations and does not stop or prune real resources.

## Where the numbers come from

The Mac metrics below come from public macOS APIs and do not require an administrator password. Each one was checked against the reference tool listed. Docker cleanup estimates and container activity come from the selected local Docker engine.

| Metric | Source | Checked against |
| --- | --- | --- |
| CPU | `host_statistics` (`HOST_CPU_LOAD_INFO`), difference between two readings | `iostat` (us + sy) |
| GPU | `IOAccelerator` › `PerformanceStatistics` › `Device Utilization %` (instantaneous value) | `ioreg` |
| Memory | Activity Monitor's formula: app memory + wired + compressed (`host_statistics64`) | `vm_stat` |
| Memory pressure | `kern.memorystatus_vm_pressure_level` | `memory_pressure` |
| Swap | `vm.swapusage` | `sysctl vm.swapusage` |
| Disk space | Capacity available "for important usage", the same figure Finder shows | Finder |
| Disk activity | `IOBlockStorageDriver` › `Statistics` | `iostat` |
| Network | Physical interface (`en*`) counters via `NET_RT_IFLIST2` | `netstat -ib` |
| Thermal state | `ProcessInfo.thermalState` | `pmset -g therm` |
| Processes | `top` (memory as in Activity Monitor, and %CPU), grouped by app | Activity Monitor |

A few notes:

- **Disk space:** space macOS can free on its own, such as caches and local snapshots, counts as free, just like in Finder. That's why "used" can be lower than what `df` or `diskutil` report.
- **Network:** VPNs and the virtual networks of VMs and containers are excluded so the same traffic isn't counted twice. Interface counters are only 32 bits wide for unprivileged apps, so the app handles the wraparound that happens every 4 GB.
- **Per-app CPU:** measured per core, as in Activity Monitor, so an app can go above 100%.
- **Temperature:** macOS doesn't expose readings in degrees without privileged access. The app shows the thermal state the system reports: Normal, Fair, Serious or Critical.

## Project structure

```
Sources/MacStatsBar/
├── main.swift            # AppDelegate: menu bar item, menu, timer, quitting apps, Settings
├── SystemSampler.swift   # Collects CPU, GPU, memory, swap, disk, network and thermal state
├── TopSampler.swift      # Processes via `top`, grouped by app
├── StatsModel.swift      # Observable state, alert levels and locale-aware formatting
├── Settings.swift        # Settings (UserDefaults) and open at login
└── Views.swift           # SwiftUI: menu bar, menu, skeleton and Settings
Resources/Localization/   # en and pt-BR strings
```

## Support the project

If MacStatsBar helps you every day, consider buying me a coffee ☕. It helps keep the project going and brings new features.

<a href="https://buymeacoffee.com/felipereisdev"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" height="44" alt="Buy Me a Coffee"></a>

## License

[MIT](LICENSE) © Felipe Reis
