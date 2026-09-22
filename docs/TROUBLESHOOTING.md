# Troubleshooting

Look up what you are seeing. For most problems `scripts\Check-Environment.ps1` points straight at the cause.

## Error lookup

| Symptom | What is actually wrong | Fix |
|---|---|---|
| Exit code `0xC0000135`<br>(STATUS_DLL_NOT_FOUND) | The `amdhip64_N.dll` that ZLUDA wants is missing. ZLUDA's `nvcuda.dll` **hardcodes the major version** in its import table | Match them up: ZLUDA 3.9.5 needs HIP 6.x (`amdhip64_6.dll`), ZLUDA 3.9.6 needs HIP 7.x (`amdhip64_7.dll`) |
| Exit code `0xC0000139`<br>(STATUS_ENTRYPOINT_NOT_FOUND) | The DLL was found, but it does not export what was asked for | Still a version mix. Check whether a different version of `amdhip64*.dll` is being loaded first from PATH |
| `WinError 126: the specified module could not be found`<br>(on `import torch`) | Python 3.8+ **no longer searches PATH** for extension-module DLL dependencies | The DLLs must go directly into `venv\Lib\site-packages\torch\lib`. Editing PATH does nothing at all |
| `no kernel image is available for execution` | rocBLAS has no gfx1031 kernels | `scripts\Install-Kernels.ps1` |
| `hipErrorNoBinaryForGpu` | Same as above | Same as above |
| `AttributeError: module 'comfy_kitchen' has no attribute 'int8_attention_is_available'` | That function does not exist under ZLUDA | `scripts\Patch-ComfyUI.ps1` |
| Access violation during convolution, or the process dies silently | RDNA2 has no cuDNN engine under ZLUDA, but ComfyUI-Zluda turns cuDNN back on | Set `TORCH_BACKENDS_CUDNN_ENABLED=0` before launching, or run `Patch-ComfyUI.ps1` |
| Access violation while loading a large model | The safetensors mmap path faults under memory pressure | Add `--disable-mmap` to the launch arguments |
| The first generation hangs for ten minutes or more | Expected. ZLUDA is JIT-compiling kernels | Wait. They are cached in `%LOCALAPPDATA%\ZLUDA\ComputeCache` and later runs are fast |
| HIP is installed but behaves as if it is not | Several versions installed with the wrong PATH order, or a user-scope environment variable shadowing the machine scope | See "Several HIP versions side by side" below |

## The awkward details

### HIP SDK installed, but `bin` has no `amdhip64.dll`

The installer sometimes skips the core runtime. On one machine HIP 5.7.1 installed with only 14 DLLs in `bin`, missing the one that matters.

Take it from the driver package:

```
C:\Windows\System32\DriverStore\FileRepository\amdocl.inf_amd64_*\
```

Several versions live there, and you **must pick the one matching your installed display driver**. The wrong version crashes just the same.

### Several HIP versions side by side

Three things have to line up, and any one of them being wrong breaks everything:

1. **PATH order** — the `bin` directory of the version you want has to come first.
2. **`HIP_PATH`** — note that a **user-scope variable overrides the machine scope**. The installer writes the machine scope, so a user-scope value you set by hand silently wins. This one is easy to miss.
3. **The ZLUDA major version** — see the error table above.

`Check-Environment.ps1` checks all three.

### Borrowed gfx1030 kernels vs community-built gfx1031 kernels

Both work. gfx1030 and gfx1031 are both RDNA2 and ISA-compatible, so borrowed kernels run correctly; their tuning parameters were just chosen for a slightly different GPU. Start with `-Mode Borrow`, switch to `-Mode Download` if performance matters.

### Why `.dat` needs an equal-length replacement

`.dat` files are rocBLAS binary manifests with hardcoded offsets. `gfx1030` and `gfx1031` happen to be the same 7 bytes long, so the only safe edit is **overwriting those 7 bytes in place**.

A text-mode replacement, or renaming to anything of a different length, corrupts the structure. rocBLAS then fails to load with no useful diagnostic.

`.hsaco` and `.co` files are compiled code objects. Same ISA, so the contents are fine as they are and only the filename changes.

Note that the naming is not consistent: most files are `..._gfx1030.xxx`, but `Kernels.so-000-gfx1030.hsaco` uses a hyphen. Matching on `_gfx1030` alone silently skips it, along with every `.co` file.

## Still stuck

Run these two and include their output in an issue:

```powershell
.\scripts\Check-Environment.ps1
.\scripts\Test-Setup.ps1
```
