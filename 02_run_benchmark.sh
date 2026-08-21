#!/usr/bin/env bash
# fio benchmark suite for verifying a cloud provider's NVMe IOPS billing claims.
#
# Usage:
#   ./02_run_benchmark.sh <TARGET> [SIZE] [OUTDIR]
#
#   TARGET  path to a test file, or a raw block device (/dev/nvme1n1).
#           A block device is overwritten in full. Use an empty, non-system disk.
#   SIZE    test file size when TARGET is a file (default 4G)
#   OUTDIR  where the json results go (default /var/tmp/nvme-iops-bench/<timestamp>)
#
# Environment:
#   RUNTIME=30    seconds per sub-test
#   RAMP_TIME=5   warm-up seconds excluded from the statistics
#   IOENGINE=     force an ioengine (default: libaio -> io_uring -> psync)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR/bin/fio" ]]; then
  FIO="$SCRIPT_DIR/bin/fio"
elif command -v fio &>/dev/null; then
  FIO="fio"
else
  echo "fio not found in $SCRIPT_DIR/bin/fio or in PATH." >&2
  echo "Rebuild the ISO via the 'Build offline IOPS-bench ISO' workflow." >&2
  exit 1
fi
echo "fio: $FIO ($("$FIO" --version))"

# An engine may be missing from the static build, and io_uring needs kernel >= 5.1,
# so pick what is actually available rather than assuming libaio.
select_engine() {
  local avail candidate
  avail="$("$FIO" --enghelp 2>/dev/null || true)"
  if [[ -n "${IOENGINE:-}" ]]; then
    if grep -qw -- "$IOENGINE" <<<"$avail"; then echo "$IOENGINE"; return; fi
    echo "ioengine '$IOENGINE' is not available in this fio build." >&2
    exit 1
  fi
  for candidate in libaio io_uring psync; do
    if grep -qw -- "$candidate" <<<"$avail"; then echo "$candidate"; return; fi
  done
  echo "sync"
}
ENGINE="$(select_engine)"
echo "ioengine: $ENGINE"
if [[ "$ENGINE" == "psync" || "$ENGINE" == "sync" ]]; then
  echo "WARNING: a synchronous engine ignores iodepth; QD>1 results will be understated." >&2
fi

TARGET="${1:?TARGET required: a file path or a block device}"
SIZE="${2:-4G}"
TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${3:-/var/tmp/nvme-iops-bench/$TS}"
mkdir -p "$OUTDIR"

IS_DEVICE=0
if [[ -b "$TARGET" ]]; then
  IS_DEVICE=1
  echo "WARNING: $TARGET is a block device. All data on it will be destroyed."
  read -rp "Continue? (yes/no): " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

RUNTIME="${RUNTIME:-30}"
RAMP_TIME="${RAMP_TIME:-5}"

COMMON=(--filename="$TARGET" --direct=1 --ioengine="$ENGINE" --group_reporting
        --output-format=json --time_based --ramp_time="$RAMP_TIME")
if [[ $IS_DEVICE -eq 0 ]]; then
  COMMON+=(--size="$SIZE")
fi

run_job () {
  local name="$1"; shift
  echo "> $name"
  # --output rather than a shell redirect: fio still prints progress lines to
  # stdout under --output-format=json, which would corrupt the file.
  "$FIO" "${COMMON[@]}" --runtime="$RUNTIME" --name="$name" \
    --output="$OUTDIR/${name}.json" "$@"
}

for qd in 1 8 32 64; do
  run_job "randread_4k_qd${qd}" --rw=randread --bs=4k --iodepth="$qd" --numjobs=1
done

for qd in 1 8 32 64; do
  run_job "randwrite_4k_qd${qd}" --rw=randwrite --bs=4k --iodepth="$qd" --numjobs=1
done

run_job "randrw_70r30w_4k_qd32" --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --numjobs=4
run_job "latency_4k_qd1" --rw=randread --bs=4k --iodepth=1 --numjobs=1
run_job "seqread_128k" --rw=read --bs=128k --iodepth=32 --numjobs=1
run_job "seqwrite_128k" --rw=write --bs=128k --iodepth=32 --numjobs=1

echo "Done. JSON results: $OUTDIR"
echo "$OUTDIR" > /tmp/nvme_bench_last_outdir
