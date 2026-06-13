# Capture the running game window to PNG (for the visual iteration loop).
# Usage: pwsh -File ai_tools/cap.ps1 [outPath] [titleLike]
param(
    [string]$Out = "ai_tools/screenshot.png",
    [string]$TitleLike = "convini"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$sig = @'
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type -TypeDefinition $sig

# Target the running game window: title is "<project> (DEBUG)".
$proc = Get-Process | Where-Object { ($_.MainWindowTitle -like "*$TitleLike*") -and ($_.MainWindowTitle -like "*(DEBUG)*") } | Select-Object -First 1

if (-not $proc) {
    Write-Error "window not found (title like '$TitleLike')"
    exit 1
}

$h = $proc.MainWindowHandle
[Win32]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 250

$r = New-Object Win32+RECT
[Win32]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.Right - $r.Left
$ht = $r.Bottom - $r.Top
if (($w -le 0) -or ($ht -le 0)) { Write-Error "failed to get window size"; exit 1 }

# PrintWindow で実体を取得（前面でなくても・他ウィンドウに隠れていても撮れる）
$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
# nFlags=2 (PW_RENDERFULLCONTENT) でGPU描画ウィンドウも取得
$ok = [Win32]::PrintWindow($h, $hdc, 2)
$g.ReleaseHdc($hdc)
if (-not $ok) {
    # フォールバック：前面化して画面コピー
    [Win32]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 250
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
}
$full = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Get-Location) $Out }
$bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output ("saved: {0} ({1}x{2}) title='{3}'" -f $full, $w, $ht, $proc.MainWindowTitle)
