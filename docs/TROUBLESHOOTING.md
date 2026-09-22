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
| Thousands of `FATAL: kernel fmha_cutlassF_..._sm80 is for sm80-sm100, but was built for sm37`, then the screen blanks and the display driver resets (event 4101) | Attention dispatched to the mem-efficient backend, whose CUTLASS kernels are built for sm80+ | Pin attention to the math backend, or use `--use-quad-cross-attention`. See "Attention backends" below |
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

### Attention backends: the one thing that really does reset the display driver

torch picks an SDPA backend at runtime. On this hardware:

| Backend | Selected? | Result |
|---|---|---|
| flash | no, `can_use_flash_attention` returns False | never runs |
| mem-efficient | yes, by default | **resets the display driver** |
| math | only if you pin it | fine |

The mem-efficient backend uses CUTLASS kernels built for sm80-sm100. ZLUDA reports
compute capability (8, 8), so torch selects them, and they then abort with

```
FATAL: kernel `fmha_cutlassF_f16_aligned_64x64_rf_sm80` is for sm80-sm100, but was built for sm37
```

Measured on an RX 6700 XT: ten `scaled_dot_product_attention` calls on a
1x8x256x64 fp16 tensor produced 36864 of those lines and event 4101 one second
after the process ended. The driver recovered on its own. The same test on an RX
6950 XT (gfx1030) needed a hard reboot two times out of three, so treat the
failure as identical across RDNA2 but the consequences as worse on gfx1030.

You are not normally exposed to this, for two independent reasons:

- ComfyUI-Zluda pins the backends in `customzluda\zluda-default.py`:
  `enable_flash_sdp(False)`, `enable_math_sdp(True)`, `enable_mem_efficient_sdp(False)`
- the usual launch arguments include `--use-quad-cross-attention`, which computes
  attention as chunked matmuls and never calls SDPA at all

It matters when you write your own probe script. Bare torch, with no
`comfy.zluda` import, uses the defaults and will reset your driver. Set the three
backend flags first. To check which backend would be chosen without running
anything:

```python
from torch.backends.cuda import SDPAParams, can_use_flash_attention, can_use_efficient_attention
q = torch.randn(1, 8, 256, 64, device="cuda", dtype=torch.float16)
p = SDPAParams(q, q, q, None, 0.0, False, False)
print(can_use_flash_attention(p, False), can_use_efficient_attention(p, False))
```

### cuDNN is fine, despite what you may read

Convolution with cuDNN enabled works: `torch.backends.cudnn.is_available()` is
True, version 9.1.0, and a 320->320 3x3 convolution at 128x128 fp16 runs in
0.0147s with no driver event. An earlier version of this document claimed RDNA2
has no cuDNN engine and that convolutions crash. That did not reproduce on either
gfx1031 or gfx1030 and has been removed.

The launcher disables cuDNN anyway, so this is not something you need to act on.

### Patching comfy\zluda.py does not survive a restart

`comfyui.bat` runs `copy comfy\customzluda\zluda-default.py comfy\zluda.py /y`
twice per launch, before and after the git update, and `comfy\model_management.py`
imports `comfy.zluda`. Any edit to `comfy\zluda.py` is overwritten on the next
start. Patch `customzluda\zluda-default.py` instead.

The nightly launchers differ: `comfyui-n.bat` and `comfyui-user.bat` copy
`customzluda\zluda.py` over it afterwards, and that file reads
`TORCH_BACKENDS_CUDNN_ENABLED` (defaulting to enabled) where `zluda-default.py`
hardcodes cuDNN off.

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
