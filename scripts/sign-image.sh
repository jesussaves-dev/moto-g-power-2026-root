#!/bin/sh
# Re-sign an Android image so a bootloader with a custom AVB key will accept it.
#
# usage: sign-image.sh <input.img> <partition-name> <output.img> <key.pem> <partition-size-bytes>
#
# Example:
#   ./sign-image.sh init_boot.magisk.img init_boot init_boot.ourkey.img avb_key.pem 8388608
#
# The rollback index is left at 0. If the device refuses to boot, pass
# --rollback_index <n> to add_hash_footer below, with n >= the device's stored
# rollback index (it rises with every OTA).

set -eu

if [ $# -ne 5 ]; then
    echo "usage: $0 <input.img> <partition-name> <output.img> <key.pem> <partition-size>" >&2
    exit 2
fi

IN=$1 PART=$2 OUT=$3 KEY=$4 SIZE=$5
DIR=$(cd "$(dirname "$0")/.." && pwd)
AVB="$DIR/tools/avbtool"

[ -f "$IN" ]  || { echo "no such image: $IN" >&2; exit 1; }
[ -f "$KEY" ] || { echo "no such key: $KEY" >&2; exit 1; }
[ -x "$AVB" ] || { echo "missing $AVB" >&2; exit 1; }
case "$SIZE" in ''|*[!0-9]*) echo "partition-size must be decimal bytes" >&2; exit 1 ;; esac

cp "$IN" "$OUT"

# Images that already carry a footer must have it removed, or add_hash_footer
# refuses because the file is larger than its own payload.
python3 "$AVB" erase_footer --image "$OUT" >/dev/null 2>&1 || true

python3 "$AVB" add_hash_footer \
    --image "$OUT" \
    --partition_name "$PART" \
    --partition_size "$SIZE" \
    --key "$KEY" \
    --algorithm SHA256_RSA2048 >/dev/null

# Self-check: the result must parse, be the full partition size, and be signed.
python3 "$AVB" info_image --image "$OUT" >/tmp/sign-image.$$.txt
grep -q 'Algorithm:[[:space:]]*SHA256_RSA2048' /tmp/sign-image.$$.txt || {
    echo "FAILED: output has no RSA signature" >&2; rm -f /tmp/sign-image.$$.txt "$OUT"; exit 1; }
grep -q "Partition Name:[[:space:]]*$PART" /tmp/sign-image.$$.txt || {
    echo "FAILED: descriptor names the wrong partition" >&2; rm -f /tmp/sign-image.$$.txt "$OUT"; exit 1; }
actual=$(wc -c < "$OUT" | tr -d ' ')
[ "$actual" = "$SIZE" ] || {
    echo "FAILED: size $actual, expected $SIZE" >&2; rm -f /tmp/sign-image.$$.txt "$OUT"; exit 1; }
rm -f /tmp/sign-image.$$.txt

echo "signed $OUT ($PART, $SIZE bytes) with $(basename "$KEY")"
