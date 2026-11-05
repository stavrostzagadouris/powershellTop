<#
.SYNOPSIS
    ptop.ps1 - PowerShell Top: Zero-Admin System & GPU Monitor for Windows
.DESCRIPTION
    A fast, flicker-free terminal UI system monitor for Windows that requires
    NO administrator privileges. Displays live CPU (overall + per-core via native
    NtQuerySystemInformation), GPU (Util %, VRAM, Temp, Power, Fan, Clocks via
    nvidia-smi), RAM, Disks, Network RX/TX, and Top Processes with interactive
    selection, process termination, and color themes.
.NOTES
    Author  : Built with Argo (Gemini 4 Argon)
    License : MIT
    Controls:
      [Q] / [Esc] : Quit
      [Up]/[Down] : Select process in table
      [K] / [Del] : Kill selected process
      [P]         : Toggle Per-Core CPU bars view
      [T]         : Cycle color themes (Midnight, Cyberpunk, Matrix, Gruvbox, Nord)
      [C]         : Sort processes by CPU%
      [M]         : Sort processes by Memory
      [G]         : Prioritize GPU processes
      [+] / [-]   : Increase / Decrease refresh speed
#>

param(
    [int]$RefreshMs = 1000
)

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Compile ultra-fast Win32 + NT native helpers (zero admin required)
if (-not ('PTopNative' -as [type])) {
    $NativeCode = @"
using System;
using System.Runtime.InteropServices;

public static class PTopNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct FILETIME {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
        public ulong ToUInt64() {
            return ((ulong)dwHighDateTime << 32) | dwLowDateTime;
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public class MEMORYSTATUSEX {
        public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION {
        public long IdleTime;
        public long KernelTime;
        public long UserTime;
        public long DpcTime;
        public long InterruptTime;
        public uint InterruptCount;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetSystemTimes(out FILETIME lpIdleTime, out FILETIME lpKernelTime, out FILETIME lpUserTime);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);

    [DllImport("ntdll.dll")]
    public static extern int NtQuerySystemInformation(int SystemInformationClass, IntPtr SystemInformation, int SystemInformationLength, out int ReturnLength);

    private static ulong _prevIdle = 0;
    private static ulong _prevKernel = 0;
    private static ulong _prevUser = 0;

    private static long[] _prevCoreIdle;
    private static long[] _prevCoreTotal;

    public static double GetCpuUsage() {
        FILETIME idle, kernel, user;
        if (!GetSystemTimes(out idle, out kernel, out user)) return 0.0;
        ulong i = idle.ToUInt64();
        ulong k = kernel.ToUInt64();
        ulong u = user.ToUInt64();

        ulong diffIdle = i - _prevIdle;
        ulong diffKernel = k - _prevKernel;
        ulong diffUser = u - _prevUser;
        ulong total = diffKernel + diffUser;

        _prevIdle = i;
        _prevKernel = k;
        _prevUser = u;

        if (total == 0) return 0.0;
        double busy = (double)(total - diffIdle) / total * 100.0;
        return Math.Max(0.0, Math.Min(100.0, busy));
    }

    public static double[] GetPerCoreUsage() {
        int coreCount = Environment.ProcessorCount;
        int structSize = Marshal.SizeOf(typeof(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION));
        int bufSize = structSize * coreCount;
        IntPtr buf = Marshal.AllocHGlobal(bufSize);
        double[] result = new double[coreCount];

        try {
            int retLen;
            // SystemProcessorPerformanceInformation = 8
            int status = NtQuerySystemInformation(8, buf, bufSize, out retLen);
            if (status != 0) return result;

            if (_prevCoreIdle == null || _prevCoreIdle.Length != coreCount) {
                _prevCoreIdle = new long[coreCount];
                _prevCoreTotal = new long[coreCount];
            }

            for (int c = 0; c < coreCount; c++) {
                IntPtr itemPtr = IntPtr.Add(buf, c * structSize);
                var info = (SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION)Marshal.PtrToStructure(itemPtr, typeof(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION));
                long idle = info.IdleTime;
                long total = info.KernelTime + info.UserTime;

                long dIdle = idle - _prevCoreIdle[c];
                long dTotal = total - _prevCoreTotal[c];

                _prevCoreIdle[c] = idle;
                _prevCoreTotal[c] = total;

                if (dTotal > 0) {
                    double pct = (double)(dTotal - dIdle) / dTotal * 100.0;
                    result[c] = Math.Max(0.0, Math.Min(100.0, pct));
                }
            }
        } finally {
            Marshal.FreeHGlobal(buf);
        }
        return result;
    }

    public static MEMORYSTATUSEX GetMemory() {
        var mem = new MEMORYSTATUSEX();
        GlobalMemoryStatusEx(mem);
        return mem;
    }
}
"@
    Add-Type -TypeDefinition $NativeCode -Language CSharp
}

# Prime CPU counters
[void][PTopNative]::GetCpuUsage()
[void][PTopNative]::GetPerCoreUsage()

# Detect CPU Name once via registry
$CpuName = (Get-ItemProperty "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0").ProcessorNameString
if (-not $CpuName) { $CpuName = "CPU" }
$CpuName = $CpuName.Trim()
$LogicalCores = [Environment]::ProcessorCount

# Color Themes (24-bit TrueColor)
$ESC = [char]27
$Themes = @(
    @{
        Name      = "Midnight"
        Border    = "$ESC[38;2;90;105;135m"
        Title     = "$ESC[1;38;2;220;230;255m"
        SubTitle  = "$ESC[38;2;140;160;200m"
        Text      = "$ESC[38;2;210;220;235m"
        Dim       = "$ESC[38;2;115;125;150m"
        Green     = "$ESC[38;2;100;230;145m"
        Cyan      = "$ESC[38;2;90;215;255m"
        Yellow    = "$ESC[38;2;255;210;90m"
        Orange    = "$ESC[38;2;255;145;75m"
        Red       = "$ESC[38;2;255;85;100m"
        Magenta   = "$ESC[38;2;205;130;255m"
        HeaderBg  = "$ESC[48;2;35;45;68m$ESC[1;38;2;190;215;255m"
        SelBg     = "$ESC[48;2;55;75;115m$ESC[1;38;2;255;255;255m"
        GpuTag    = "$ESC[1;38;2;118;255;3m"
    },
    @{
        Name      = "Cyberpunk"
        Border    = "$ESC[38;2;255;0;128m"
        Title     = "$ESC[1;38;2;0;255;255m"
        SubTitle  = "$ESC[38;2;255;105;180m"
        Text      = "$ESC[38;2;240;240;255m"
        Dim       = "$ESC[38;2;140;90;160m"
        Green     = "$ESC[38;2;0;255;180m"
        Cyan      = "$ESC[38;2;0;240;255m"
        Yellow    = "$ESC[38;2;255;240;0m"
        Orange    = "$ESC[38;2;255;120;0m"
        Red       = "$ESC[38;2;255;40;80m"
        Magenta   = "$ESC[38;2;255;0;255m"
        HeaderBg  = "$ESC[48;2;75;15;65m$ESC[1;38;2;0;255;255m"
        SelBg     = "$ESC[48;2;130;20;105m$ESC[1;38;2;255;255;0m"
        GpuTag    = "$ESC[1;38;2;0;255;160m"
    },
    @{
        Name      = "Matrix"
        Border    = "$ESC[38;2;30;140;50m"
        Title     = "$ESC[1;38;2;120;255;140m"
        SubTitle  = "$ESC[38;2;70;200;90m"
        Text      = "$ESC[38;2;160;245;170m"
        Dim       = "$ESC[38;2;55;115;65m"
        Green     = "$ESC[38;2;50;255;90m"
        Cyan      = "$ESC[38;2;110;255;160m"
        Yellow    = "$ESC[38;2;190;255;90m"
        Orange    = "$ESC[38;2;240;200;60m"
        Red       = "$ESC[38;2;255;90;90m"
        Magenta   = "$ESC[38;2;100;235;180m"
        HeaderBg  = "$ESC[48;2;15;55;25m$ESC[1;38;2;130;255;150m"
        SelBg     = "$ESC[48;2;30;95;45m$ESC[1;38;2;220;255;220m"
        GpuTag    = "$ESC[1;38;2;180;255;60m"
    },
    @{
        Name      = "Gruvbox"
        Border    = "$ESC[38;2;146;131;116m"
        Title     = "$ESC[1;38;2;251;241;199m"
        SubTitle  = "$ESC[38;2;213;196;161m"
        Text      = "$ESC[38;2;235;219;178m"
        Dim       = "$ESC[38;2;124;111;100m"
        Green     = "$ESC[38;2;184;187;38m"
        Cyan      = "$ESC[38;2;142;192;124m"
        Yellow    = "$ESC[38;2;250;189;47m"
        Orange    = "$ESC[38;2;254;128;25m"
        Red       = "$ESC[38;2;251;73;52m"
        Magenta   = "$ESC[38;2;211;134;155m"
        HeaderBg  = "$ESC[48;2;60;56;54m$ESC[1;38;2;250;189;47m"
        SelBg     = "$ESC[48;2;102;92;84m$ESC[1;38;2;251;241;199m"
        GpuTag    = "$ESC[1;38;2;184;187;38m"
    },
    @{
        Name      = "Nord"
        Border    = "$ESC[38;2;94;129;172m"
        Title     = "$ESC[1;38;2;236;239;244m"
        SubTitle  = "$ESC[38;2;136;192;208m"
        Text      = "$ESC[38;2;216;222;233m"
        Dim       = "$ESC[38;2;108;122;148m"
        Green     = "$ESC[38;2;163;190;140m"
        Cyan      = "$ESC[38;2;136;192;208m"
        Yellow    = "$ESC[38;2;235;203;139m"
        Orange    = "$ESC[38;2;208;135;112m"
        Red       = "$ESC[38;2;191;97;106m"
        Magenta   = "$ESC[38;2;180;142;173m"
        HeaderBg  = "$ESC[48;2;59;66;82m$ESC[1;38;2;136;192;208m"
        SelBg     = "$ESC[48;2;76;86;106m$ESC[1;38;2;236;239;244m"
        GpuTag    = "$ESC[1;38;2;163;190;140m"
    }
)
$ThemeIdx = 0
$C = $Themes[$ThemeIdx]
$C.Reset = "$ESC[0m"

function Get-MeterColor([double]$Pct) {
    if ($Pct -lt 40) { return $C.Green }
    if ($Pct -lt 70) { return $C.Cyan }
    if ($Pct -lt 85) { return $C.Yellow }
    return $C.Red
}

function Get-TempColor([double]$Temp) {
    if ($Temp -lt 55) { return $C.Green }
    if ($Temp -lt 72) { return $C.Yellow }
    if ($Temp -lt 83) { return $C.Orange }
    return $C.Red
}

function Format-Bar([double]$Pct, [int]$Width, [string]$Color = "") {
    if ($Width -lt 2) { return "" }
    $Pct = [Math]::Max(0.0, [Math]::Min(100.0, $Pct))
    if (-not $Color) { $Color = Get-MeterColor $Pct }
    $Filled = [int][Math]::Round(($Pct / 100.0) * $Width)
    $Empty  = $Width - $Filled
    return "$Color" + ("█" * $Filled) + "$($C.Dim)" + ("░" * $Empty) + "$($C.Reset)"
}

$SparkChars = @(' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█')
function Format-Sparkline([System.Collections.Generic.List[double]]$History, [int]$Width, [string]$Color) {
    if ($Width -lt 1) { return "" }
    $Count = $History.Count
    $Sb = [System.Text.StringBuilder]::new()
    [void]$Sb.Append($Color)
    $Start = $Count - $Width
    for ($i = $Start; $i -lt $Count; $i++) {
        if ($i -lt 0) {
            [void]$Sb.Append('·')
        } else {
            $v = [Math]::Max(0.0, [Math]::Min(100.0, $History[$i]))
            $idx = [int][Math]::Round(($v / 100.0) * 8)
            [void]$Sb.Append($SparkChars[$idx])
        }
    }
    [void]$Sb.Append($C.Reset)
    return $Sb.ToString()
}

function Pad-Ansi([string]$Str, [int]$Width) {
    $Clean = $Str -replace '\x1b\[[0-9;]*m', ''
    $Len = $Clean.Length
    if ($Len -gt $Width) {
        return $Clean.Substring(0, [Math]::Max(0, $Width - 1)) + "…"
    }
    return $Str + (" " * ($Width - $Len))
}

function Draw-BoxLine([string]$LeftContent, [int]$LeftWidth, [string]$RightContent, [int]$RightWidth) {
    $L = Pad-Ansi $LeftContent $LeftWidth
    $R = Pad-Ansi $RightContent $RightWidth
    return "$($C.Border)│$($C.Reset) $L $($C.Border)││$($C.Reset) $R $($C.Border)│$($C.Reset)"
}

function Draw-FullLine([string]$Content, [int]$InnerWidth) {
    $P = Pad-Ansi $Content $InnerWidth
    return "$($C.Border)│$($C.Reset) $P $($C.Border)│$($C.Reset)"
}

$HasNvidiaSmi = [bool](Get-Command nvidia-smi -CommandType Application -ErrorAction SilentlyContinue)

# Vendor-neutral fallback (AMD / Intel / anything WDDM): the "GPU Engine" and
# "GPU Adapter Memory" performance counters that Task Manager uses (no admin).
# Gives Util %, VRAM and per-process activity; no temp/power/fan/clocks.
$GpuEngineCat   = $null
$GpuMemCat      = $null
$PrevGpuEngine  = $null
$GpuAdapterName = "GPU"
$GpuAdapterMemMB = 1.0
if (-not $HasNvidiaSmi) {
    try {
        $GpuEngineCat  = [System.Diagnostics.PerformanceCounterCategory]::new('GPU Engine')
        $GpuMemCat     = [System.Diagnostics.PerformanceCounterCategory]::new('GPU Adapter Memory')
        $PrevGpuEngine = $GpuEngineCat.ReadCategory()['Utilization Percentage']
    } catch { $GpuEngineCat = $null }

    # Prefer a discrete AMD/NVIDIA adapter over integrated / remote-display ones
    $vc = Get-CimInstance Win32_VideoController | Where-Object { $_.AdapterCompatibility -notmatch 'Microsoft' } |
        Sort-Object { if ($_.AdapterCompatibility -match 'AMD|Advanced Micro|NVIDIA') { 0 } else { 1 } } |
        Select-Object -First 1
    if ($vc) {
        $GpuAdapterName  = $vc.Name
        $GpuAdapterMemMB = [Math]::Max(1.0, [double]$vc.AdapterRAM / 1MB)
        # AdapterRAM is a uint32 (caps at 4 GiB); the driver's registry value holds the real size
        Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue | ForEach-Object {
            $dp = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            $q  = $dp.'HardwareInformation.qwMemorySize'
            if ($dp.DriverDesc -eq $vc.Name -and $q) {
                if ($q -is [byte[]]) { $q = [BitConverter]::ToUInt64($q, 0) }
                $GpuAdapterMemMB = [Math]::Max(1.0, [double]$q / 1MB)
            }
        }
    }
}

function Get-GpuStatsGeneric($res) {
    if (-not $GpuEngineCat) { return $res }
    $res.Name       = $GpuAdapterName
    $res.ShortName  = if ($GpuAdapterName -match '(RX|RTX|GTX|Arc)\s+\S+') { $Matches[0] } else { ($GpuAdapterName -replace '^(AMD|Intel\(R\)|NVIDIA)\s+', '' -replace '\s+Graphics', '').Trim() }
    $res.PState     = ""
    $res.HasSensors = $false
    $res.MemTotMB   = $GpuAdapterMemMB

    # Utilization counters are rates: diff this sample against the previous one
    $cur = $GpuEngineCat.ReadCategory()['Utilization Percentage']
    $engUtil = @{}   # "luid|engtype" -> summed %
    $pidUtil = @{}
    foreach ($k in $cur.Keys) {
        $old = $script:PrevGpuEngine[$k]
        if (-not $old -or $k -notmatch '^pid_(\d+)_(luid_\w+?_phys_\d+)_eng_\d+_engtype_(.*)$') { continue }
        $v = [System.Diagnostics.CounterSample]::Calculate($old.Sample, $cur[$k].Sample)
        if ($v -le 0) { continue }
        $engUtil["$($Matches[2])|$($Matches[3])"] += $v
        $pidUtil[[int]$Matches[1]] += $v
    }
    $script:PrevGpuEngine = $cur
    foreach ($p in $pidUtil.Keys) { $res.GpuPids[$p] = [int][Math]::Min(100, [Math]::Round($pidUtil[$p])) }

    # Pick the adapter with the most dedicated VRAM in use (discrete GPU), then shared (iGPU)
    $mem = $GpuMemCat.ReadCategory()
    $luid = $mem['Dedicated Usage'].Keys | Sort-Object { $mem['Dedicated Usage'][$_].RawValue }, { $mem['Shared Usage'][$_].RawValue } -Descending | Select-Object -First 1
    if ($luid) {
        $res.MemUsedMB = [double]$mem['Dedicated Usage'][$luid].RawValue / 1MB
        # Like Task Manager: adapter util = busiest engine type (3D, Copy, VideoDecode, Compute...)
        $busiest = 0.0
        foreach ($ek in $engUtil.Keys) {
            if ($ek.StartsWith("$luid|")) { $busiest = [Math]::Max($busiest, $engUtil[$ek]) }
        }
        $res.Util = [Math]::Min(100.0, $busiest)
    }
    return $res
}

function Get-GpuStats {
    $res = @{
        Name      = if ($HasNvidiaSmi) { "NVIDIA GPU" } else { "No GPU detected" }
        ShortName = "GPU"
        Util      = 0.0
        MemUtil   = 0.0
        MemUsedMB = 0.0
        MemTotMB  = 1.0
        Temp      = 0.0
        PowerW    = 0.0
        PowerCapW = 1.0
        FanPct    = 0.0
        ClockCore = 0
        ClockMem  = 0
        PState    = "P0"
        GpuPids   = @{}
        HasSensors = $HasNvidiaSmi
    }
    if (-not $HasNvidiaSmi) { return (Get-GpuStatsGeneric $res) }

    $smi = & nvidia-smi --query-gpu=name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed,clocks.current.graphics,clocks.current.memory,pstate --format=csv,noheader,nounits 2>$null
    if ($smi) {
        $line = ($smi -split "`r?`n")[0]
        $parts = $line -split ',\s*'
        if ($parts.Count -ge 12) {
            $res.Name      = $parts[0]
            $res.ShortName = ($parts[0] -replace '^(NVIDIA\s+)?(GeForce\s+|RTX\s+A|Tesla\s+|Quadro\s+)?', '').Trim()
            if ($parts[0] -match 'RTX\s+\S+|GTX\s+\S+') { $res.ShortName = $Matches[0] }
            $res.Util      = [double]($parts[1] -as [double])
            $res.MemUtil   = [double]($parts[2] -as [double])
            $res.MemUsedMB = [double]($parts[3] -as [double])
            $res.MemTotMB  = [Math]::Max(1.0, [double]($parts[4] -as [double]))
            $res.Temp      = [double]($parts[5] -as [double])
            $res.PowerW    = [double]($parts[6] -as [double])
            $res.PowerCapW = [Math]::Max(1.0, [double]($parts[7] -as [double]))
            $res.FanPct    = [double]($parts[8] -as [double])
            $res.ClockCore = [int]($parts[9] -as [int])
            $res.ClockMem  = [int]($parts[10] -as [int])
            $res.PState    = $parts[11]
        }
    }

    $pmon = & nvidia-smi pmon -c 1 2>$null
    if ($pmon) {
        foreach ($pl in ($pmon -split "`r?`n")) {
            if ($pl -match '^\s*\d+\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)') {
                $pidVal = [int]$Matches[1]
                $smVal  = if ($Matches[3] -match '^\d+$') { [int]$Matches[3] } else { 0 }
                $res.GpuPids[$pidVal] = $smVal
            }
        }
    }
    return $res
}

# Histories
$CpuHist  = [System.Collections.Generic.List[double]]::new()
$GpuHist  = [System.Collections.Generic.List[double]]::new()
$VramHist = [System.Collections.Generic.List[double]]::new()
$RamHist  = [System.Collections.Generic.List[double]]::new()

# Network state
$PrevNetRx = 0L
$PrevNetTx = 0L
$PrevNetTime = [DateTime]::UtcNow
$NetIfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
    Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' }
foreach ($nic in $NetIfaces) {
    $st = $nic.GetIPv4Statistics()
    $PrevNetRx += $st.BytesReceived
    $PrevNetTx += $st.BytesSent
}

# Process CPU tracking state
$PrevProcTimes = @{}
$PrevProcStamp = [DateTime]::UtcNow
foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
    try { $PrevProcTimes[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds } catch {}
}

$SortBy = "CPU"       # CPU, MEM, GPU
$ShowPerCore = $true  # Toggle with [P] (default: on)
$SelectedIdx = 0      # Process row selection
$StatusMsg   = ""
$StatusUntil = [DateTime]::MinValue
$DisplayedProcs = @()

# Enter alternate screen buffer and hide cursor
Write-Host "$ESC[?1049h$ESC[?25l$ESC[2J" -NoNewline

try {
    while ($true) {
        $LoopStart = [DateTime]::UtcNow

        # Handle keyboard input without blocking
        while ([Console]::KeyAvailable) {
            $Key = [Console]::ReadKey($true)
            switch ($Key.Key) {
                'Q'          { return }
                'Escape'     { return }
                'C'          { $SortBy = "CPU"; $SelectedIdx = 0 }
                'M'          { $SortBy = "MEM"; $SelectedIdx = 0 }
                'G'          { $SortBy = "GPU"; $SelectedIdx = 0 }
                'P'          { $ShowPerCore = -not $ShowPerCore }
                'T'          {
                    $ThemeIdx = ($ThemeIdx + 1) % $Themes.Count
                    $C = $Themes[$ThemeIdx]
                    $C.Reset = "$ESC[0m"
                    $StatusMsg = "Theme: $($C.Name)"
                    $StatusUntil = [DateTime]::UtcNow.AddSeconds(2)
                }
                'UpArrow'    { $SelectedIdx = [Math]::Max(0, $SelectedIdx - 1) }
                'DownArrow'  { $SelectedIdx = $SelectedIdx + 1 }
                'K'          {
                    if ($DisplayedProcs.Count -gt $SelectedIdx) {
                        $target = $DisplayedProcs[$SelectedIdx]
                        try {
                            Stop-Process -Id $target.PID -Force -ErrorAction Stop
                            $StatusMsg = "Killed $($target.Name) (PID $($target.PID))"
                        } catch {
                            $StatusMsg = "Failed to kill PID $($target.PID): Access Denied"
                        }
                        $StatusUntil = [DateTime]::UtcNow.AddSeconds(3)
                    }
                }
                'Delete'     {
                    if ($DisplayedProcs.Count -gt $SelectedIdx) {
                        $target = $DisplayedProcs[$SelectedIdx]
                        try {
                            Stop-Process -Id $target.PID -Force -ErrorAction Stop
                            $StatusMsg = "Killed $($target.Name) (PID $($target.PID))"
                        } catch {
                            $StatusMsg = "Failed to kill PID $($target.PID): Access Denied"
                        }
                        $StatusUntil = [DateTime]::UtcNow.AddSeconds(3)
                    }
                }
                'OemPlus'    { $RefreshMs = [Math]::Max(250, $RefreshMs - 250) }
                'Add'        { $RefreshMs = [Math]::Max(250, $RefreshMs - 250) }
                'OemMinus'   { $RefreshMs = [Math]::Min(5000, $RefreshMs + 250) }
                'Subtract'   { $RefreshMs = [Math]::Min(5000, $RefreshMs + 250) }
            }
        }

        $WinW = [Math]::Max(84, [Console]::WindowWidth)
        $WinH = [Math]::Max(24, [Console]::WindowHeight)

        $AvailW = $WinW - 8
        $LeftW  = [int][Math]::Floor($AvailW / 2)
        $RightW = $AvailW - $LeftW
        $FullInnerW = $WinW - 4

        # 1. Collect CPU & RAM
        $CpuPct     = [PTopNative]::GetCpuUsage()
        $CorePcts   = [PTopNative]::GetPerCoreUsage()
        $MemInfo    = [PTopNative]::GetMemory()
        $RamTotalGB = $MemInfo.ullTotalPhys / 1GB
        $RamUsedGB  = ($MemInfo.ullTotalPhys - $MemInfo.ullAvailPhys) / 1GB
        $RamPct     = [double]$MemInfo.dwMemoryLoad

        $PageTotalGB = $MemInfo.ullTotalPageFile / 1GB
        $PageUsedGB  = ($MemInfo.ullTotalPageFile - $MemInfo.ullAvailPageFile) / 1GB
        $PagePct     = if ($PageTotalGB -gt 0) { ($PageUsedGB / $PageTotalGB) * 100.0 } else { 0.0 }

        # 2. Collect GPU
        $Gpu = Get-GpuStats
        $VramPct = ($Gpu.MemUsedMB / $Gpu.MemTotMB) * 100.0
        $PwrPct  = ($Gpu.PowerW / $Gpu.PowerCapW) * 100.0

        # Update histories
        $CpuHist.Add($CpuPct);   if ($CpuHist.Count -gt 120)  { $CpuHist.RemoveAt(0) }
        $GpuHist.Add($Gpu.Util); if ($GpuHist.Count -gt 120)  { $GpuHist.RemoveAt(0) }
        $VramHist.Add($VramPct); if ($VramHist.Count -gt 120) { $VramHist.RemoveAt(0) }
        $RamHist.Add($RamPct);   if ($RamHist.Count -gt 120)  { $RamHist.RemoveAt(0) }

        # 3. Collect Network
        $NowNet = [DateTime]::UtcNow
        $NetSec = [Math]::Max(0.1, ($NowNet - $PrevNetTime).TotalSeconds)
        $CurRx = 0L; $CurTx = 0L
        $NetIfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' }
        foreach ($nic in $NetIfaces) {
            $st = $nic.GetIPv4Statistics()
            $CurRx += $st.BytesReceived
            $CurTx += $st.BytesSent
        }
        $RxKBs = [Math]::Max(0.0, ($CurRx - $PrevNetRx) / 1KB / $NetSec)
        $TxKBs = [Math]::Max(0.0, ($CurTx - $PrevNetTx) / 1KB / $NetSec)
        $PrevNetRx = $CurRx; $PrevNetTx = $CurTx; $PrevNetTime = $NowNet

        # 4. Collect Disks
        $Drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }

        # 5. Collect Processes
        $NowProc = [DateTime]::UtcNow
        $ProcElapsedMs = [Math]::Max(1.0, ($NowProc - $PrevProcStamp).TotalMilliseconds)
        $NewProcTimes = @{}
        $ProcList = [System.Collections.Generic.List[PSCustomObject]]::new()
        $AllProcs = [System.Diagnostics.Process]::GetProcesses()
        foreach ($p in $AllProcs) {
            if ($p.Id -in @(0, 4)) { continue }
            $pCpu = 0.0
            try {
                $curMs = $p.TotalProcessorTime.TotalMilliseconds
                $NewProcTimes[$p.Id] = $curMs
                if ($PrevProcTimes.ContainsKey($p.Id)) {
                    $delta = $curMs - $PrevProcTimes[$p.Id]
                    $pCpu = [Math]::Max(0.0, ($delta / ($ProcElapsedMs * $LogicalCores)) * 100.0)
                }
            } catch {}
            $wsMB = $p.WorkingSet64 / 1MB
            $mPct = ($p.WorkingSet64 / $MemInfo.ullTotalPhys) * 100.0
            $isGpu = $Gpu.GpuPids.ContainsKey($p.Id)
            $gpuSm = if ($isGpu) { $Gpu.GpuPids[$p.Id] } else { -1 }

            $ProcList.Add([PSCustomObject]@{
                PID   = $p.Id
                Name  = $p.ProcessName
                CPU   = $pCpu
                MemMB = $wsMB
                MemP  = $mPct
                IsGpu = $isGpu
                GpuSm = $gpuSm
            })
        }
        $PrevProcTimes = $NewProcTimes
        $PrevProcStamp = $NowProc

        # Build Frame Buffer
        $Out = [System.Text.StringBuilder]::new(12288)
        [void]$Out.Append("$ESC[H")

        # Top Header Bar
        $ClockStr = (Get-Date).ToString("HH:mm:ss")
        $UpSpan = [TimeSpan]::FromMilliseconds([Environment]::TickCount64)
        $UpStr = "{0}d {1:00}h {2:00}m" -f $UpSpan.Days, $UpSpan.Hours, $UpSpan.Minutes
        $BannerStatus = if ([DateTime]::UtcNow -lt $StatusUntil) { " │ $($C.Orange)$StatusMsg" } else { "" }
        $HdrLeft = "$($C.Title) ptop $($C.Dim)│ $($C.Cyan)$($env:COMPUTERNAME) $($C.Dim)│ Up: $($C.Text)$UpStr $($C.Dim)│ $($C.Yellow)${RefreshMs}ms$BannerStatus"
        $HdrRight = "$($C.Dim)[$($C.Yellow)P$($C.Dim)]Cores [$($C.Yellow)T$($C.Dim)]heme [$($C.Yellow)C/M/G$($C.Dim)]Sort [$($C.Yellow)↑↓/K$($C.Dim)]Kill [$($C.Yellow)Q$($C.Dim)]uit │ $($C.Cyan)$ClockStr "
        $CleanL = ($HdrLeft -replace '\x1b\[[0-9;]*m', '').Length
        $CleanR = ($HdrRight -replace '\x1b\[[0-9;]*m', '').Length
        $Gap = [Math]::Max(1, $WinW - $CleanL - $CleanR)
        [void]$Out.AppendLine("$HdrLeft" + (" " * $Gap) + "$HdrRight$($C.Reset)")

        # ── ROW 1: CPU (Left) & GPU (Right) ──
        $CpuBorderTitle = "─$($C.Title) CPU $($C.SubTitle)($CpuName) $($C.Border)"
        $GpuPStateTag = if ($Gpu.PState) { " [$($Gpu.PState)]" } else { "" }
        $GpuBorderTitle = "─$($C.Title) GPU $($C.SubTitle)($($Gpu.Name)$GpuPStateTag) $($C.Border)"
        $CleanCpuT = ($CpuBorderTitle -replace '\x1b\[[0-9;]*m', '').Length
        $CleanGpuT = ($GpuBorderTitle -replace '\x1b\[[0-9;]*m', '').Length
        $TopBorder = "$($C.Border)╭" + $CpuBorderTitle + ("─" * [Math]::Max(0, $LeftW + 2 - $CleanCpuT)) + "╮╭" + $GpuBorderTitle + ("─" * [Math]::Max(0, $RightW + 2 - $CleanGpuT)) + "╮$($C.Reset)"
        [void]$Out.AppendLine($TopBorder)

        $BarW    = [Math]::Max(10, $LeftW - 22)
        $RBarW   = [Math]::Max(10, $RightW - 26)
        $SparkW  = [Math]::Max(10, $LeftW - 12)
        $RSparkW = [Math]::Max(10, $RightW - 12)

        # Line 1: Overall CPU%  |  GPU Core Util %
        $CpuL1 = "$($C.Text)CPU Total  $(Format-Bar $CpuPct $BarW) $(Get-MeterColor $CpuPct)$("{0,5:0.0}%" -f $CpuPct)$($C.Reset)"
        $GpuL1 = "$($C.Text)GPU Core   $(Format-Bar $Gpu.Util $RBarW) $(Get-MeterColor $Gpu.Util)$("{0,5:0.0}%" -f $Gpu.Util)$($C.Reset)"
        [void]$Out.AppendLine((Draw-BoxLine $CpuL1 $LeftW $GpuL1 $RightW))

        # Line 2: CPU Sparkline | GPU Sparkline
        $CpuL2 = "$($C.Dim)History    $(Format-Sparkline $CpuHist $SparkW (Get-MeterColor $CpuPct))"
        $GpuL2 = "$($C.Dim)History    $(Format-Sparkline $GpuHist $RSparkW (Get-MeterColor $Gpu.Util))"
        [void]$Out.AppendLine((Draw-BoxLine $CpuL2 $LeftW $GpuL2 $RightW))

        # Line 3: RAM Usage     | GPU VRAM Usage
        $VramGBUsed = $Gpu.MemUsedMB / 1024.0
        $VramGBTot  = $Gpu.MemTotMB / 1024.0
        $CpuL3 = "$($C.Text)RAM        $(Format-Bar $RamPct $BarW) $($C.Cyan)$("{0,4:0.0}/{1:0.0}G" -f $RamUsedGB, $RamTotalGB)$($C.Reset)"
        $GpuL3 = "$($C.Text)VRAM       $(Format-Bar $VramPct ($RBarW - 4)) $($C.Magenta)$("{0,4:0.0}/{1:0.0}G" -f $VramGBUsed, $VramGBTot) ($("{0:0}%" -f $VramPct))$($C.Reset)"
        [void]$Out.AppendLine((Draw-BoxLine $CpuL3 $LeftW $GpuL3 $RightW))

        # Line 4: Swap / Page   | GPU Power Draw
        $CpuL4 = "$($C.Text)Commit/Swp $(Format-Bar $PagePct $BarW) $($C.Dim)$("{0,4:0.0}/{1:0.0}G" -f $PageUsedGB, $PageTotalGB)$($C.Reset)"
        $GpuL4 = if ($Gpu.HasSensors) {
            "$($C.Text)Power      $(Format-Bar $PwrPct ($RBarW - 4) $C.Yellow) $($C.Yellow)$("{0,5:0.0}/{1:0}W" -f $Gpu.PowerW, $Gpu.PowerCapW)$($C.Reset)"
        } else { "$($C.Text)Power      $($C.Dim)N/A$($C.Reset)" }
        [void]$Out.AppendLine((Draw-BoxLine $CpuL4 $LeftW $GpuL4 $RightW))

        # Line 5: Cores/Procs   | GPU Temp, Fan, Clocks, MemCtrl
        $CpuL5 = "$($C.Dim)Cores: $($C.Text)$LogicalCores $($C.Dim)([P] Per-Core)   Procs: $($C.Text)$($AllProcs.Count)"
        $TCol  = Get-TempColor $Gpu.Temp
        $GpuL5 = if ($Gpu.HasSensors) {
            "$($C.Dim)Temp: $TCol$("{0:0}°C" -f $Gpu.Temp)  $($C.Dim)Fan: $($C.Cyan)$("{0:0}%" -f $Gpu.FanPct)  $($C.Dim)Clocks: $($C.Green)$($Gpu.ClockCore)$($C.Dim)/$($C.Magenta)$($Gpu.ClockMem)MHz  $($C.Dim)MemCtrl: $($C.Text)$("{0:0}%" -f $Gpu.MemUtil)"
        } else { "$($C.Dim)Temp/Fan/Clocks: N/A (NVIDIA only)" }
        [void]$Out.AppendLine((Draw-BoxLine $CpuL5 $LeftW $GpuL5 $RightW))

        $ExtraLines = 0
        if ($ShowPerCore -and $CorePcts.Length -gt 0) {
            $CoreTitle = "─$($C.Title) Per-Core CPU Utilization $($C.Border)"
            $CleanCT = ($CoreTitle -replace '\x1b\[[0-9;]*m', '').Length
            [void]$Out.AppendLine("$($C.Border)├" + $CoreTitle + ("─" * [Math]::Max(0, $LeftW + 2 - $CleanCT)) + "┴" + ("─" * ($RightW + 3)) + "┤$($C.Reset)")
            $ExtraLines++

            $Cols = 4
            $CellW = [int][Math]::Floor(($FullInnerW - ($Cols - 1) * 2) / $Cols)
            $MiniBarW = [Math]::Max(4, $CellW - 11)
            for ($i = 0; $i -lt $CorePcts.Length; $i += $Cols) {
                $Cells = [System.Collections.Generic.List[string]]::new()
                for ($colIdx = 0; $colIdx -lt $Cols; $colIdx++) {
                    $idx = $i + $colIdx
                    if ($idx -lt $CorePcts.Length) {
                        $cp = $CorePcts[$idx]
                        $col = Get-MeterColor $cp
                        $cellStr = "$($C.Dim)C$("{0,-2}" -f $idx)$($C.Reset) $(Format-Bar $cp $MiniBarW) $col$("{0,4:0}%" -f $cp)$($C.Reset)"
                        $Cells.Add((Pad-Ansi $cellStr $CellW))
                    } else {
                        $Cells.Add(" " * $CellW)
                    }
                }
                [void]$Out.AppendLine((Draw-FullLine ($Cells -join "  ") $FullInnerW))
                $ExtraLines++
            }
        }

        # ── ROW 2: DISKS (Left) & NETWORK (Right) ──
        $DskBorderTitle = "─$($C.Title) Disks $($C.Border)"
        $NetBorderTitle = "─$($C.Title) Network $($C.Border)"
        $CleanDskT = ($DskBorderTitle -replace '\x1b\[[0-9;]*m', '').Length
        $CleanNetT = ($NetBorderTitle -replace '\x1b\[[0-9;]*m', '').Length
        if ($ShowPerCore) {
            $MidBorder = "$($C.Border)├" + $DskBorderTitle + ("─" * [Math]::Max(0, $LeftW + 2 - $CleanDskT)) + "┬" + $NetBorderTitle + ("─" * [Math]::Max(0, $RightW + 3 - $CleanNetT)) + "┤$($C.Reset)"
        } else {
            $MidBorder = "$($C.Border)├" + $DskBorderTitle + ("─" * [Math]::Max(0, $LeftW + 2 - $CleanDskT)) + "┤├" + $NetBorderTitle + ("─" * [Math]::Max(0, $RightW + 2 - $CleanNetT)) + "┤$($C.Reset)"
        }
        [void]$Out.AppendLine($MidBorder)

        $DskLines = [System.Collections.Generic.List[string]]::new()
        foreach ($d in ($Drives | Select-Object -First 2)) {
            $totG = $d.TotalSize / 1GB
            $useG = ($d.TotalSize - $d.AvailableFreeSpace) / 1GB
            $dPct = if ($totG -gt 0) { ($useG / $totG) * 100.0 } else { 0.0 }
            $dName = $d.Name.TrimEnd('\')
            $DskLines.Add("$($C.Text)$($dName.PadRight(10)) $(Format-Bar $dPct ($BarW - 6)) $($C.Cyan)$("{0,4:0}/{1:0}G ({2:0}%)" -f $useG, $totG, $dPct)$($C.Reset)")
        }
        while ($DskLines.Count -lt 2) { $DskLines.Add("") }

        $RxStr = if ($RxKBs -ge 1024) { "{0:0.00} MB/s" -f ($RxKBs / 1024) } else { "{0:0.0} KB/s" -f $RxKBs }
        $TxStr = if ($TxKBs -ge 1024) { "{0:0.00} MB/s" -f ($TxKBs / 1024) } else { "{0:0.0} KB/s" -f $TxKBs }
        $NetL1 = "$($C.Green)▼ Download $($C.Text)$($RxStr.PadRight(14)) $($C.Dim)Total RX: $($C.Text)$("{0:0.00} GB" -f ($CurRx / 1GB))"
        $NetL2 = "$($C.Yellow)▲ Upload   $($C.Text)$($TxStr.PadRight(14)) $($C.Dim)Total TX: $($C.Text)$("{0:0.00} GB" -f ($CurTx / 1GB))"

        [void]$Out.AppendLine((Draw-BoxLine $DskLines[0] $LeftW $NetL1 $RightW))
        [void]$Out.AppendLine((Draw-BoxLine $DskLines[1] $LeftW $NetL2 $RightW))

        $BotSplit = "$($C.Border)╰" + ("─" * ($LeftW + 2)) + "╯╰" + ("─" * ($RightW + 2)) + "╯$($C.Reset)"
        [void]$Out.AppendLine($BotSplit)

        # ── ROW 3: PROCESSES (Full Width) ──
        $ProcTitle = "─$($C.Title) Processes $($C.SubTitle)(Sort: $($C.Yellow)$SortBy$($C.SubTitle) │ GPU Apps: $($C.Green)$($Gpu.GpuPids.Count)$($C.SubTitle) │ Theme: $($C.Cyan)$($C.Name)$($C.SubTitle)) $($C.Border)"
        $CleanPT = ($ProcTitle -replace '\x1b\[[0-9;]*m', '').Length
        [void]$Out.AppendLine("$($C.Border)╭" + $ProcTitle + ("─" * [Math]::Max(0, $FullInnerW + 2 - $CleanPT)) + "╮$($C.Reset)")

        # Table Header
        $NameColW = [Math]::Max(18, $FullInnerW - 58)
        $TblHdr = "{0,7}  {1,-$NameColW}  {2,7}  {3,9}  {4,6}  {5,-16}" -f "PID", "PROCESS NAME", "CPU %", "MEM (MB)", "MEM %", "GPU STATUS"
        [void]$Out.AppendLine((Draw-FullLine "$($C.HeaderBg)$($TblHdr.PadRight($FullInnerW))$($C.Reset)" $FullInnerW))

        # Sort Processes
        $SortedProcs = switch ($SortBy) {
            "MEM" { $ProcList | Sort-Object MemMB -Descending }
            "GPU" { $ProcList | Sort-Object IsGpu, GpuSm, CPU, MemMB -Descending }
            default { $ProcList | Sort-Object CPU, MemMB -Descending }
        }

        $UsedLines = 15 + $ExtraLines
        $ProcRows = [Math]::Max(3, $WinH - $UsedLines)
        $DisplayedProcs = @($SortedProcs | Select-Object -First $ProcRows)
        if ($SelectedIdx -ge $DisplayedProcs.Count) {
            $SelectedIdx = [Math]::Max(0, $DisplayedProcs.Count - 1)
        }

        for ($r = 0; $r -lt $DisplayedProcs.Count; $r++) {
            $pr = $DisplayedProcs[$r]
            $pName = if ($pr.Name.Length -gt $NameColW) { $pr.Name.Substring(0, $NameColW - 1) + "…" } else { $pr.Name }
            if ($r -eq $SelectedIdx) {
                $gText = if ($pr.IsGpu) {
                    if ($pr.GpuSm -gt 0) { "● $($Gpu.ShortName) ($($pr.GpuSm)%)" } else { "● $($Gpu.ShortName) (Active)" }
                } else { "·" }
                $PlainRow = "{0,7}  {1,-$NameColW}  {2,6:0.0}%  {3,8:0.0}M  {4,5:0.0}%  {5,-19}" -f $pr.PID, $pName, $pr.CPU, $pr.MemMB, $pr.MemP, $gText
                [void]$Out.AppendLine((Draw-FullLine "$($C.SelBg)$($PlainRow.PadRight($FullInnerW))$($C.Reset)" $FullInnerW))
            } else {
                $cCol  = Get-MeterColor ($pr.CPU * 2)
                $mCol  = Get-MeterColor ($pr.MemP * 2)
                $gBadge = if ($pr.IsGpu) {
                    if ($pr.GpuSm -gt 0) { "$($C.GpuTag)● $($Gpu.ShortName) ($($pr.GpuSm)%)$($C.Reset)" }
                    else { "$($C.GpuTag)● $($Gpu.ShortName) (Active)$($C.Reset)" }
                } else {
                    "$($C.Dim)·$($C.Reset)"
                }
                $RowStr = "$($C.Dim)$("{0,7}" -f $pr.PID)  $($C.Text)$($pName.PadRight($NameColW))  $cCol$("{0,6:0.0}%" -f $pr.CPU)  $($C.Cyan)$("{0,8:0.0}M" -f $pr.MemMB)  $mCol$("{0,5:0.0}%" -f $pr.MemP)  $gBadge"
                [void]$Out.AppendLine((Draw-FullLine $RowStr $FullInnerW))
            }
        }

        [void]$Out.Append("$($C.Border)╰" + ("─" * ($FullInnerW + 2)) + "╯$($C.Reset)")

        # Output entire frame at once
        [Console]::Write($Out.ToString())

        # Sleep remaining interval in small slices for responsive keyboard input
        $Elapsed = ([DateTime]::UtcNow - $LoopStart).TotalMilliseconds
        $Remain  = [Math]::Max(50, $RefreshMs - [int]$Elapsed)
        $Slept   = 0
        while ($Slept -lt $Remain -and -not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 50
            $Slept += 50
        }
    }
}
finally {
    Write-Host "$ESC[?25h$ESC[?1049l$ESC[0m" -NoNewline
}
