<#
.SYNOPSIS
Apply the two ComfyUI changes that gfx1031 + ZLUDA needs.

.DESCRIPTION
1. comfy\ldm\modules\attention.py
   comfy_kitchen has no int8_attention_is_available under ZLUDA, so calling it
   raises AttributeError during startup.

2. comfyui.bat
   --disable-mmap: the safetensors mmap path faults under memory pressure; this
   copies tensors instead.

Note that this does not touch cuDNN. Measured on an RX 6700 XT, convolution with
cuDNN enabled runs fine at 0.0147s per 320->320 3x3 at 128x128, and the launcher
pins cuDNN off anyway by copying customzluda\zluda-default.py over comfy\zluda.py
on every run. Anything written into comfy\zluda.py is overwritten at the next
launch, so patches belong in customzluda\zluda-default.py instead.

Both files are backed up as .gfx1031.bak before the first change. Running this
more than once is harmless.

.PARAMETER ComfyUIRoot
ComfyUI root directory. Auto-detected when omitted.
#>
[CmdletBinding()]
param([string]$ComfyUIRoot)

. (Join-Path $PSScriptRoot 'Common.ps1')

$root = Find-ComfyUIRoot -Hint $ComfyUIRoot
if (-not $root) { throw "ComfyUI root not found. Pass -ComfyUIRoot." }
Write-Host "ComfyUI: $root"

function Backup-Once {
    param([string]$Path)
    $b = "$Path.gfx1031.bak"
    if (-not (Test-Path $b)) { Copy-Item $Path $b }
}

# ---- 1) attention.py ----
$att = Join-Path $root 'comfy\ldm\modules\attention.py'
if (-not (Test-Path $att)) { throw "No $att" }

$text = Get-Content $att -Raw
$call = 'COMFY_KITCHEN_INT8_ATTENTION_IS_AVAILABLE = comfy_kitchen.int8_attention_is_available()'

if ($text -match 'hasattr\(comfy_kitchen, "int8_attention_is_available"\)') {
    Write-Host "  attention.py: already patched." -ForegroundColor DarkGray
} elseif ($text -notmatch [regex]::Escape($call)) {
    Write-Host "  attention.py: the line to patch was not found, upstream may have changed. Skipping." -ForegroundColor Yellow
} else {
    Backup-Once $att
    $guard = @'
if hasattr(comfy_kitchen, "int8_attention_is_available"):
    COMFY_KITCHEN_INT8_ATTENTION_IS_AVAILABLE = comfy_kitchen.int8_attention_is_available()
else:
    COMFY_KITCHEN_INT8_ATTENTION_IS_AVAILABLE = False
'@
    [IO.File]::WriteAllText($att, $text.Replace($call, $guard.TrimEnd()), (New-Object Text.UTF8Encoding $false))
    Write-Host "  attention.py: added the hasattr guard." -ForegroundColor Green
}

# ---- 2) comfyui.bat ----
$bat = Join-Path $root 'comfyui.bat'
if (-not (Test-Path $bat)) { throw "No $bat" }

$lines = Get-Content $bat
$changed = $false

for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*set "COMMANDLINE_ARGS=' -and $lines[$i] -notmatch '--disable-mmap') {
        $lines[$i] = $lines[$i] -replace '"\s*$', ' --disable-mmap"'
        $changed = $true
    }
}

if ($changed) {
    Backup-Once $bat
    [IO.File]::WriteAllLines($bat, $lines, (New-Object Text.UTF8Encoding $false))
    Write-Host "  comfyui.bat: updated (backup: comfyui.bat.gfx1031.bak)." -ForegroundColor Green
} else {
    Write-Host "  comfyui.bat: already patched." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Next: scripts\Test-Setup.ps1"
