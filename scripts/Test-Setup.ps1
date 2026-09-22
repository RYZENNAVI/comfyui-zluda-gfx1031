<#
.SYNOPSIS
Run real work on the GPU from the ComfyUI venv to prove the gfx1031 kernels work.

.DESCRIPTION
Check-Environment.ps1 only inspects files and environment variables. This one
actually dispatches to the GPU:
  - matmul        goes through rocBLAS; missing gfx1031 kernels fail here
  - convolution   fails here when cuDNN was not properly disabled
  - attention     goes through SDPA

The first run is slow because ZLUDA JIT-compiles kernels, cached under
%LOCALAPPDATA%\ZLUDA\ComputeCache. Later runs are fast.

.PARAMETER ComfyUIRoot
ComfyUI root directory. Auto-detected when omitted.

.PARAMETER TimeoutSeconds
How long to wait for a result. Defaults to 900, since the first run has to
JIT-compile kernels.
#>
[CmdletBinding()]
param(
    [string]$ComfyUIRoot,
    [int]$TimeoutSeconds = 900
)

. (Join-Path $PSScriptRoot 'Common.ps1')

$root = Find-ComfyUIRoot -Hint $ComfyUIRoot
if (-not $root) { throw "ComfyUI root not found. Pass -ComfyUIRoot." }

$py = Join-Path $root 'venv\Scripts\python.exe'
if (-not (Test-Path $py)) { throw "No $py - the ComfyUI venv is not set up." }

$zluda = Get-ChildItem $root -Recurse -Filter 'zluda.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $zluda) { throw "zluda.exe not found." }

$code = @'
import torch, sys, os

print("torch       ", torch.__version__)
print("cuda avail  ", torch.cuda.is_available())
if not torch.cuda.is_available():
    sys.exit("torch cannot see the GPU, stopping here.")
print("device      ", torch.cuda.get_device_name(0))
print("cudnn       ", torch.backends.cudnn.enabled)

# ComfyUI-Zluda pins these in customzluda/zluda-default.py, and this script has to
# match the real runtime. Left at the torch defaults, attention dispatches to the
# mem-efficient CUTLASS kernels, which are built for sm80+ and abort on RDNA2 with
#   FATAL: kernel `fmha_cutlassF_f16_aligned_64x64_rf_sm80` is for sm80-sm100
# tens of thousands of times, and then reset the display driver (event 4101).
torch.backends.cuda.enable_flash_sdp(False)
torch.backends.cuda.enable_math_sdp(True)
torch.backends.cuda.enable_mem_efficient_sdp(False)
print("sdp backend  math only (flash and mem-efficient off, as ComfyUI-Zluda sets them)")
print()

fail = []

# rocBLAS: missing gfx1031 kernels blow up here
try:
    a = torch.randn(1024, 1024, device="cuda", dtype=torch.float16)
    r = (a @ a).float().sum().item()
    assert r == r, "matmul produced NaN"
    print("matmul fp16  OK")
except Exception as e:
    fail.append(("matmul fp16", e))
    print("matmul fp16  FAILED:", e)

# convolution: blows up here when cuDNN was not disabled
try:
    x = torch.randn(1, 4, 64, 64, device="cuda", dtype=torch.float16)
    w = torch.randn(8, 4, 3, 3, device="cuda", dtype=torch.float16)
    y = torch.nn.functional.conv2d(x, w, padding=1)
    assert y.shape == (1, 8, 64, 64), y.shape
    print("conv2d fp16  OK")
except Exception as e:
    fail.append(("conv2d fp16", e))
    print("conv2d fp16  FAILED:", e)

# attention, on the math backend selected above
try:
    q = torch.randn(1, 8, 256, 64, device="cuda", dtype=torch.float16)
    torch.nn.functional.scaled_dot_product_attention(q, q, q)
    print("sdpa fp16    OK")
except Exception as e:
    fail.append(("sdpa fp16", e))
    print("sdpa fp16    FAILED:", e)

print()
rc = 0
if fail:
    print("%d of 3 checks failed." % len(fail))
    rc = 1
else:
    print("All checks passed; this GPU can run ComfyUI.")

print("__GFX1031_DONE__ %d" % rc)
sys.stdout.flush()
os._exit(rc)
'@

$tmp = Join-Path $env:TEMP "gfx1031-selftest-$PID.py"
$log = Join-Path $env:TEMP "gfx1031-selftest-$PID.log"
Set-Content -Path $tmp -Value $code -Encoding UTF8

# Match how comfyui.bat launches, otherwise this tests a different environment.
$env:TORCH_BACKENDS_CUDNN_ENABLED = '0'
$env:PYTHONIOENCODING = 'utf-8'

Write-Host "Running the self-test in $root (the first run is slow while ZLUDA JIT-compiles kernels)..."
Write-Host ""

$p = Start-Process -FilePath $zluda.FullName -ArgumentList @('--', $py, $tmp) `
    -WorkingDirectory $root -NoNewWindow -PassThru `
    -RedirectStandardOutput $log -RedirectStandardError "$log.err"

# Once the work is done, python under zluda.exe often refuses to exit, spinning
# on CUDA context teardown. So wait for the sentinel line rather than for exit.
$rc = $null
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $log) {
        $m = Select-String -Path $log -Pattern '^__GFX1031_DONE__ (\d+)' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) { $rc = [int]$m.Matches[0].Groups[1].Value; break }
    }
    if ($p.HasExited) { $rc = $p.ExitCode; break }
}

Stop-ProcessTree -Id $p.Id

if (Test-Path $log) {
    Get-Content $log -Encoding UTF8 | Where-Object { $_ -notmatch '^__GFX1031_DONE__' } | ForEach-Object { Write-Host $_ }
}
if ((Test-Path "$log.err") -and (Get-Item "$log.err").Length -gt 0) {
    Write-Host "--- stderr ---" -ForegroundColor DarkGray
    Get-Content "$log.err" -Encoding UTF8 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
}
Remove-Item $tmp, $log, "$log.err" -ErrorAction SilentlyContinue

Write-Host ""
if ($rc -eq 0) {
    Write-Host "Self-test passed." -ForegroundColor Green
} elseif ($null -eq $rc) {
    Write-Host "No result after $TimeoutSeconds seconds. A first run really can take longer while kernels compile; raise -TimeoutSeconds and try again." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "Self-test failed. Look the errors above up in docs\TROUBLESHOOTING.md." -ForegroundColor Red
    exit 1
}
