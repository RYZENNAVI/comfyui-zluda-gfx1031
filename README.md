# comfyui-zluda-gfx1031

Get ComfyUI running on an **RX 6700 / 6700 XT / 6750 XT** (gfx1031) under ZLUDA on Windows.

## Why this GPU needs its own project

gfx1031 is not on the official AMD ROCm support list. That is not a performance gap — **official rocBLAS ships no kernels for this GPU at all**, so the first matmul dies with `no kernel image is available`.

Work around that and four more problems follow, each with a misleading error message:

1. **No gfx1031 kernels** in official rocBLAS.
2. **ZLUDA and HIP major versions must match exactly.** ZLUDA's `nvcuda.dll` hardcodes `amdhip64_6.dll` or `amdhip64_7.dll` in its import table. A mismatch gives you a bare `0xC0000135` and nothing else to go on.
3. **Python 3.8+ no longer searches PATH** for extension-module DLL dependencies. Editing PATH does nothing; the DLLs have to sit in `venv\Lib\site-packages\torch\lib`.
4. **Attention resets the display driver** if torch is left at its defaults. ZLUDA reports compute capability (8, 8), so torch dispatches attention to the mem-efficient backend, whose CUTLASS kernels are built for sm80+ and abort thousands of times before taking the driver down with them. ComfyUI-Zluda pins the backends to math-only, so you only meet this when writing your own test script.

Each of these is findable on its own. Assembling a combination that actually works is the hard part. This project scripts the whole thing.

## Usage

Run as Administrator when HIP lives under `Program Files` (the scripts check whether they can write, and say so if not).

```powershell
git clone https://github.com/RYZENNAVI/comfyui-zluda-gfx1031
cd comfyui-zluda-gfx1031
.\install.ps1
```

Reopen your terminal afterwards, then launch ComfyUI as usual.

### Individual steps

```powershell
.\scripts\Check-Environment.ps1    # read-only diagnostics; run this first whenever something breaks
.\scripts\Install-Kernels.ps1      # install gfx1031 kernels
.\scripts\Patch-ComfyUI.ps1        # patch ComfyUI
.\scripts\Test-Setup.ps1           # run matmul, conv2d and SDPA on the GPU
```

### Two kernel sources

```powershell
.\install.ps1                  # default: borrow the gfx1030 kernels (same RDNA2 ISA)
.\install.ps1 -Mode Download   # download community-built real gfx1031 kernels, usually faster
```

Start with the default to get a working setup, then switch to `-Mode Download` if it feels slow. Download mode replaces the rocBLAS library outright; the original is kept as `library.bak` next to it.

|  | Borrow | Download |
|---|---|---|
| Network needed | no | yes |
| Third-party binaries | none | yes (upstream is GPL-3.0) |
| Works | yes, gfx1030 and gfx1031 are ISA-compatible | yes |
| Performance | tuning parameters were chosen for gfx1030 | compiled for actual gfx1031 |

## Requirements

- Windows 10/11
- RX 6700 / 6700 XT / 6750 XT
- A working [ComfyUI-Zluda](https://github.com/patientx/ComfyUI-Zluda) install
- HIP SDK for Windows, matching your ZLUDA version: ZLUDA 3.9.5 goes with HIP 6.x, 3.9.6 with HIP 7.x
- [7-Zip](https://www.7-zip.org/) for `-Mode Download` — upstream packs are `.7z`, which the bundled Windows tools cannot extract

## When something breaks

Run `.\scripts\Check-Environment.ps1` first, then look the error up in **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**, which maps each error code and symptom to its real cause.

## Third-party kernels

`-Mode Download` fetches from these at install time:

- [likelovewant/ROCmLibs-for-gfx1103-AMD780M-APU](https://github.com/likelovewant/ROCmLibs-for-gfx1103-AMD780M-APU)
- [brknsoul/ROCmLibs](https://github.com/brknsoul/ROCmLibs)

**This repository redistributes none of those binaries.** They are GPL-3.0, and redistributing them would carry the corresponding obligations. The scripts only help you download them from upstream; whether to install them is your call. The scripts in this repository are MIT.
