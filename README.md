# ☁️ RemoteLibrary KOReader Plugin

[![KOReader](https://img.shields.io/badge/KOReader-Plugin-blueviolet.svg?style=for-the-badge)](https://github.com/koreader/koreader)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg?style=for-the-badge)](https://www.gnu.org/licenses/gpl-3.0)
[![Lua](https://img.shields.io/badge/Lua-5.1%20%2F%20JIT-orange.svg?style=for-the-badge)](https://www.lua.org/)

A feature-rich KOReader plugin designed to seamlessly overlay your remote cloud library on top of your local e-reader filesystem. With **RemoteLibrary**, you can browse, download, and open files from your cloud storage providers on-demand as if they were stored locally.

---

## ✨ Key Features

*   **🌐 Transparent Overlaying:** Displays remote folders and files seamlessly inside your local `FileChooser` view, marked with a clean `[Cloud]` prefix.
*   **⚡ On-Demand Downloads:** Simply tap a remote file to download and open it instantly.
*   **📁 Smart Directory Sync:** Integrates with KOReader's native `cloudstorage` plugin to support WebDAV, FTP, Dropbox, and other cloud providers.
*   **🚀 Offline Maps:** Caches your remote library structure (`remotelibrary_map.lua`) for blazing-fast browsing without constant network requests.
*   **🛠️ UI Extensions:** Directly hooks into KOReader's file manager settings and metadata providers to prevent unnecessary network overhead during file preview.

---

## 🛠️ How It Works (Architecture)

```mermaid
graph TD
    A[FileChooser:getList] -->|Intercepts list| B{Check Local Directory}
    B -->|Under home_dir| C[Query remotelibrary_map.lua]
    B -->|Outside home_dir| D[Return Local Files Only]
    C -->|Overlay| E[Add '[Cloud]' proxies for directories and files]
    E --> F[Display merged file list]
    
    F -->|Tap on [Cloud] file| G[Download & Open]
    G -->|Invoke| H[cloudstorage provider]
    H -->|Saves file locally| I[Open via FileManager]
```

> [!NOTE]
> The plugin uses Lua metatable extensions to patch standard KOReader widgets like `FileChooser`, `BookInfo`, and `BookInfoManager` dynamically. This ensures that metadata scanners do not block when encountering proxy files that haven't been downloaded yet.

---

## ⚙️ Installation & Setup

### 1. Copy to Plugins
Place the `RemoteLibrary.koplugin` folder inside your KOReader plugins directory:
```bash
koreader/plugins/RemoteLibrary.koplugin/
```

### 2. Configure Cloud Storage
1. Ensure the KOReader **Cloud storage** plugin is enabled.
2. Add a cloud storage provider (e.g., WebDAV) inside KOReader.
3. Open KOReader's Top Menu -> **Tools (gear icon)** -> **Remote Library** -> **Settings**.
4. Tap **Cloudstorage directory** and select your desired provider/folder.

### 3. Generate File Map
To populate the overlay, tap **Reload** under the **Remote Library** menu. This scans your remote directory recursively and saves the mapping file.

---

## 💾 Storage & Configuration Files

All configuration files are kept safe inside the KOReader data storage folder:

| File Name | Purpose |
| :--- | :--- |
| `remotelibrary.lua` | Stores the active Cloudstorage directory reference. |
| `remotelibrary_map.lua` | The mapped remote directory tree structure. |

---

## 🧪 Running Tests

To verify code sanity and check for regressions, run:

```bash
./run_tests.sh
```

---

*Made with ❤️ for KOReader.*
