<div align="center">

# Fix-FakeUSB

**Find the real capacity of a fake USB stick (sold as "2 TB", actually 32 GB), shrink it to that size, verify every byte and format it. One double-click on stock Windows, nothing to install.**

![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
![C#](https://img.shields.io/badge/C%23-inline%20engine-239120?logo=csharp&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

</div>

---

## The problem

Marketplaces are full of USB sticks whose controller firmware **lies about capacity**. Writes past the real flash size are silently dropped or wrap around and overwrite earlier data, so you only find out when your files are corrupted. Generic tools tell you the stick is fake; they don't make it usable.

## What it does

1. **Quick probe (1–10 min):** writes small tagged blocks across the whole *reported* size, highest address first, then reads them back. On a fake, blocks past the real capacity come back as zeros, junk, I/O errors, or **aliases** of lower addresses. Writing top-down means the genuine low block is written last, so an alias shows a foreign header and gets caught.
2. **Exact measurement (optional, 1–3 h):** writes and reads back every byte up to the suspected limit, with periodic spot-checks of older data, a live ETA and Esc to stop while keeping what's already proven.
3. **Fix:** creates a partition at **95% of the measured real size** (safety margin), formats it exFAT or FAT32 and labels it. From then on, phones and PCs show the true size.

There's also a **controller info** option that prints the VID:PID, in case you want to look for a firmware reflash tool.

## How it's built

- A **C# engine compiled on the fly** inside PowerShell (`Add-Type`) opens the raw disk with `FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH`, so reads hit the flash and not the OS cache.
- Every test block carries a **header with its own offset + a per-run nonce** and a pseudo-random payload derived from both, so stale data from a previous run or an aliased block can never pass as valid.
- Plain Windows PowerShell 5.1 + `diskpart`. No dependencies, no downloads.

## Safety rails

- Only **USB disks** are listed; system and boot disks are never offered.
- **Nothing is written** until you type `WIPE <disk number>`.
- The disk's identity (name, serial, size) is **re-checked before every destructive step**, so a stick swapped mid-run gets refused.
- It asks for Administrator rights itself (needed for raw disk access).

> ⚠️ Fixing a stick **erases everything on it**.

## Usage

1. Download `Fix-FakeUSB.ps1` and `Fix-FakeUSB.bat` into the same folder.
2. Double-click **`Fix-FakeUSB.bat`** and accept the admin prompt.
3. Pick the USB disk and choose:
   - `[1] Fix it`: measure the exact real size, shrink and format (recommended)
   - `[2] Quick fix`: estimate in minutes, shrink and format (not verified)
   - `[3] Controller info`: VID/PID for a firmware reflash

```powershell
# or from an elevated PowerShell, targeting a disk directly
.\Fix-FakeUSB.ps1 -Disk 3
```

After the fix, don't reformat the stick from a phone, TV or camera, because some of them rewrite the fake size. If it ever shows the fake size again, run the tool again.

---

<sub>Built by **Nicolas Di Prospero** · [github.com/nicodiprospero](https://github.com/nicodiprospero)</sub>
