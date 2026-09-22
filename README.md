# comfyui-zluda-gfx1031

> **This project has moved to [comfyui-zluda-rdna2](https://github.com/RYZENNAVI/comfyui-zluda-rdna2).**
> This repository is archived and no longer maintained. Everything here is also there, kernel installation included, and the version there has been corrected in places this one was not.

## What happened

This project covered gfx1031 (RX 6700 XT, 6750 XT, 6700). A sister project covered gfx1030 (RX 6950 XT, 6900 XT, 6800 XT, 6800). Once both had been verified against real hardware and the findings were compared, almost everything turned out to be shared: the ZLUDA and HIP version matching, the DLLs that go into `torch\lib`, the launcher that overwrites the file you just patched, and the attention backend that resets the display driver.

Exactly one thing genuinely differs, and it is the kernels. gfx1031 is not on the official AMD ROCm support list, so official rocBLAS ships no kernels for it and they have to be installed; gfx1030 is, so it needs nothing. The merged project detects which card you have and runs the kernel step only where it belongs. `Install-Kernels.ps1`, both Borrow and Download modes, moved across unchanged and was re-verified on an RX 6700 XT.

Keeping two repositories meant every fix had to be made twice, so they were merged.

## What the merged version fixes that this one got wrong

- **cuDNN.** This repository claimed RDNA2 has no cuDNN engine under ZLUDA and that convolutions crash without it disabled, and `Patch-ComfyUI.ps1` set `TORCH_BACKENDS_CUDNN_ENABLED=0` to prevent that. Measured on both architectures, the claim is not true, and on the standard launcher that variable is never read: `comfyui.bat` installs `zluda-default.py`, which hardcodes the setting.
- **Attention.** The driver resets really do happen, but they come from the mem-efficient SDPA backend, whose CUTLASS kernel is built for the wrong SM version. This repository's own `Test-Setup.ps1` used to call SDPA with the default backends, which is exactly the configuration that triggers them.
- **Hardware claims.** The scripts accept every desktop RDNA2 card, but only an RX 6700 XT and an RX 6950 XT have actually been run on, and mobile parts such as the RX 6700S are a different chip entirely. The merged version says so and refuses to classify them.

## Go here instead

**https://github.com/RYZENNAVI/comfyui-zluda-rdna2**

The full history of this repository was merged into it rather than copied, so none of it was lost.
