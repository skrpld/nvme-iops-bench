#!/usr/bin/env bash
# Серия fio-тестов для проверки биллинга IOPS на NVMe-диске облачного сервиса.
#
# Использование:
#   ./02_run_benchmark.sh <TARGET> [SIZE] [OUTDIR]
#
#   TARGET  — путь к тестовому файлу ИЛИ сырое устройство (/dev/nvme1n1).
#             ⚠️ Если TARGET — блочное устройство, ВСЕ ДАННЫЕ НА НЁМ БУДУТ УНИЧТОЖЕНЫ.
#             Используй отдельный/пустой диск, не системный.
#   SIZE    — размер тестового файла, если TARGET — файл (по умолчанию 4G)
#   OUTDIR  — куда складывать json-результаты
#             (по умолчанию /var/tmp/nvme-iops-bench/<timestamp> — CD смонтирован read-only)
#
# Переменные окружения:
#   RUNTIME=30    секунд на каждый под-тест
#   RAMP_TIME=5   секунд прогрева, не попадающих в статистику
#   IOENGINE=     принудительный ioengine (по умолчанию libaio → io_uring → psync)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Сначала ищем статический fio рядом со скриптом (офлайн-бандл), иначе — системный.
if [[ -x "$SCRIPT_DIR/bin/fio" ]]; then
  FIO="$SCRIPT_DIR/bin/fio"
elif command -v fio &>/dev/null; then
  FIO="fio"
else
  echo "❌ fio не найден ни в $SCRIPT_DIR/bin/fio, ни в PATH." >&2
  echo "   Пересобери ISO через GitHub Actions (workflow 'Build offline IOPS-bench ISO')." >&2
  exit 1
fi
echo "Используется fio: $FIO ($("$FIO" --version))"

# Выбор ioengine по факту доступности: в статической сборке движок может отсутствовать,
# а старое ядро на VM может не поддерживать io_uring. Жёсткий --ioengine=libaio ронял прогон.
select_engine() {
  local avail candidate
  avail="$("$FIO" --enghelp 2>/dev/null || true)"
  if [[ -n "${IOENGINE:-}" ]]; then
    if grep -qw -- "$IOENGINE" <<<"$avail"; then echo "$IOENGINE"; return; fi
    echo "❌ ioengine '$IOENGINE' недоступен в этой сборке fio." >&2
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
  echo "⚠️  Синхронный движок игнорирует iodepth — результаты при QD>1 будут занижены." >&2
fi

TARGET="${1:?Укажи TARGET: путь к файлу или блочное устройство}"
SIZE="${2:-4G}"
TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${3:-/var/tmp/nvme-iops-bench/$TS}"
mkdir -p "$OUTDIR"

IS_DEVICE=0
if [[ -b "$TARGET" ]]; then
  IS_DEVICE=1
  echo "⚠️  TARGET — блочное устройство ($TARGET). Данные на нём будут уничтожены."
  read -rp "Продолжить? (yes/no): " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { echo "Отменено."; exit 1; }
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
  echo "▶ $name"
  # --output, а не '>': с --output-format=json fio всё равно печатает в stdout
  # служебные строки ("Laying out IO file...") и ломает JSON.
  "$FIO" "${COMMON[@]}" --runtime="$RUNTIME" --name="$name" \
    --output="$OUTDIR/${name}.json" "$@"
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

# 4. Latency-тест: QD=1, показывает "чистую" задержку диска
run_job "latency_4k_qd1" --rw=randread --bs=4k --iodepth=1 --numjobs=1

# 5. Sequential throughput (для сравнения — обычно не то, что биллится по IOPS)
run_job "seqread_128k" --rw=read --bs=128k --iodepth=32 --numjobs=1
run_job "seqwrite_128k" --rw=write --bs=128k --iodepth=32 --numjobs=1

echo "✅ Готово. JSON-результаты: $OUTDIR"
echo "$OUTDIR" > /tmp/nvme_bench_last_outdir
