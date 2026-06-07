#Requires -Version 5.0
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

if (-not ([System.Management.Automation.PSTypeName]'MonitorControl').Type) {
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
    public struct RECT { public int left, top, right, bottom; }

    private static List<IntPtr> _handles = new List<IntPtr>();
    private static bool EnumCallback(IntPtr hMon, IntPtr hdc, ref RECT rect, IntPtr data) {
        _handles.Add(hMon); return true;
    }
    public static List<IntPtr> GetLogicalMonitorHandles() {
        _handles = new List<IntPtr>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, new MonitorEnumDelegate(EnumCallback), IntPtr.Zero);
        return _handles;
    }
}
"@
}

# --- Enumerate monitors ---
$script:monitors = New-Object System.Collections.Generic.List[object]
$index = 0

foreach ($hMonitor in [MonitorControl]::GetLogicalMonitorHandles()) {
    $count = [uint32]0
    if (-not [MonitorControl]::GetNumberOfPhysicalMonitorsFromHMONITOR($hMonitor, [ref]$count)) { continue }

    $physMons = [System.Array]::CreateInstance([MonitorControl+PHYSICAL_MONITOR], $count)
    if (-not [MonitorControl]::GetPhysicalMonitorsFromHMONITOR($hMonitor, $count, $physMons)) { continue }

    foreach ($pm in $physMons) {
        $min = [uint32]0; $cur = [uint32]0; $max = [uint32]0
        if ([MonitorControl]::GetMonitorBrightness($pm.hPhysicalMonitor, [ref]$min, [ref]$cur, [ref]$max)) {
            $index++
            $pct = if ($max -gt $min) { [int](($cur - $min) * 100 / ($max - $min)) } else { 0 }
            $script:monitors.Add([PSCustomObject]@{
                Index  = $index
                Handle = $pm.hPhysicalMonitor
                Name   = if ($pm.szPhysicalMonitorDescription) { $pm.szPhysicalMonitorDescription } else { "Monitor $index" }
                Min    = $min
                Max    = $max
                Pct    = $pct
            })
        }
    }
}

if ($script:monitors.Count -eq 0) {
    [System.Windows.MessageBox]::Show(
        "No DDC/CI-capable monitors found.`nMake sure the display cable passes DDC/CI signals.",
        "Monitor Brightness", "OK", "Warning") | Out-Null
    exit 1
}

# --- Build UI ---
$window = New-Object System.Windows.Window
$window.Title           = "Monitor Brightness"
$window.Width           = 420
$window.SizeToContent   = "Height"
$window.ResizeMode      = "CanMinimize"
$window.WindowStartupLocation = "CenterScreen"

$outer = New-Object System.Windows.Controls.StackPanel
$outer.Margin = New-Object System.Windows.Thickness(16)

foreach ($mon in $script:monitors) {
    $gb = New-Object System.Windows.Controls.GroupBox
    $gb.Header = "Monitor $($mon.Index)"
    $gb.Margin = New-Object System.Windows.Thickness(0, 0, 0, 12)

    $inner = New-Object System.Windows.Controls.StackPanel
    $inner.Margin = New-Object System.Windows.Thickness(8, 4, 8, 8)

    # Subtitle
    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.Text       = $mon.Name
    $sub.Foreground = [System.Windows.Media.Brushes]::Gray
    $sub.FontSize   = 11
    $sub.Margin     = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $inner.Children.Add($sub) | Out-Null

    # Grid: slider | label
    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = New-Object System.Windows.GridLength(52, [System.Windows.GridUnitType]::Pixel)
    $grid.ColumnDefinitions.Add($c1)
    $grid.ColumnDefinitions.Add($c2)

    $slider = New-Object System.Windows.Controls.Slider
    $slider.Minimum          = 0
    $slider.Maximum          = 100
    $slider.Value            = $mon.Pct
    $slider.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($slider, 0)

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text                = "$($mon.Pct)%"
    $lbl.VerticalAlignment   = "Center"
    $lbl.HorizontalAlignment = "Right"
    $lbl.FontWeight          = "SemiBold"
    $lbl.Margin              = New-Object System.Windows.Thickness(6, 0, 0, 0)
    [System.Windows.Controls.Grid]::SetColumn($lbl, 1)

    $grid.Children.Add($slider) | Out-Null
    $grid.Children.Add($lbl)    | Out-Null
    $inner.Children.Add($grid)  | Out-Null

    # Store everything needed in Tag to avoid closure issues
    $slider.Tag = @{
        Handle = $mon.Handle
        Min    = $mon.Min
        Max    = $mon.Max
        Label  = $lbl
    }

    $slider.Add_ValueChanged({
        $sl  = $args[0]
        $pct = [int]$sl.Value
        $d   = $sl.Tag
        $d.Label.Text = "$pct%"
        $raw = [uint32]([Math]::Round($d.Min + ($d.Max - $d.Min) * $pct / 100.0))
        [MonitorControl]::SetMonitorBrightness($d.Handle, $raw) | Out-Null
    })

    $gb.Content = $inner
    $outer.Children.Add($gb) | Out-Null
}

$window.Content = $outer

$window.Add_Closed({
    foreach ($mon in $script:monitors) {
        [MonitorControl]::DestroyPhysicalMonitor($mon.Handle) | Out-Null
    }
})

$window.ShowDialog() | Out-Null
