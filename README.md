# ptop — PowerShell Top for Windows
NOTE: This was made 100% by Gemini Argon just for myself, feel free to use it if you want.

A fast, flicker-free, **zero-admin** `btop`-style Terminal UI (TUI) system and GPU monitor for Windows written in a single standalone PowerShell script.

Most Windows terminal hardware monitors (`btop4win-LHM`, OpenHardwareMonitor-based tools) require Administrator privileges to load kernel drivers just to read GPU utilization, or fail to display overall GPU compute usage due to Windows WDDM driver quirks (`bottom`). **`ptop`** runs entirely in standard user space with zero external dependencies and sub-millisecond native system polling.

---

## ✨ Features

* **Zero Admin Privileges Required:** Works out-of-the-box on standard user accounts, SSH sessions, and locked-down workstations.
* **Full NVIDIA GPU Telemetry:**
  * Live **GPU Core %** meter + history sparkline graph
  * **VRAM** usage (`GiB` used/total + `%` bar)
  * **Power Draw** (`W / Cap W` + meter bar)
  * **GPU Temperature (`°C`)**, **Fan Speed (`%`)**, **Graphics & Memory Clocks (`MHz`)**, **Memory Controller %**, and **P-State**
  * **Per-Process GPU Activity:** Highlights processes actively running on the GPU (`● RTX 3080 (Active)` / SM%)
* **AMD / Intel / Other GPUs (fallback):** When `nvidia-smi` isn't available, ptop reads the vendor-neutral Windows GPU performance counters (the same ones Task Manager uses) for **GPU %**, **VRAM**, and **per-process GPU activity**. Temperature, power, fan and clocks are NVIDIA-only.
* **Sub-Millisecond Native CPU & RAM Polling:**
  * Uses inline C# P/Invoke (`GetSystemTimes`, `GlobalMemoryStatusEx`, and `NtQuerySystemInformation`) instead of slow WMI queries (`< 0.2ms` overhead)
  * Press **`P`** to toggle a live **Per-Core CPU Utilization Grid** across all logical processors
* **Disks & Live Network Throughput:**
  * Color-graded capacity bars for fixed drives
  * Real-time **Download (`▼`)** and **Upload (`▲`)** throughput (`KB/s` / `MB/s`) plus session totals
* **Interactive Process Manager:**
  * Sort by **CPU (`C`)**, **Memory (`M`)**, or **Active GPU Processes (`G`)**
  * Navigate rows with **`↑` / `↓`** and terminate processes directly with **`K`** or **`Del`**
* **5 Built-in 24-bit TrueColor Themes:**
  * Cycle live with **`T`**: **Midnight**, **Cyberpunk**, **Matrix**, **Gruvbox**, and **Nord**
* **Flicker-Free Rendering:**
  * Uses the ANSI alternate screen buffer (`?1049h`) and single-write frame buffering

---

## 🖥️ Interface Layout

