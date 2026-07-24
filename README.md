# AMD CPU PoC — MariaDB Core-Scaling Benchmark

Interactive, customer-facing PoC runner (`amd-mariadb-poc-v1.3.sh`) that
demonstrates AMD EPYC CPU core scaling for MariaDB using the HammerDB TPC-C
OLTP workload (and optionally TPC-H analytics). It's a wrapper around the
base benchmark runner in
[skariapaul/mariadb-tpcc-bench](https://github.com/skariapaul/mariadb-tpcc-bench),
which it auto-clones and drives — this one script is all you need on the
benchmark host. The previous single-instance-only version,
`amd-mariadb-poc-v1.2.sh`, is kept for reference.

A full walkthrough (setup, CLI options, step-by-step procedure,
troubleshooting) is in
[`amd-mariadb-poc-v1.3-README.pdf`](amd-mariadb-poc-v1.3-README.pdf)
(source: [`amd-mariadb-poc-v1.3-README.md`](amd-mariadb-poc-v1.3-README.md)).
The v1.2 walkthrough, [`amd-mariadb-poc-v1.2-README.pdf`](amd-mariadb-poc-v1.2-README.pdf),
remains available unchanged for anyone still using that script.

## What it does

1. **Interactive wizard** — core counts (e.g. `8 16 24 32`), NUMA-node pinning,
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
4. **Scale-out mode (default, `--shard-cores`)** — every eligible core count
   is benchmarked twice: once as a single MariaDB instance, and once as N
   independent containers of `--shard-cores` each (e.g. 32c -> 1x32c single
   instance AND 4x8c scale-out), running concurrently with disjoint,
   NUMA-aware CPU pins and their throughput summed. Shows what horizontal
   scale-out recovers from single-instance lock/latch contention at high
   core counts. The default core-count list is every multiple of
   `--shard-cores` up to the host's actual core count (not capped) — e.g.
   `8 16 24 32 40 48 56 64` on a 64-core host, further on bigger SUTs. At
   the shard size itself only single-instance runs (1 shard == single
   instance). Disable with `--no-scale-out` for the old v1.2 behavior.
5. **Measurement extras** — CPU package power via RAPL (-> NOPM/Watt) and
   mpstat CPU-utilisation sampling per run (per mode, when scale-out is on).
6. **Consolidated report** (Markdown + PDF via pandoc) containing:
   - Executive summary with headline speedup (single-instance and, if run,
     the scale-out uplift at the largest core count)
   - Full system-under-test inventory
   - TPC-C scaling table: mode, containers, NOPM, speedup, scaling
     efficiency %, watts, NOPM/W — one row per (core count, mode)
   - ASCII throughput chart, latency percentiles, TPC-H table (if run)
   - Appendices: every generated `my.cnf` (single-instance and shard),
     `lscpu`/memory details

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

Scale-out mode needs a base runner checkout that supports `--container-name`
and `--tmp-dir` (so concurrent shard containers don't collide on Docker
container name or HammerDB's `/tmp` job files). Point `--base-dir` at such a
checkout — e.g. `mariadb/mariadb-tpcc-bench` in this repo — until the patch
is merged upstream; without it, `--no-scale-out` still works against a
vanilla clone.

## Quick start

```bash
# Interactive (recommended for the PoC — walks through every choice,
# including scale-out sizing)
bash amd-mariadb-poc-v1.3.sh --base-dir mariadb/mariadb-tpcc-bench

# Fully non-interactive example for a 64-core EPYC PoC — sweeps 8..64 in
# steps of 8, single-instance AND scale-out (8c shards) for every eligible
# core count
bash amd-mariadb-poc-v1.3.sh --yes \
  --base-dir mariadb/mariadb-tpcc-bench \
  --warehouses 640 --rampup 3 --duration 15 --buffer-pool 96G \
  --numa-node 0 --mariadb-ver 11.4 \
  --customer "Acme Corp" --report both

# Single-instance only (old v1.2 behavior), or a custom shard size
bash amd-mariadb-poc-v1.3.sh --yes --no-scale-out --cores "8 16 32 64"
bash amd-mariadb-poc-v1.3.sh --yes --shard-cores 16 --base-dir mariadb/mariadb-tpcc-bench

# Sanity check the plan first
bash amd-mariadb-poc-v1.3.sh --dry-run --yes --base-dir mariadb/mariadb-tpcc-bench
```

## Output layout

```
amd-poc-YYYYMMDD-HHMM/
  amd-mariadb-poc-report.md    - consolidated PoC report
  amd-mariadb-poc-report.pdf   - (if pandoc + LaTeX available)
  bench/                       - single-instance base runner workdir
    configs/  *.cnf per core count
    results/  raw HammerDB logs + per-run summaries
  bench-scaleout/<N>core/shard<i>/  - one isolated base-runner workdir per
                                       scale-out shard (own configs/, results/)
  metrics/<N>core/single/      - power.txt (RAPL), mpstat.log
  metrics/<N>core/scaleout/    - power.txt, mpstat.log, aggregate_summary.txt,
                                  shard<i>.log, tmp-s<i>/ (per-shard HammerDB tmp)
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
- RAPL power only sums top-level package zones (excludes Intel's per-package
  core/uncore sub-zones, which would otherwise double/triple-count the same
  energy — this was inflating Xeon readings 2-4x before it was fixed). With
  `--numa-node` set, power is further scoped to that node's physical
  package(s) only, so a NUMA-pinned run doesn't also report an idle socket's
  draw; the report states whether scoping applied.
- Durability is intentionally relaxed (`innodb_flush_log_at_trx_commit=0`,
  `innodb_doublewrite=0`) for peak throughput; the report states this so the
  customer sees the methodology honestly.
- **Scale-out rows are N independent MariaDB instances**, each with its own
  schema, buffer-pool slice, and CPU pin, benchmarked concurrently and
  summed — a proxy for a sharded/horizontally-scaled deployment, not one
  logically-consistent database. Say so explicitly if a customer asks.
  Warehouses per shard auto-size to 10x `--shard-cores` independent of the
  single-instance `--warehouses` value, unless `--warehouses` is passed
  explicitly (then applied uniformly to every shard). Buffer pool is the
  configured total divided evenly across that core count's shard count.
- Scale-out shards use ports starting at 3400 (vs 3307 for the
  single-instance runs) and container names like `mariadb-bench-32c-s0`, so
  they never collide even though they run at the same time.
- Single-instance always runs before scale-out for a given core count, and
  the smallest core count in the sweep is always single-instance only —
  this guarantees HammerDB is downloaded/cached before any concurrent
  scale-out shards launch, avoiding a race on the shared `~/HammerDB`
  install on a brand-new host.
