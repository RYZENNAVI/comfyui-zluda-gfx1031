<#
.SYNOPSIS
Check every part of a gfx1031 + ZLUDA setup that commonly goes wrong.

.DESCRIPTION
Read-only. Reports what it finds and how to fix it. When something fails, look
the error up in docs\TROUBLESHOOTING.md.

.PARAMETER ComfyUIRoot
ComfyUI root directory. Auto-detected when omitted.
#>
[CmdletBinding()]
param([string]$ComfyUIRoot)

. (Join-Path $PSScriptRoot 'Common.ps1')
$ErrorActionPreference = 'Continue'

$fail = 0
$warn = 0

function Ok   ($m) { Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow; $script:warn++ }
function Bad  ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:fail++ }
function Fix  ($m) { Write-Host "         -> $m" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "=== 1. GPU ==="
$gpus = @(Get-AmdGpuNames)
if ($gpus.Count -eq 0) {
    Bad "No AMD GPU detected."
} else {
    $gpus | ForEach-Object { Write-Host "  $_" }
    if (Test-IsGfx1031 $gpus) { Ok "This is a gfx1031, which is what this project is for." }
    else { Warn "Does not look like a gfx1031 (RX 6700 / 6700 XT / 6750 XT). These scripts may not apply." }
}

Write-Host ""
Write-Host "=== 2. HIP SDK ==="
$hips = @(Get-HipInstalls)
if ($hips.Count -eq 0) {
    Bad "No HIP SDK installed."
    Fix "Install HIP SDK for Windows, matching your ZLUDA version (see section 4)."
} else {
    foreach ($h in $hips) {
        if ($h.Runtime) {
            Write-Host "  HIP $($h.Version)  runtime $($h.Runtime)  $($h.Root)"
        } else {
            # An incomplete install like this gives ZLUDA a bare 0xC0000135.
            Bad "HIP $($h.Version) is incomplete: no amdhip64*.dll in $($h.Bin)"
            Fix "Take one from C:\Windows\System32\DriverStore\FileRepository\amdocl.inf_*, matching your installed driver version."
        }
    }
    if ($hips.Count -gt 1) {
        Warn "$($hips.Count) HIP versions installed; PATH order decides which one is used (see section 3)."
    }
}

Write-Host ""
Write-Host "=== 3. Environment variables and PATH ==="
$hu = [Environment]::GetEnvironmentVariable('HIP_PATH', 'User')
$hm = [Environment]::GetEnvironmentVariable('HIP_PATH', 'Machine')
if ($hu -and $hm -and ($hu.TrimEnd('\') -ne $hm.TrimEnd('\'))) {
    # The installer writes the machine scope; a stale user value silently wins.
    Bad "HIP_PATH differs between user ($hu) and machine ($hm) scope; the user one wins."
    Fix "Decide which you want, then delete the user-scope HIP_PATH from System Properties > Environment Variables."
} elseif ($hu -or $hm) {
    Ok "HIP_PATH = $(if ($hu) { $hu } else { $hm })"
} else {
    Warn "HIP_PATH is not set."
}

$first = @($env:Path -split ';' | Where-Object { $_ -like '*AMD\ROCm*' } | Select-Object -First 1)
if ($first) {
    Write-Host "  First ROCm entry on PATH: $first"
    if ($hips.Count -gt 1) { Fix "With several versions installed, put the one you want first." }
} elseif ($hips.Count -gt 0) {
    Bad "No ROCm bin directory on PATH."
    Fix "Put the bin directory of your target HIP first on PATH."
}

Write-Host ""
Write-Host "=== 4. ZLUDA and HIP version match ==="
$root = Find-ComfyUIRoot -Hint $ComfyUIRoot
if (-not $root) {
    Warn "ComfyUI root not found, skipping the ZLUDA check. Pass -ComfyUIRoot."
} else {
    Write-Host "  ComfyUI: $root"
    $nv = Get-ChildItem $root -Recurse -Filter 'nvcuda.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nv) {
        Warn "The ZLUDA nvcuda.dll was not found."
    } else {
        $need = Get-ZludaHipRequirement $nv.FullName
        Write-Host "  $($nv.FullName)"
        if (-not $need) {
            Warn "Could not read which amdhip64 it imports."
        } else {
            # A mismatch here is 0xC0000135 or 0xC0000139 with no other clue.
            $have = @($hips | Where-Object { $_.Runtime -eq $need })
            if ($have.Count -gt 0) {
                Ok "ZLUDA wants $need, HIP $($have[0].Version) provides it."
            } else {
                Bad "ZLUDA wants $need, but none of the installed HIP versions provide it."
                Fix "Either install the matching HIP major version or change ZLUDA (3.9.5 goes with HIP 6.x, 3.9.6 with HIP 7.x)."
            }
        }
    }
}

Write-Host ""
Write-Host "=== 5. gfx1031 kernels in rocBLAS ==="
foreach ($h in $hips) {
    if (-not $h.Runtime) { continue }   # section 2 already reported this one as broken
    if (-not (Test-Path $h.RocBlasLib)) { continue }
    $n = @(Get-ChildItem $h.RocBlasLib -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like '*gfx1031*' }).Count
    if ($n -gt 0) { Ok "HIP $($h.Version): $n gfx1031 files." }
    else {
        Bad "HIP $($h.Version): no gfx1031 kernels at all, so you will get 'no kernel image is available'."
        Fix "Run scripts\Install-Kernels.ps1 (-Mode Borrow by default, or -Mode Download for real community kernels)."
    }
}

Write-Host ""
Write-Host "=== 6. ComfyUI-side changes ==="
if ($root) {
    $att = Join-Path $root 'comfy\ldm\modules\attention.py'
    if (Test-Path $att) {
        # comfy_kitchen has no int8_attention_is_available under ZLUDA.
        if (Select-String -Path $att -Pattern 'hasattr\(comfy_kitchen, "int8_attention_is_available"\)' -Quiet) {
            Ok "attention.py has the int8_attention guard."
        } else {
            Bad "attention.py is unpatched; startup will fail with AttributeError under ZLUDA."
            Fix "Run scripts\Patch-ComfyUI.ps1"
        }
    }

    $bat = Get-ChildItem $root -Filter 'comfyui*.bat' -ErrorAction SilentlyContinue
    $hasMmap = $false
    foreach ($b in $bat) {
        if ((Get-Content $b.FullName -Raw) -match '--disable-mmap') { $hasMmap = $true }
    }
    # safetensors mmap faults under memory pressure.
    if ($hasMmap) { Ok "The launcher passes --disable-mmap." }
    else { Warn "The launcher does not pass --disable-mmap; large models may hit an access violation." }

    # The launcher copies customzluda\zluda-default.py over comfy\zluda.py on every
    # run, and that file pins the attention backends to math only. Without it torch
    # picks the mem-efficient CUTLASS kernels, which are built for sm80+ and reset
    # the display driver on RDNA2. Measured on an RX 6700 XT: event 4101, one second
    # after the process ended.
    $zd = Join-Path $root 'comfy\customzluda\zluda-default.py'
    if (Test-Path $zd) {
        if (Select-String -Path $zd -Pattern 'enable_mem_efficient_sdp\(False\)' -Quiet) {
            Ok "The launcher pins attention to the math backend."
        } else {
            Bad "customzluda\zluda-default.py does not disable the mem-efficient attention backend."
            Fix "Attention will reset the display driver. Pass --use-quad-cross-attention, which avoids SDPA entirely."
        }
    }

    $torchLib = Join-Path $root 'venv\Lib\site-packages\torch\lib'
    $zdir = if ($nv) { Split-Path $nv.FullName -Parent } else { $null }
    if ((Test-Path $torchLib) -and $zdir) {
        # Python 3.8+ no longer searches PATH for extension-module dependencies,
        # so the ZLUDA DLLs have to be copied into torch\lib under the names
        # torch expects. Editing PATH achieves nothing.
        $map = @{
            'cublas.dll'   = 'cublas64_11.dll'
            'cusparse.dll' = 'cusparse64_11.dll'
            'cufft.dll'    = 'cufft64_10.dll'
            'nvrtc.dll'    = 'nvrtc64_112_0.dll'
        }
        $stale = foreach ($k in $map.Keys) {
            $src = Join-Path $zdir $k
            $dst = Join-Path $torchLib $map[$k]
            if (-not (Test-Path $src)) { continue }
            if (-not (Test-Path $dst)) { $map[$k]; continue }
            if ((Get-FileHash $src).Hash -ne (Get-FileHash $dst).Hash) { $map[$k] }
        }
        if (@($stale).Count -eq 0) {
            Ok "The CUDA DLLs in torch\lib are the ZLUDA builds."
        } else {
            Bad "These in torch\lib are not the ZLUDA builds: $($stale -join ', ')"
            Fix "Copy them from zluda\ under the names above. Python 3.8+ only looks in this directory, not on PATH."
        }
    }
}

Write-Host ""
if ($fail -eq 0 -and $warn -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
} else {
    Write-Host "Failed: $fail   Warnings: $warn   Fix these and run this again." -ForegroundColor $(if ($fail) { 'Red' } else { 'Yellow' })
}
