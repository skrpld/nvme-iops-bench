# NVMe IOPS Billing Benchmark — офлайн через GitHub Actions

Для случая: рабочий ноут без права ставить софт + целевая VM без интернета,
единственный способ занести файлы — примонтировать ISO.

## Шаг 1. Собрать ISO (только браузер, ничего не ставится локально)

1. github.com → New repository → **Private** → создать пустым
2. Add file → Upload files → перетащить сюда содержимое этого архива целиком
   (структура папок должна сохраниться: `.github/workflows/build-iso.yml` —
   именно по такому пути, иначе GitHub Actions его не увидит)
3. Commit changes
4. Вкладка **Actions** → слева "Build offline IOPS-bench ISO" → **Run workflow** → Run workflow
5. Подождать ~2-3 минуты (сборка статического fio с нуля)
6. Открыть завершившийся run (зелёная галка) → внизу блок **Artifacts** →
   скачать `nvme-iops-bench-iso.zip`
7. Распаковать штатным архиватором ОС → внутри `nvme-iops-bench.iso`

## Шаг 2. Использовать на офлайн-VM

```bash
sudo mount /dev/sr0 /mnt/cdrom
cd /mnt/cdrom
```

Определить, какой диск НЕ системный (не запускать тест на системном!):
```bash
ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)")
echo "Системный диск: /dev/$ROOT_DISK — НЕ использовать для теста"
lsblk -d -o NAME,SIZE,MOUNTPOINT | grep -v "$ROOT_DISK"
```

Запуск теста:
```bash
sudo ./02_run_benchmark.sh /dev/nvme1n1
# или безопаснее — файл на смонтированном нецелевом диске:
# sudo ./02_run_benchmark.sh /mnt/data/testfile 4G
```

Если ISO смонтирован без бита выполнения — `sudo bash ./02_run_benchmark.sh ...`.

Отчёт:
```bash
python3 03_generate_report.py "$(cat /tmp/nvme_bench_last_outdir)"
```

## Что тестируется
- Random Read/Write IOPS на 4k блоке при QD 1/8/32/64
- Смешанная нагрузка 70% read / 30% write, QD32 (типичный биллинг-профиль)
- "Чистая" latency на QD=1
- Sequential throughput 128k (для справки, обычно не биллится по IOPS)

## Настройка
| Переменная | По умолчанию | Что делает |
|---|---|---|
| `RUNTIME` | `30` | секунд на каждый под-тест |
| `RAMP_TIME` | `5` | прогрев, не попадающий в статистику |
| `IOENGINE` | автовыбор | принудительный движок fio |

Автовыбор движка: `libaio` → `io_uring` → `psync`. На синхронном движке `iodepth`
игнорируется, и цифры при QD>1 будут занижены — скрипт об этом предупредит.

Пример: `RUNTIME=60 sudo ./02_run_benchmark.sh /dev/nvme1n1`

## Куда пишутся результаты
По умолчанию в `/var/tmp/nvme-iops-bench/<timestamp>/`, а не рядом со скриптом:
CD-ROM смонтирован read-only. Свой путь — третьим аргументом.

## ⚠️ Важно
- `02_run_benchmark.sh` сам ищет `./bin/fio` рядом с собой (кладётся туда workflow'ом при
  сборке ISO) — ничего дополнительно устанавливать на офлайн-VM не нужно.
- Если TARGET — блочное устройство целиком, все данные на нём будут уничтожены.
  Скрипт запросит подтверждение.
- Единственная внешняя зависимость на офлайн-VM — `python3` для отчёта (обычно уже установлен).
