#Requires -Version 5.0
<#
.SYNOPSIS
    Sets brightness on DDC/CI capable monitors (e.g. Apple Cinema Display) on Windows.

.PARAMETER Brightness
    Brightness level from 0 to 100.

.EXAMPLE
    .\Set-MonitorBrightness.ps1 -Brightness 50
    .\Set-MonitorBrightness.ps1 -Brightness 75 -List
#>
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100)]
    [int]$Brightness,

    [Parameter(Mandatory = $false)]
    [int]$Monitor = 0,

    [switch]$List
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class MonitorControl {
    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(
        IntPtr hdc, IntPtr lprcClip, MonitorEnumDelegate lpfnEnum, IntPtr dwData);

    public delegate bool MonitorEnumDelegate(
        IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor, ref uint pdwNumberOfPhysicalMonitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor, uint dwPhysicalMonitorArraySize,
        [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetMonitorBrightness(
        IntPtr hPhysicalMonitor, ref uint pdwMin, ref uint pdwCurrent, ref uint pdwMax);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool SetMonitorBrightness(
        IntPtr hPhysicalMonitor, uint dwNewBrightness);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool DestroyPhysicalMonitor(IntPtr hPhysicalMonitor);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int left, top, right, bottom;
    }

    private static List<IntPtr> _handles = new List<IntPtr>();

    private static bool EnumCallback(IntPtr hMon, IntPtr hdc, ref RECT rect, IntPtr data) {
        _handles.Add(hMon);
        return true;
    }

    public static List<IntPtr> GetLogicalMonitorHandles() {
        _handles = new List<IntPtr>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, new MonitorEnumDelegate(EnumCallback), IntPtr.Zero);
        return _handles;
    }
}
"@

if (-not $List -and -not $PSBoundParameters.ContainsKey('Brightness')) {
    Write-Host "Usage:"
    Write-Host "  List monitors:         .\Set-MonitorBrightness.ps1 -List"
    Write-Host "  Set all monitors:      .\Set-MonitorBrightness.ps1 -Brightness 60"
    Write-Host "  Set one monitor:       .\Set-MonitorBrightness.ps1 -Brightness 60 -Monitor 1"
    exit 0
}

$logicalHandles = [MonitorControl]::GetLogicalMonitorHandles()
$monitorIndex = 0

foreach ($hMonitor in $logicalHandles) {
    $count = [uint32]0
    if (-not [MonitorControl]::GetNumberOfPhysicalMonitorsFromHMONITOR($hMonitor, [ref]$count)) {
        continue
    }

    $physMons = [System.Array]::CreateInstance([MonitorControl+PHYSICAL_MONITOR], $count)
    if (-not [MonitorControl]::GetPhysicalMonitorsFromHMONITOR($hMonitor, $count, $physMons)) {
        continue
    }

    foreach ($pm in $physMons) {
        $monitorIndex++
        $name = if ($pm.szPhysicalMonitorDescription) { $pm.szPhysicalMonitorDescription } else { "Monitor $monitorIndex" }
        $min = [uint32]0; $cur = [uint32]0; $max = [uint32]0
        $canRead = [MonitorControl]::GetMonitorBrightness($pm.hPhysicalMonitor, [ref]$min, [ref]$cur, [ref]$max)

        if ($List) {
            Write-Host ("#$monitorIndex  $name")
            if ($canRead) {
                $pct = if ($max -gt $min) { [int](($cur - $min) * 100 / ($max - $min)) } else { 0 }
                Write-Host ("       Brightness: $pct% (raw $cur, range $min-$max)")
            } else {
                Write-Warning "       DDC/CI brightness not supported on this monitor"
            }
        } else {
            if ($Monitor -ne 0 -and $monitorIndex -ne $Monitor) {
                # skip — user targeted a specific monitor
            } elseif ($canRead) {
                $raw = [uint32]([Math]::Round($min + ($max - $min) * $Brightness / 100.0))
                $ok = [MonitorControl]::SetMonitorBrightness($pm.hPhysicalMonitor, $raw)
                if ($ok) {
                    Write-Host "[OK]  #$monitorIndex $name -> $Brightness%"
                } else {
                    Write-Warning "[FAIL] #$monitorIndex $name  (SetMonitorBrightness failed)"
                }
            } else {
                Write-Warning "[SKIP] #$monitorIndex $name  (DDC/CI not supported)"
            }
        }

        [MonitorControl]::DestroyPhysicalMonitor($pm.hPhysicalMonitor) | Out-Null
    }
}

if ($monitorIndex -eq 0) {
    Write-Warning "No monitors found. Make sure the display is connected and DDC/CI is enabled."
}
