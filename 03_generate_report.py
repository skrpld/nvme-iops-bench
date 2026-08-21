#!/usr/bin/env python3
"""
Собирает markdown-отчёт по IOPS/throughput/latency из json-файлов fio.

Использование:
    python3 03_generate_report.py <OUTDIR> [report.md]
"""
import json
import sys
import glob
import os
from datetime import datetime

def load_jobs(outdir):
    jobs = []
    for path in sorted(glob.glob(os.path.join(outdir, "*.json"))):
        with open(path) as f:
            data = json.load(f)
        for job in data.get("jobs", []):
            job["_file"] = os.path.basename(path)
            jobs.append(job)
    return jobs

def fmt(v, unit=""):
    if v is None:
        return "-"
    return f"{v:,.0f}{unit}" if v >= 1000 else f"{v:.1f}{unit}"

def row(job):
    name = job.get("jobname", job["_file"])
    r, w = job.get("read", {}), job.get("write", {})
    iops = round((r.get("iops", 0) or 0) + (w.get("iops", 0) or 0))
    bw_kb = (r.get("bw", 0) or 0) + (w.get("bw", 0) or 0)
    bw_mb = bw_kb / 1024
    lat_ns = r.get("lat_ns", {}).get("mean") or w.get("lat_ns", {}).get("mean") or 0
    lat_us = lat_ns / 1000
    lat_p99_ns = r.get("clat_ns", {}).get("percentile", {}).get("99.000000") \
        or w.get("clat_ns", {}).get("percentile", {}).get("99.000000") or 0
    lat_p99_us = lat_p99_ns / 1000
    return name, iops, bw_mb, lat_us, lat_p99_us

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    outdir = sys.argv[1]
    report_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(outdir, "report.md")

    jobs = load_jobs(outdir)
    if not jobs:
        print(f"⚠️ Не найдено json-файлов в {outdir}", file=sys.stderr)
        sys.exit(1)

    lines = []
    lines.append(f"# Отчёт по NVMe IOPS-бенчмарку")
    lines.append(f"")
    lines.append(f"Дата: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"Источник данных: `{outdir}`")
    lines.append(f"")
    lines.append("| Тест | IOPS | Throughput (MB/s) | Ср. latency (µs) | p99 latency (µs) |")
    lines.append("|---|---:|---:|---:|---:|")

    parsed = [row(j) for j in jobs]
    for name, iops, bw_mb, lat_us, lat_p99_us in parsed:
        lines.append(f"| {name} | {fmt(iops)} | {fmt(bw_mb)} | {fmt(lat_us)} | {fmt(lat_p99_us)} |")

    # Ключевые выводы
    randread = [p for p in parsed if p[0].startswith("randread_4k")]
    randwrite = [p for p in parsed if p[0].startswith("randwrite_4k")]
    max_r = max(randread, key=lambda p: p[1], default=None)
    max_w = max(randwrite, key=lambda p: p[1], default=None)

    lines.append("")
    lines.append("## 📌 Ключевые выводы")
    if max_r:
        lines.append(f"- Пиковый Random Read IOPS: **{fmt(max_r[1])}** ({max_r[0]})")
    if max_w:
        lines.append(f"- Пиковый Random Write IOPS: **{fmt(max_w[1])}** ({max_w[0]})")
    mixed = next((p for p in parsed if p[0].startswith("randrw")), None)
    if mixed:
        lines.append(f"- Смешанная нагрузка 70/30: **{fmt(mixed[1])} IOPS**, throughput {fmt(mixed[2])} MB/s")
    lat = next((p for p in parsed if p[0].startswith("latency")), None)
    if lat:
        lines.append(f"- Задержка при QD=1 (4k random read): ср. {fmt(lat[3])} µs, p99 {fmt(lat[4])} µs")

    lines.append("")
    lines.append("## Сравни с биллингом провайдера")
    lines.append("Сопоставь строки `randread_4k_qd*` / `randwrite_4k_qd*` / `randrw_70r30w_4k_qd32`")
    lines.append("с заявленными в тарифе цифрами IOPS для этого типа диска/объёма. Провайдеры обычно")
    lines.append("гарантируют IOPS именно на блоке 4k и при определённой глубине очереди — сверяй с той же QD.")

    with open(report_path, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"✅ Отчёт сохранён: {report_path}")
    print("\n".join(lines))

if __name__ == "__main__":
    main()
