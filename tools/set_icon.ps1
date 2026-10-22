# מחליף את אייקון התוכנה מתמונה אחת.
# שימוש:  powershell -ExecutionPolicy Bypass -File tools\set_icon.ps1 "C:\path\logo.png" [-Push]
# מקבל PNG / JPG / BMP / ICO. מומלץ תמונה ריבועית של 256 פיקסלים ומעלה.
# מייצר: windows\runner\resources\app_icon.ico (16,24,32,48,64,128,256) ו-assets\app_icon.png (לשורת הכותרת).
# עם -Push: גם commit ו-push ל-main, ו-GitHub Actions יבנה גרסה חדשה.
param(
  [Parameter(Mandatory = $true)][string]$Source,
  [switch]$Push
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$icoPath = Join-Path $root 'windows\runner\resources\app_icon.ico'
$pngPath = Join-Path $root 'assets\app_icon.png'
if (-not (Test-Path -LiteralPath $Source)) { throw "הקובץ לא נמצא: $Source" }
New-Item -ItemType Directory -Force (Split-Path $pngPath) | Out-Null

$src = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Source))
$side = [Math]::Max($src.Width, $src.Height)

# ריבוע שקוף, התמונה במרכז (בלי עיוות)
function Render([int]$n) {
  $bmp = New-Object System.Drawing.Bitmap $n, $n, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'HighQuality'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
  $g.Clear([System.Drawing.Color]::Transparent)
  $scale = $n / $side
  $w = $src.Width * $scale; $h = $src.Height * $scale
  $g.DrawImage($src, ($n - $w) / 2, ($n - $h) / 2, $w, $h)
  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return , $ms.ToArray()
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$images = foreach ($s in $sizes) { , (Render $s) }

# כתיבת ICO עם תמונות PNG מוטמעות (נתמך מ-Windows Vista)
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $ms
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $d = $images[$i]
  $b = if ($s -ge 256) { 0 } else { $s }
  $bw.Write([byte]$b); $bw.Write([byte]$b); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([uint16]1); $bw.Write([uint16]32)
  $bw.Write([uint32]$d.Length); $bw.Write([uint32]$offset)
  $offset += $d.Length
}
foreach ($d in $images) { $bw.Write($d) }
$bw.Flush()
$bytes = $ms.ToArray()
$src.Dispose()

[System.IO.File]::WriteAllBytes($icoPath, $bytes)
[System.IO.File]::WriteAllBytes($pngPath, $images[$sizes.Count - 1])
Write-Host "נכתב: $icoPath"
Write-Host "נכתב: $pngPath"

if ($Push) {
  Push-Location $root
  try {
    git add -- windows/runner/resources/app_icon.ico assets/app_icon.png
    git commit -m "אייקון חדש לתוכנה"
    git push origin HEAD
    Write-Host 'נדחף. ההתקדמות של הבנייה: https://github.com/YairDaniel11/Otzariya_Link_Maker/actions'
  } finally { Pop-Location }
}
