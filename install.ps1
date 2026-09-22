<#
.SYNOPSIS
Set up an RX 6700 / 6700 XT / 6750 XT (gfx1031) to run ComfyUI + ZLUDA.

.DESCRIPTION
Runs four steps in order:
  1. check the environment   scripts\Check-Environment.ps1
  2. install gfx1031 kernels scripts\Install-Kernels.ps1
  3. patch ComfyUI           scripts\Patch-ComfyUI.ps1
  4. verify on the GPU       scripts\Test-Setup.ps1

Each step also runs on its own. When something fails, look it up in
docs\TROUBLESHOOTING.md.

.PARAMETER Mode
Kernel source: Borrow (reuse gfx1030 kernels, no network, the default) or
Download (community-built real gfx1031 kernels).

.PARAMETER ComfyUIRoot
ComfyUI root directory. Auto-detected when omitted.

.PARAMETER HipRoot
HIP install root. Auto-detected when omitted.

.PARAMETER Yes
Download mode only: skip the confirmation before downloading the kernel pack.

.EXAMPLE
.\install.ps1

.EXAMPLE
.\install.ps1 -Mode Download
#>
[CmdletBinding()]
param(
    [ValidateSet('Borrow', 'Download')]
    [string]$Mode = 'Borrow',
    [string]$ComfyUIRoot,
    [string]$HipRoot,
    [switch]$Yes
)

. (Join-Path $PSScriptRoot 'scripts\Common.ps1')

$gpus = @(Get-AmdGpuNames)
if (-not (Test-IsGfx1031 $gpus)) {
    Write-Host "No gfx1031 GPU detected (RX 6700 / 6700 XT / 6750 XT)." -ForegroundColor Yellow
    Write-Host "Found: $($gpus -join ', ')"
    if ((Read-Host "Continue anyway? [y/N]") -notmatch '^[yY]') { return }
}

Write-Host ""
Write-Host "######## 1/4 checking the environment ########" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'scripts\Check-Environment.ps1') -ComfyUIRoot $ComfyUIRoot

Write-Host ""
Write-Host "######## 2/4 installing gfx1031 kernels ########" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'scripts\Install-Kernels.ps1') -Mode $Mode -HipRoot $HipRoot -Yes:$Yes

Write-Host ""
Write-Host "######## 3/4 patching ComfyUI ########" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'scripts\Patch-ComfyUI.ps1') -ComfyUIRoot $ComfyUIRoot

Write-Host ""
Write-Host "######## 4/4 verifying on the GPU ########" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'scripts\Test-Setup.ps1') -ComfyUIRoot $ComfyUIRoot

Write-Host ""
Write-Host "Done. Environment variable changes need a fresh terminal to take effect." -ForegroundColor Green
