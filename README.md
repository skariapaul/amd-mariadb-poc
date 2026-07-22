# AMD CPU PoC — MariaDB Core-Scaling Benchmark

Interactive, customer-facing PoC runner (`amd-mariadb-poc-v1.2.sh`) that
demonstrates AMD EPYC CPU core scaling for MariaDB using the HammerDB TPC-C
OLTP workload (and optionally TPC-H analytics). It's a wrapper around the
base benchmark runner in
[skariapaul/mariadb-tpcc-bench](https://github.com/skariapaul/mariadb-tpcc-bench),
which it auto-clones and drives — this one script is all you need on the
benchmark host.

A full walkthrough (setup, CLI options, step-by-step procedure,
troubleshooting) is in [`amd-mariadb-poc-v1.2-README.pdf`](amd-mariadb-poc-v1.2-README.pdf).

## What it does

1. **Interactive wizard** — core counts (e.g. `8 16 32 64`), NUMA-node pinning,
   warehouse sizing (with guidance to avoid contention plateaus), run length,
   buffer pool, MariaDB version, report format.
2. **Host tuning for best performance** (optional, needs sudo, auto-reverted):
   - CPU frequency governor -> `performance`
   - `vm.swappiness=1`
   - Transparent hugepages -> `never`, explicit 2 MiB hugepages sized to the
     InnoDB buffer pool (the base runner then enables `large_pages=ON`)
3. **Per-core-count runs** — fresh MariaDB container per config with an
   InnoDB config tuned per the AMD EPYC RDBMS Tuning Guide, NUMA-local cpuset,
   HammerDB schema build + timed run.
4. **Measurement extras** — CPU package power via RAPL (-> NOPM/Watt) and
   mpstat CPU-utilisation sampling per run.
5. **Consolidated report** (Markdown + PDF via pandoc) containing:
   - Executive summary with headline speedup
   - Full system-under-test inventory
   - TPC-C scaling table: NOPM, speedup, scaling efficiency %, watts, NOPM/W
   - ASCII throughput chart, latency percentiles, TPC-H table (if run)
   - Appendices: every generated `my.cnf`, `lscpu`/memory details

## Prerequisites (on the benchmark host)

```bash
# Ubuntu/Debian
sudo apt-get install -y docker-ce docker-compose-plugin git libmariadb3 sysstat numactl
# for PDF output:
sudo apt-get install -y pandoc texlive-latex-recommended texlive-fonts-recommended

# RHEL/Rocky
sudo yum install -y docker-ce docker-compose-plugin git mariadb-connector-c sysstat numactl pandoc
```

Docker daemon running; ~20 GB free disk; run as a user in the `docker` group.

## Quick start

```bash
# Interactive (recommended for the PoC — walks through every choice)
bash amd-mariadb-poc-v1.2.sh

# Fully non-interactive example for a 64-core EPYC PoC
bash amd-mariadb-poc-v1.2.sh --yes \
  --cores "8 16 32 64" --warehouses 640 \
  --rampup 3 --duration 15 --buffer-pool 96G \
  --numa-node 0 --mariadb-ver 11.4 \
  --customer "Acme Corp" --report both

# Sanity check the plan first
bash amd-mariadb-poc-v1.2.sh --dry-run --yes
```

## Output layout

```
amd-poc-YYYYMMDD-HHMM/
  amd-mariadb-poc-report.md    - consolidated PoC report
  amd-mariadb-poc-report.pdf   - (if pandoc + LaTeX available)
  bench/                       - base runner workdir
    configs/  *.cnf per core count
    results/  raw HammerDB logs + per-run summaries
  metrics/<N>core/             - power.txt (RAPL), mpstat.log
  sysinfo/                     - lscpu, numactl, free, os-release, ...
```

## PoC tips

- **Warehouses >= 10x the largest core count** (the wizard defaults to this).
  With too few warehouses, hot-row contention flattens the curve and undersells
  the CPU. Budget for the schema build: roughly 15 s per warehouse per config.
- **Pin to one NUMA node** when your largest core count fits in a node —
  it removes cross-socket memory latency from the comparison. Use
  `--numa-node`, and check topology first with `numactl --hardware`.
- On EPYC, node cpulists enumerate physical cores before SMT siblings, so
  NUMA-derived cpusets naturally land on physical cores first.
- For headline numbers use `--duration 15` or more; 5-minute runs are fine
  for dry-fitting the setup.
- RAPL power needs readable `/sys/class/powercap/*rapl*` counters — run as
  root (or `sudo`) if NOPM/Watt shows as `-` in the report.
- Durability is intentionally relaxed (`innodb_flush_log_at_trx_commit=0`,
  `innodb_doublewrite=0`) for peak throughput; the report states this so the
  customer sees the methodology honestly.
