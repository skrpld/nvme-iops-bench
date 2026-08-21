#!/usr/bin/env bash
# Серия fio-тестов для проверки биллинга IOPS на NVMe-диске облачного сервиса.
#
# Использование:
#   ./02_run_benchmark.sh <TARGET> [SIZE] [OUTDIR]
#
#   TARGET  — путь к тестовому файлу (по умолчанию режим) ИЛИ сырое устройство (/dev/nvme1n1).
#             ⚠️ Если TARGET — блочное устройство, ВСЕ ДАННЫЕ НА НЁМ БУДУТ УНИЧТОЖЕНЫ.
#             Используй отдельный/пустой диск, не системный.
#   SIZE    — размер тестового файла, если TARGET — файл (по умолчанию 4G)
#   OUTDIR  — куда складывать json-результаты (по умолчанию ./results/<timestamp>)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Сначала ищем статический fio рядом со скриптом (офлайн-бандл), иначе — системный.
if [[ -x "$SCRIPT_DIR/bin/fio" ]]; then
  FIO="$SCRIPT_DIR/bin/fio"
elif command -v fio &>/dev/null; then
  FIO="fio"
else
  echo "❌ fio не найден ни в $SCRIPT_DIR/bin/fio, ни в PATH." >&2
  echo "   Собери офлайн-бандл через 00_build_static_fio.sh на машине с интернетом." >&2
  exit 1
fi
echo "Используется fio: $FIO ($("$FIO" --version))"

TARGET="${1:?Укажи TARGET: путь к файлу или блочное устройство}"
SIZE="${2:-4G}"
TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${3:-./results/$TS}"
mkdir -p "$OUTDIR"

IS_DEVICE=0
if [[ -b "$TARGET" ]]; then
  IS_DEVICE=1
  echo "⚠️  TARGET — блочное устройство ($TARGET). Данные на нём будут уничтожены."
  read -rp "Продолжить? (yes/no): " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { echo "Отменено."; exit 1; }
fi

COMMON=(--filename="$TARGET" --direct=1 --ioengine=libaio --group_reporting
        --output-format=json --time_based)
[[ $IS_DEVICE -eq 0 ]] && COMMON+=(--size="$SIZE")

RUNTIME="${RUNTIME:-30}"   # секунд на тест, override через env RUNTIME=60

run_job () {
  local name="$1"; shift
  echo "▶ $name"
  "$FIO" "${COMMON[@]}" --runtime="$RUNTIME" --name="$name" "$@" \
    > "$OUTDIR/${name}.json"
}

# 1. Random Read IOPS, 4k блок, разные глубины очереди
for qd in 1 8 32 64; do
  run_job "randread_4k_qd${qd}" --rw=randread --bs=4k --iodepth="$qd" --numjobs=1
done

# 2. Random Write IOPS, 4k блок, разные глубины очереди
for qd in 1 8 32 64; do
  run_job "randwrite_4k_qd${qd}" --rw=randwrite --bs=4k --iodepth="$qd" --numjobs=1
done

# 3. Смешанная нагрузка 70/30 read/write (типичный профиль биллинга IOPS)
run_job "randrw_70r30w_4k_qd32" --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --numjobs=4

# 4. Latency-тест: QD=1, синхронный, показывает "чистую" задержку диска
run_job "latency_4k_qd1" --rw=randread --bs=4k --iodepth=1 --numjobs=1

# 5. Sequential throughput (для сравнения — обычно не то, что биллится по IOPS)
run_job "seqread_128k" --rw=read --bs=128k --iodepth=32 --numjobs=1
run_job "seqwrite_128k" --rw=write --bs=128k --iodepth=32 --numjobs=1

echo "✅ Готово. JSON-результаты: $OUTDIR"
echo "$OUTDIR" > /tmp/nvme_bench_last_outdir
