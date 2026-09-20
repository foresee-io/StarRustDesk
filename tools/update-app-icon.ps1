param(
    [Parameter(Mandatory = $true)]
    [string]$SourceImage
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = (Resolve-Path -LiteralPath $SourceImage).Path

function Assert-Opaque([System.Drawing.Bitmap]$Bitmap) {
    $rect = [System.Drawing.Rectangle]::new(0, 0, $Bitmap.Width, $Bitmap.Height)
    $bits = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $bytes = [byte[]]::new([Math]::Abs($bits.Stride) * $Bitmap.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($bits.Scan0, $bytes, 0, $bytes.Length)
        for ($i = 3; $i -lt $bytes.Length; $i += 4) {
            if ($bytes[$i] -ne 255) { throw 'Icon contains transparent or semi-transparent pixels.' }
        }
    } finally { $Bitmap.UnlockBits($bits) }
}

# Mechanical export of the approved artwork: no redraw, crop or corner mask.
$source = [System.Drawing.Bitmap]::new($sourcePath)
$output = $null
try {
    if ($source.Width -ne $source.Height) { throw 'Approved source must be square.' }
    Assert-Opaque $source
    $output = [System.Drawing.Bitmap]::new(1024, 1024, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($output)
    $attributes = [System.Drawing.Imaging.ImageAttributes]::new()
    try {
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $graphics.DrawImage($source, [System.Drawing.Rectangle]::new(0, 0, 1024, 1024),
            0, 0, $source.Width, $source.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
    } finally { $attributes.Dispose(); $graphics.Dispose() }
    Assert-Opaque $output
    foreach ($directory in @('AppScope/resources/base/media', 'entry/src/main/resources/base/media')) {
        foreach ($name in @('starrustdesk_app_icon_1024.png', 'starrustdesk_app_icon.png')) {
            $destination = Join-Path $root "$directory/$name"
            $output.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
            Write-Output "$directory/$name : 1024x1024 opaque RGB PNG"
        }
    }
} finally {
    if ($null -ne $output) { $output.Dispose() }
    $source.Dispose()
}
