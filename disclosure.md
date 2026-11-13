# Draft: vulnerability report to Motorola Mobility PSIRT

To: `mbgpsirt@lenovo.com` (or the form at https://en-us.support.motorola.com/app/emailform)
Subject: Bootloader preflash validation honours custom AVB key on MT6835 Moto devices

---

## Summary

On a moto g power - 2026 (`XT2617V`, `vegas26`, MediaTek MT6835), with the
bootloader in `flashing_unlocked` state, the bootloader's "preflash validation"
check verifies flashed images against the **active** AVB key, which an unlocked
user can replace via the `avb_custom_key` partition.

Consequence: an unlocked device can flash arbitrary `boot` / `init_boot` /
`vbmeta` images signed by a third-party key, in addition to stock-signed ones.
I am reporting this because the intent of preflash validation appears to be to
limit flashing to OEM-signed images even after unlock; the current
implementation does not achieve that.

Related observation, same device: an unsigned `vbmeta` (algorithm NONE, no
descriptors) is accepted by `fastboot flash vbmeta`, and boots, provided its
rollback index is not below the stored value.

## Affected

- moto g power - 2026, `XT2617V`, build `W1WEOS36.48-22-3-3-4-2`
- LK version string `MBM-3.1-vegas_og_vext-5d518d-W1WEOS36.48-22-3-3-…`
- Presumably other MT6835 Motorola devices sharing this LK line; not tested.

## Reproduction (high level)

1. Unlock the bootloader (legitimate `fastboot oem unlock` path).
2. `fastboot flash avb_custom_key <third-party public key>` — accepted.
3. `fastboot flash vbmeta <vbmeta signed by that key>` — accepted.
4. `fastboot flash init_boot <modified image signed by that key>` — accepted.

By contrast, without step 2 the same modified image is rejected with
`Preflash validation failed`.

## Static analysis of the check

LK base `0xffff000050f00000`, payload extracted from `lk.img`:

```
0xffff000050f12324  wrapper; prints "Preflash validation failed" (0xffff000050fecd38)
0xffff000050f9c970  dispatch on partition name
0xffff000050f9cd20  table lookup {partition name, hash/verify handler}
0xffff000050fbb364  AVB verification of the image against vbmeta descriptors
```

The verification path resolves its trust anchor at runtime rather than using a
compiled-in OEM key, hence the custom-key behaviour.

## Impact

- An unlocked device can run modified boot images. This is broadly expected of
  unlocked devices on other platforms, so the severity is likely low, and this
  may be working as designed. It is documented here because the error text and
  check placement suggest the opposite intent.
- No bypass of the lock state itself, and no impact on `oem_locked` devices was
  found: the same path is refused unless the device reports unlocked.

## Notes

- A related user-space path (`lk_auto_patch`, public) exploits LK certificate
  handling to make `oem unlock` accept a device-specific key on locked devices.
  That issue is already public and reported by its author; it is mentioned only
  for completeness. I have no involvement in that project.
- I have not published a write-up. I will hold it for 90 days from this report,
  or until you confirm a fix has shipped, whichever comes first.
- Happy to provide the analyzed image digest, the exact `avbtool`/`fastboot`
  transcripts, and the two comparison images used.

## Contact

<name>, <email>. Device is my own, purchased retail.
