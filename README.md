# ☁️ RemoteLibrary KOReader Plugin

[![CI](https://github.com/dani84bs/RemoteLibrary.koplugin/actions/workflows/test.yml/badge.svg)](https://github.com/dani84bs/RemoteLibrary.koplugin/actions/workflows/test.yml)
[![KOReader](https://img.shields.io/badge/KOReader-Plugin-blueviolet.svg)](https://github.com/koreader/koreader)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

RemoteLibrary overlays a cloud-storage library onto KOReader's local file browser, so you can see and open books that haven't been downloaded yet — as if they were already on the device.

## Features

- **Transparent overlay** — remote folders and files appear inside the normal `FileChooser` view, tagged `[Cloud]`.
- **On-demand downloads** — tap a `[Cloud]` file to download and open it; folders materialize as you navigate into them.
- **Built on `cloudstorage`** — reuses KOReader's own cloud storage plugin, so any provider it supports (WebDAV, FTP, Dropbox, …) works here.
- **Cached remote map** — the directory tree is scanned once and cached to `remotelibrary_map.lua` for instant, offline browsing. A WebDAV target uses a single-request fast scan when the server allows it, falling back to a per-folder scan otherwise.
- **`[Refresh Cloud]` action entry** — a pinned row in the file browser that triggers a rescan without leaving the folder view.
- **Metadata-safe** — patches KOReader's book info and cover lookups so proxy files never trigger a network fetch just to render a list.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for how the overlay is implemented, and [`CONTEXT.md`](CONTEXT.md) for the domain vocabulary (remote map, proxy, fast/slow scan, action entry).

## Installation

Copy this folder into your KOReader plugins directory:

```bash
koreader/plugins/RemoteLibrary.koplugin/
```

## Setup

1. Enable KOReader's **Cloud storage** plugin and add a provider (WebDAV, FTP, …).
2. Open KOReader's Tools menu → **Remote Library** → **Settings** → **Cloudstorage directory**, and pick the provider/folder to overlay.
3. From the **Remote Library** menu, tap **Reload** to scan the remote directory and build the map. Use the file browser's `[Refresh Cloud]` entry any time you want to rescan without opening the menu.

## Configuration files

Stored in KOReader's settings directory:

| File | Purpose |
| :--- | :--- |
| `remotelibrary.lua` | The configured cloudstorage directory. |
| `remotelibrary_map.lua` | The cached remote directory tree. |

## Testing

Unit tests run against a checked-out KOReader tree:

```bash
./run_tests.sh <path_to_koreader_root>
```

End-to-end tests exercise a real WebDAV server and are not wired into CI:

```bash
./run_e2e_tests.sh <path_to_koreader_root>
```

## License

MIT — see [LICENSE](LICENSE).