```bash
 ptop │ WORKSTATION │ Up: 2d 08h 55m │ 1000ms     [P]Cores [T]heme [C/M/G]Sort [↑↓/K]Kill [Q]uit │ 15:30:00
╭─ CPU (13th Gen Intel Core i5-13600KF) ────────────╮╭─ GPU (NVIDIA GeForce RTX 3080 [P0]) ─────────────────╮
│ CPU Total  ████████░░░░░░░░░░░░░░░░░░░░░░   26.4% ││ GPU Core   ██████████████████░░░░░░░░░░░░   61.0%    │
│ History    ▁▂▃▄▃▂▁▂▃▅▆▄▃▂▁▂▃▄▃▂▁▂▃▄▅▄▃▂▁▂▃▄▃      ││ History    ▁▁▂▄▆▇▆▅▄▅▆▇█▇▆▅▄▅▆▆▅▄▃▄▅▆▅▄▅▆▅       │
│ RAM        █████████████░░░░░░░░░░░░░░░░░ 14.2/32G││ VRAM       ██████████░░░░░░░░░░░░  4.8/10.0G (48%)   │
│ Commit/Swp █░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  0.1/2.0G││ Power      ████████████████░░░░░░  245.0/340W        │
│ Cores: 20 ([P] Per-Core)   Procs: 248             ││ Temp: 64°C  Fan: 58%  Clocks: 1950/9501MHz  MemCtrl:22%│
├─ Disks ───────────────────────────────────────────┤├─ Network ────────────────────────────────────────────┤
│ C:         ████████████████████░░░░░░  634/930G   ││ ▼ Download 12.45 MB/s     Total RX: 48.21 GB         │
│ D:         █████████████████████░░░░░  658/931G   ││ ▲ Upload   420.5 KB/s     Total TX: 6.14 GB          │
╰───────────────────────────────────────────────────╯╰──────────────────────────────────────────────────────╯
╭─ Processes (Sort: GPU │ GPU Apps: 12 │ Theme: Midnight) ──────────────────────────────────────────────────╮
│     PID  PROCESS NAME                            CPU %   MEM (MB)   MEM %  GPU STATUS                     │
│    4828  explorer                                 1.2%     184.2M    0.6%  ● RTX 3080 (Active)            │
│   26604  WindowsTerminal                          0.8%      92.4M    0.3%  ● RTX 3080 (Active)            │
╰───────────────────────────────────────────────────────────────────────────────────────────────────────────╯
```

---

## 🚀 Quick Start

### 1. Clone the repository
```bash
git clone https://github.com/stavrostzagadouris/powershellTop.git
cd powershellTop
```

### 2. Run directly
```bash
./ptop.ps1
```

### 3. Install the `ptop` global alias (optional)
Run the included installer script to add `ptop` to your PowerShell `$PROFILE`:
```bash
./install.ps1
```

Or add the alias manually:
```bash
Add-Content -Path $PROFILE -Value "`nSet-Alias -Name ptop -Value '$PWD\ptop.ps1'"
. $PROFILE
ptop
```

---

## ⌨️ Keyboard Controls

| Key | Action |
| :--- | :--- |
| **`C`** | Sort processes by **CPU %** |
| **`M`** | Sort processes by **Memory Usage** |
| **`G`** | Sort **Active GPU processes** to the top |
| **`P`** | Toggle **Per-Core CPU Utilization** grid |
| **`T`** | Cycle **Color Themes** (*Midnight → Cyberpunk → Matrix → Gruvbox → Nord*) |
| **`↑` / `↓`** | Move process selection highlight up / down |
| **`K` / `Del`** | Terminate (kill) the currently highlighted process |
| **`+` / `-`** | Speed up / slow down the refresh interval (`250ms` – `5000ms`) |
| **`Q` / `Esc`** | Quit `ptop` and restore the terminal screen |

---

## ⚙️ Command-Line Options

You can customize the starting refresh interval in milliseconds (default `1000`):

```bash
ptop -RefreshMs 500
```

---

## 🧠 How It Works Without Admin

1. **CPU Total & Per-Core Metrics:** Compiled at runtime via `Add-Type` C# P/Invoke against `kernel32.dll!GetSystemTimes` and `ntdll.dll!NtQuerySystemInformation(SystemProcessorPerformanceInformation)`. This completely bypasses WMI/CIM performance counter lag and requires zero elevation.
2. **Physical & Virtual Memory:** Queries `kernel32.dll!GlobalMemoryStatusEx` directly in memory.
3. **GPU Card & Process Telemetry:** Queries user-space NVML via `nvidia-smi` for card-level utilization, VRAM, power, thermals, clocks, and `nvidia-smi pmon` for active WDDM/TCC GPU processes.

---

## 🙌 Credits

Created by **Argo** (*Gemini 4 Argon*) in collaboration with **stavros**.

## 📄 License

Released under the [MIT License](LICENSE).
