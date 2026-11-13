# Unlocking and rooting a Moto G Power 2026 (XT2617V / `vegas26`)

**This is a write-up of what was done to one phone that its owner bought and owns.** It documents a bootloader weakness found by observation, a way around it, and the resulting root setup. It is not a general-purpose unlock service, and it deliberately contains nothing about FRP, IMEI, or carrier/SIM unlocking.

Read [Legal and ethics](#legal-and-ethics) before you do anything with this.

---

## TL;DR

Moto's MediaTek bootloader refuses modified images with `Preflash validation failed`, even when `flashing_unlocked`. That check verifies images against the **active** AVB key rather than a hard-coded one. Install your own key in `avb_custom_key` (permitted while unlocked) and the gate moves onto a key you control. After that, anything you sign boots — including a Magisk-patched `init_boot` and a GSI.

```
Val Protocol LK patch -> fastboot oem unlock -> avb_custom_key
  -> self-signed vbmeta -> Magisk init_boot -> (optional) GSI
```

## Tested configuration

| | |
|---|---|
| Device | moto g power - 2026, `XT2617V`, codename `vegas26` |
| SoC | MT6835 (Dimensity 6300), MediaTek |
| Firmware | `W1WEOS36.48-22-3-3-4-2`, Android 16, patch 2026-04-01 |
| Bootloader | `MBM-3.1-vegas_og_vext-…`, `secure: yes` |
| Result | `securestate: flashing_unlocked`, custom AVB key, Magisk root, GSI |

Other `vegas26` builds and sibling devices are untested here. The LK technique is pattern-based and may transfer; the AVB behaviour may differ.

## Warnings

- Unlocking **wipes all data**. So does the GSI step.
- Unlocking voids warranty and is visible to the carrier forever.
- Replacing the AVB trust root is a **commitment**: afterwards your phone only boots images *you* sign. Stock firmware will not flash as-is.
- OTA updates become unusable. An OTA that partially applies can leave the device unbootable until reflashed.
- On a GSI expect broken camera extras, VoLTE/VoNR, and vendor-specific features.
- Budget for a phone you can afford to lose. Every step here is recoverable from fastboot **only while `lk` and the preloader are intact**. Never write `preloader_a/b`, `seccfg`, `boot_para`, or the GPT.

---

## Prerequisites

- A phone **you own**, with OEM unlocking enabled in Developer options
- adb/fastboot (platform-tools), Python 3.11+
- The stock firmware for **your exact build** (needed for `lk.img` and `init_boot.img`)
- This repo's helper: `scripts/sign-image.sh` (wraps `avbtool`)

Get your build string from `adb shell getprop ro.build.display.id`. Firmware is not redistributed here — use your vendor's tooling or a mirror.

## Step 1 — Unlock the bootloader

Use [val-protocol](https://github.com/Maikyxd/val-protocol) (AGPL-3.0) on `lk.img` extracted from *your* firmware.

```bash
git clone https://github.com/Maikyxd/val-protocol.git
cd val-protocol
python3 -m pip install -r requirements.txt
python3 -m pip install git+https://github.com/R0rt1z2/liblk

# sanity-check the image first (read-only, touches nothing)
python3 lk_static_analyzer.py /path/to/lk.img -o ./analysis --no-full-disasm

python3 lk_auto_patch.py /path/to/lk.img \
  -o lk.unlock-serial.img --preset unlock-serial --key-token-secret "YOUR_SECRET"
```

Then, on the phone:

```bash
adb reboot bootloader
fastboot flash lk lk.unlock-serial.img
fastboot reboot bootloader          # the patched LK loads
fastboot getvar serialno            # note the serial
# generate the key on the host:
#   python3 lk_keygen.py --secret "YOUR_SECRET" --serialno "<SERIAL>" --count 1
fastboot oem unlock <20-CHAR-KEY>
```

Notes:
- The patched LK only matters for issuing `oem unlock`. It is not needed afterwards.
- **Never flash the stock `lk` back** while you still want unlock capability, and skip `lk` if you ever flash full firmware.
- Keep `YOUR_SECRET` and the generated key. Losing them loses re-unlock ability.

If your build is from **September 2026 or later**, this is reported patched. The upstream author states US builds with the fix start with `V` instead of `W`; treat August 2026 as untested.

## Step 2 — The wall

With the bootloader unlocked, flashing a patched `init_boot` fails:

```
Writing 'init_boot_a'
(bootloader) Preflash validation failed
FAILED (remote: '')
```

That message has exactly one reference in `lk` (LK base `0xffff000050f00000`, `W1WEOS36.48-22-3-3`):

```
0xffff000050f12324  wrapper - prints the message (string at 0xffff000050fecd38)
0xffff000050f9c970  dispatch on partition name
0xffff000050f9cd20  table lookup for the partition
0xffff000050fbb364  verify image against vbmeta descriptors   <-- the gate
```

It is AVB verification against descriptors signed by the OEM, and it runs even when unlocked and even with verification disabled. That is why patching a boot image cannot work on these builds — until the key changes.

## Step 3 — Replace the trust root

Verified live on the configuration above: the gate honours `avb_custom_key`.

```bash
# 1. your own signing key (never publish this)
openssl genrsa -out avb_key.pem 2048
python3 avbtool.py extract_public_key --key avb_key.pem --output avb_pub.bin

# 2. install it as the device's trusted key (allowed while unlocked)
adb reboot bootloader
fastboot flash avb_custom_key avb_pub.bin
```

Build a `vbmeta` signed with your key. Keep verification disabled (`--flags 2`) for the first attempt — it makes a wrong descriptor non-fatal:

```bash
python3 avbtool.py make_vbmeta_image \
  --output vbmeta.ourkey.img --key avb_key.pem --algorithm SHA256_RSA2048 \
  --flags 2 --rollback_index 2 --padding_size 8192 \
  --include_descriptors_from_image init_boot.ourkey.img
fastboot flash vbmeta vbmeta.ourkey.img
```

**Rollback index gotcha:** the device's stored rollback index rises with OTAs. A `vbmeta` claiming an index below it will refuse to boot and you get a bootloop. Set `--rollback_index` at or above the build you are on. Do **not** flash a stock `vbmeta` back afterwards.

## Step 4 — Root

Patch `init_boot.img` from *your* firmware with Magisk (headless is fine — it runs the same `boot_patch.sh` the app does), then sign it with your key:

```bash
adb push init_boot.img /data/local/tmp/magisk/
adb shell 'cd /data/local/tmp/magisk && KEEPVERITY=true KEEPFORCEENCRYPT=true sh boot_patch.sh init_boot.img'
adb pull /data/local/tmp/magisk/new-boot.img init_boot.magisk.img

./scripts/sign-image.sh init_boot.magisk.img init_boot init_boot.ourkey.img avb_key.pem 8388608
fastboot flash init_boot init_boot.ourkey.img
```

Boot, then set Magisk → Settings → **Superuser access → Apps and ADB**. On a GSI, `su` may not be on `PATH`:

```bash
adb shell /debug_ramdisk/su -c id     # uid=0(root)
```

## Step 5 — Optional: GSI

Only after fastbootd is confirmed working (`adb reboot fastboot`, `fastboot getvar is-userspace` → `yes`).

Check `system` size first — OEM layouts often put the space in `product`:

```bash
fastboot getvar partition-size:system_a
fastboot delete-logical-partition product_a
fastboot resize-logical-partition system_a 4294967296
fastboot flash system_a system.img
fastboot -w
fastboot reboot
```

Keep your `vbmeta` with verification disabled, or the GSI will not boot. Recovery is reflashing the stock `super` sparse chunks in order.

## Step 6 — Optional: cosmetics

Fonts and boot animation can be shipped as a Magisk module (`system/fonts/…`, `system/product/media/bootanimation.zip`). Note that a GSI may have **no** `/system/media/bootanimation.zip` at all, and Android 16 looks under `/product/media` on this device.

---

## Recovery

| symptom | fix |
|---|---|
| bootloop after a bad `vbmeta` | `fastboot flash vbmeta <your vbmeta>.img` (rollback index high enough) |
| Magisk ramdisk won't boot | flash a stock `init_boot` re-signed with your key |
| system unusable | fastbootd → reflash stock `super` sparse chunks |
| data unmountable | recovery → factory reset |
| want to abandon the custom key | `fastboot erase avb_custom_key`, then a working `vbmeta` |

Fastboot lives in `lk`, so "system won't boot" is never "no recovery" — unless you write the preloader.

## What this does not cover

FRP bypass, IMEI/modem modification, and SIM/carrier unlocking are **out of scope on purpose**. Carrier unlock is a carrier process; in the US it is a support request, not a software step.

## Legal and ethics

- Do this to hardware you own. Unlocking your own phone for interoperability falls under the DMCA anti-circumvention exemptions for wireless handsets in the US; other jurisdictions differ.
- **Disclose before publishing.** The behaviour described in Step 2 is a bootloader design weakness. Report it to the vendor and give them time before a public write-up: Motorola Mobility PSIRT, `mbgpsirt@lenovo.com` (see `disclosure.md`).
- Do not redistribute OEM firmware. Link to sources instead.
- Never publish a private signing key. The commands are the useful part; your key is not.
- The upstream tools keep their own licenses: val-protocol is AGPL-3.0, Magisk is GPL-3.0, `avbtool` is Apache-2.0.

## Credits

- [Maikyxd/val-protocol](https://github.com/Maikyxd/val-protocol) — LK analysis and patching
- [R0rt1z2/liblk](https://github.com/R0rt1z2/liblk) — LK container parsing
- [topjohnwu/Magisk](https://github.com/topjohnwu/Magisk) — root
- `avbtool` from AOSP/`external/avb` — signing and descriptors
