#!/usr/bin/env bash
# =============================================================================
#  AMD CPU PoC — MariaDB TPC-C / TPC-H Core-Scaling Benchmark
# =============================================================================
#  Customer-facing Proof-of-Concept runner that demonstrates AMD EPYC CPU
#  scaling for MariaDB OLTP (TPC-C) and optionally analytics (TPC-H).
#
#  Built on top of:  https://github.com/skariapaul/mariadb-tpcc-bench
#  (HammerDB + Docker interactive benchmark runner)
#
#  What this wrapper adds on top of the base runner:
#    * Interactive PoC wizard (core counts, NUMA pinning, run sizing, report)
#    * AMD-aware host tuning: CPU governor -> performance, swappiness,
#      transparent hugepages OFF + explicit hugepages sized to buffer pool
#      (all reverted automatically on exit)
#    * Full system inventory capture (CPU/NUMA/memory/kernel/BIOS) for report
#    * Per-run CPU utilisation sampling (mpstat) and package power via RAPL
#      -> NOPM/Watt "performance-per-watt" numbers for the PoC story
#    * Scaling-efficiency analysis (speedup vs baseline, % efficiency)
#    * Scale-out mode: every eligible core count is benchmarked BOTH as a
#      single MariaDB instance AND as N independent containers of
#      --shard-cores each (e.g. 32c -> 1x32c single instance AND 4x8c
#      scale-out), aggregating throughput across the shards. This shows
#      the throughput ceiling of a single instance alongside what
#      horizontal scale-out recovers from it. Enabled by default; disable
#      with --no-scale-out to reproduce single-instance-only behavior.
#    * Consolidated Markdown report + optional PDF (via pandoc)
#
#  Usage:
#     bash amd-mariadb-poc-v1.3.sh              # interactive wizard
#     bash amd-mariadb-poc-v1.3.sh --yes        # accept all defaults
#
#  Options (all optional — the wizard asks for anything not given):
#     --cores "8 16 32"       Core counts to test (default: multiples of
#                              --shard-cores up to the host's core count)
#     --shard-cores N         Cores per scale-out container (default 8) —
#                              also sets the step of the default core list
#     --no-scale-out           Single-instance only (skip scale-out rows)
#     --warehouses N          TPC-C warehouses for the single-instance runs
#                              (recommend >= 10x max cores). Scale-out
#                              containers auto-size to 10x their own
#                              --shard-cores unless --warehouses is given
#                              explicitly, in which case it applies to
#                              every shard unchanged.
#     --rampup N              Ramp-up minutes            (default 2)
#     --duration N            Timed-run minutes          (default 10)
#     --tpch                  Also run TPC-H analytics
#     --tpch-sf N             TPC-H scale factor         (default 1)
#     --buffer-pool SIZE      InnoDB buffer pool, e.g. 64G (default 75% RAM)
#                              Scale-out containers split this evenly.
#     --mariadb-ver VER       MariaDB image tag          (default 11.4)
#     --numa-node N           Pin runs to NUMA node N (auto cpuset per count)
#     --no-host-tuning        Skip governor/hugepage/swappiness tuning
#     --report md|pdf|both    Report format              (default both)
#     --customer "Name"       Customer name printed on the report cover
#     --title "Text"          Report title override
#     --workdir PATH          Output dir (default ./amd-poc-YYYYMMDD-HHMM)
#     --base-dir PATH         Path to a mariadb-tpcc-bench checkout
#                             (default: auto-clone next to workdir; scale-out
#                             mode needs a checkout with --container-name /
#                             --tmp-dir support)
#     --dry-run               Show the plan, run nothing
#     --yes                   Non-interactive, accept defaults/flags
#     -h | --help             This help
# =============================================================================
set -euo pipefail

BASE_REPO_URL="https://github.com/skariapaul/mariadb-tpcc-bench.git"

# ── Colours ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'
  BLD='\033[1m'; RST='\033[0m'
else
  RED=''; YEL=''; GRN=''; CYN=''; BLD=''; RST=''
fi
log()  { echo -e "${CYN}[$(date '+%H:%M:%S')]${RST} $*"; }
ok()   { echo -e "${GRN}[$(date '+%H:%M:%S')] \xe2\x9c\x94 $*${RST}"; }
warn() { echo -e "${YEL}[$(date '+%H:%M:%S')] \xe2\x9a\xa0 $*${RST}"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] \xe2\x9c\x96 $*${RST}" >&2; exit 1; }
hr()   { echo -e "${BLD}\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81\xe2\x94\x81${RST}"; }
section() { hr; echo -e "${BLD}  $*${RST}"; hr; }

# ── Defaults ─────────────────────────────────────────────────────────────────
CORES_LIST=""
WAREHOUSES=""
WAREHOUSES_EXPLICIT=false
RAMPUP=2
DURATION=10
RUN_TPCH=false
TPCH_SF=1
BUFFER_POOL=""
MARIADB_VER="11.4"
NUMA_NODE=""
HOST_TUNING=true
REPORT_FMT="both"
CUSTOMER=""
TITLE=""
WORKDIR=""
BASE_DIR=""
DRY_RUN=false
YES=false
SHARD_CORES=8
SCALE_OUT=true
SHARD_PORT_BASE=3400

# ── Args ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --cores)          CORES_LIST="$2"; shift 2 ;;
    --warehouses)     WAREHOUSES="$2"; WAREHOUSES_EXPLICIT=true; shift 2 ;;
    --rampup)         RAMPUP="$2"; shift 2 ;;
    --duration)       DURATION="$2"; shift 2 ;;
    --tpch)           RUN_TPCH=true; shift ;;
    --tpch-sf)        TPCH_SF="$2"; RUN_TPCH=true; shift 2 ;;
    --buffer-pool)    BUFFER_POOL="$2"; shift 2 ;;
    --mariadb-ver)    MARIADB_VER="$2"; shift 2 ;;
    --numa-node)      NUMA_NODE="$2"; shift 2 ;;
    --no-host-tuning) HOST_TUNING=false; shift ;;
    --shard-cores)    SHARD_CORES="$2"; shift 2 ;;
    --no-scale-out)   SCALE_OUT=false; shift ;;
    --report)         REPORT_FMT="$2"; shift 2 ;;
    --customer)       CUSTOMER="$2"; shift 2 ;;
    --title)          TITLE="$2"; shift 2 ;;
    --workdir)        WORKDIR="$2"; shift 2 ;;
    --base-dir)       BASE_DIR="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --yes|-y)         YES=true; shift ;;
    -h|--help)
      sed -n '/^#  Usage:/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \{0,2\}//'
      exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

case "$REPORT_FMT" in md|pdf|both) : ;; *) die "--report must be md, pdf or both" ;; esac
[[ "$SHARD_CORES" =~ ^[0-9]+$ && "$SHARD_CORES" -ge 1 ]] || die "--shard-cores must be a positive integer"

# ── Prompt helper ────────────────────────────────────────────────────────────
# prompt VAR "Question" "default"
prompt() {
  local var="$1" q="$2" def="$3" reply
  if $YES; then eval "$var=\"\$def\""; return; fi
  printf "${BLD}%s${RST} [${GRN}%s${RST}]: " "$q" "$def"
  read -r reply
  eval "$var=\"\${reply:-\$def}\""
}
# confirm "Question" default_yes|default_no  -> returns 0 for yes
confirm() {
  local q="$1" def="${2:-default_yes}" hint reply
  if $YES; then [[ "$def" == default_yes ]]; return; fi
  [[ "$def" == default_yes ]] && hint="Y/n" || hint="y/N"
  printf "${BLD}%s${RST} [${GRN}%s${RST}]: " "$q" "$hint"
  read -r reply
  reply="${reply,,}"
  if [[ -z "$reply" ]]; then [[ "$def" == default_yes ]]; return; fi
  [[ "$reply" == y || "$reply" == yes ]]
}

# ── System detection ─────────────────────────────────────────────────────────
detect_system() {
  HOST_CORES=$(nproc)
  HOST_RAM_GiB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
  CPU_MODEL=$(lscpu 2>/dev/null | awk -F': +' '/Model name/{print $2; exit}')
  CPU_VENDOR=$(lscpu 2>/dev/null | awk -F': +' '/Vendor ID/{print $2; exit}')
  SOCKETS=$(lscpu 2>/dev/null | awk -F': +' '/^Socket\(s\)/{print $2; exit}')
  CORES_PER_SOCKET=$(lscpu 2>/dev/null | awk -F': +' '/^Core\(s\) per socket/{print $2; exit}')
  THREADS_PER_CORE=$(lscpu 2>/dev/null | awk -F': +' '/^Thread\(s\) per core/{print $2; exit}')
  NUMA_NODES=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
  (( NUMA_NODES >= 1 )) || NUMA_NODES=1
  SMT_ACTIVE=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo "?")
}

# ── Dependency checks ────────────────────────────────────────────────────────
# Installs pandoc + a LaTeX engine (needed for --report pdf/both). Returns
# non-zero if no supported package manager is found or sudo isn't available;
# callers fall back to Markdown-only in that case.
install_pandoc() {
  need_sudo || { warn "No root/sudo available — cannot auto-install pandoc/LaTeX."; return 1; }
  if command -v apt-get &>/dev/null; then
    log "Installing pandoc + texlive via apt-get (this can take a few minutes) ..."
    $SUDO apt-get update -qq \
      && $SUDO apt-get install -y pandoc texlive-latex-recommended texlive-fonts-recommended
  elif command -v dnf &>/dev/null; then
    log "Installing pandoc + texlive via dnf (this can take a few minutes) ..."
    $SUDO dnf install -y pandoc texlive-scheme-basic texlive-collection-fontsrecommended
  elif command -v yum &>/dev/null; then
    log "Installing pandoc + texlive via yum (this can take a few minutes) ..."
    $SUDO yum install -y pandoc texlive texlive-collection-fontsrecommended
  else
    warn "No supported package manager found (apt-get/dnf/yum) — install pandoc + a LaTeX engine manually."
    return 1
  fi
}

check_deps() {
  section "Pre-flight Checklist"

  if command -v docker &>/dev/null; then ok "Docker installed"
  else die "Docker not found — install Docker first."; fi

  if docker info &>/dev/null; then ok "Docker daemon reachable"
  else die "Docker daemon not reachable (try: sudo systemctl start docker, or add yourself to the docker group)."; fi

  if command -v git &>/dev/null; then ok "git installed"
  else die "git not found — needed to fetch the base benchmark runner."; fi

  if ldconfig -p 2>/dev/null | grep -q libmariadb.so.3; then ok "libmariadb.so.3 found"
  else
    die "libmariadb.so.3 missing (HammerDB needs it on the host).
  Ubuntu/Debian : sudo apt-get install -y libmariadb3
  RHEL/Rocky    : sudo yum install -y mariadb-connector-c"
  fi

  HAVE_MPSTAT=false;  command -v mpstat  &>/dev/null && HAVE_MPSTAT=true
  if $HAVE_MPSTAT; then ok "mpstat installed (CPU utilisation sampling enabled)"
  else warn "mpstat not found (sysstat pkg) — CPU utilisation sampling disabled."; fi

  HAVE_NUMACTL=false; command -v numactl &>/dev/null && HAVE_NUMACTL=true
  if $HAVE_NUMACTL; then ok "numactl installed"
  else warn "numactl not found — NUMA topology details/pinning helpers limited."; fi

  HAVE_PANDOC=false;  command -v pandoc  &>/dev/null && HAVE_PANDOC=true
  if $HAVE_PANDOC; then
    ok "pandoc installed (PDF report generation enabled)"
  elif [[ "$REPORT_FMT" == "md" ]]; then
    warn "pandoc not found (fine — only needed for PDF reports, and --report md was requested)."
  else
    warn "pandoc not found — needed for PDF report generation."
    if confirm "Install pandoc + LaTeX now (needs sudo, ~300-500MB download)?" default_yes; then
      if install_pandoc && command -v pandoc &>/dev/null; then
        HAVE_PANDOC=true
        ok "pandoc installed."
      else
        warn "pandoc install failed or unavailable — PDF generation will be skipped (Markdown only)."
        warn "  Install manually: sudo apt-get install -y pandoc texlive-latex-recommended texlive-fonts-recommended"
      fi
    else
      warn "Skipping pandoc install — PDF generation will be skipped (Markdown only)."
    fi
  fi
}

fetch_base_repo() {
  if [[ -n "$BASE_DIR" ]]; then
    [[ -f "$BASE_DIR/mariadb-tpcc-bench.sh" ]] || die "mariadb-tpcc-bench.sh not found in --base-dir $BASE_DIR"
    ok "Using base runner at $BASE_DIR"
    return
  fi
  for cand in "./mariadb-tpcc-bench" "$HOME/mariadb-tpcc-bench"; do
    if [[ -f "$cand/mariadb-tpcc-bench.sh" ]]; then
      BASE_DIR="$(cd "$cand" && pwd)"
      ok "Found base runner at $BASE_DIR"
      return
    fi
  done
  BASE_DIR="$WORKDIR/mariadb-tpcc-bench"
  log "Cloning base runner into $BASE_DIR ..."
  $DRY_RUN && { log "[dry-run] git clone $BASE_REPO_URL"; return; }
  git clone --depth 1 "$BASE_REPO_URL" "$BASE_DIR"
  ok "Base runner ready."
}

check_scaleout_support() {
  $SCALE_OUT || return 0
  $DRY_RUN && [[ ! -f "$BASE_DIR/mariadb-tpcc-bench.sh" ]] && return 0
  if ! grep -q -- '--container-name' "$BASE_DIR/mariadb-tpcc-bench.sh" 2>/dev/null; then
    die "Scale-out mode needs a base runner with --container-name/--tmp-dir support (not found in $BASE_DIR/mariadb-tpcc-bench.sh). Point --base-dir at a patched checkout, or pass --no-scale-out."
  fi
}

# ── System inventory capture ─────────────────────────────────────────────────
collect_sysinfo() {
  local dir="$WORKDIR/sysinfo"
  mkdir -p "$dir"
  lscpu                    > "$dir/lscpu.txt"          2>/dev/null || true
  free -h                  > "$dir/free.txt"           2>/dev/null || true
  uname -a                 > "$dir/uname.txt"          2>/dev/null || true
  cat /etc/os-release      > "$dir/os-release.txt"     2>/dev/null || true
  docker --version         > "$dir/docker.txt"         2>/dev/null || true
  lsblk -o NAME,SIZE,TYPE,ROTA,MODEL,MOUNTPOINT > "$dir/lsblk.txt" 2>/dev/null || true
  cat /sys/kernel/mm/transparent_hugepage/enabled > "$dir/thp.txt" 2>/dev/null || true
  cat /proc/sys/vm/nr_hugepages  > "$dir/nr_hugepages.txt" 2>/dev/null || true
  cat /proc/sys/vm/swappiness    > "$dir/swappiness.txt"   2>/dev/null || true
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > "$dir/governor.txt" 2>/dev/null || true
  if $HAVE_NUMACTL; then numactl --hardware > "$dir/numactl.txt" 2>/dev/null || true; fi
  # BIOS / platform (best effort, needs root)
  if command -v dmidecode &>/dev/null && [[ $EUID -eq 0 || -n "${SUDO_OK:-}" ]]; then
    ${SUDO} dmidecode -t system -t bios -t processor > "$dir/dmidecode.txt" 2>/dev/null || true
  fi
}

# ── Host tuning (applied with sudo, reverted on exit) ────────────────────────
SUDO=""
ORIG_GOVERNOR=""
ORIG_SWAPPINESS=""
ORIG_THP=""
ORIG_HUGEPAGES=""
TUNING_APPLIED=false
HP_FOR_BP=0

need_sudo() {
  if [[ $EUID -eq 0 ]]; then SUDO=""; SUDO_OK=1; return 0; fi
  if sudo -n true 2>/dev/null || sudo -v; then SUDO="sudo"; SUDO_OK=1; return 0; fi
  return 1
}

bp_to_mib() {  # "64G" / "8192M" -> MiB
  local v="${1^^}"
  case "$v" in
    *G) echo $(( ${v%G} * 1024 )) ;;
    *M) echo    "${v%M}" ;;
    *)  echo $(( v / 1024 / 1024 )) ;;
  esac
}

mib_to_size() {  # MiB -> compact size string, e.g. 8192 -> "8G", 6000 -> "6000M"
  local mib=$1
  if (( mib >= 1024 && mib % 1024 == 0 )); then
    echo "$(( mib / 1024 ))G"
  else
    echo "${mib}M"
  fi
}

apply_host_tuning() {
  section "Applying host tuning (reverted automatically on exit)"
  $DRY_RUN && { log "[dry-run] would set governor=performance, swappiness=1, THP=never, hugepages"; return; }
  need_sudo || { warn "No root/sudo available — skipping host tuning."; HOST_TUNING=false; return; }

  # 1. CPU frequency governor -> performance
  local govfile=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
  if [[ -f $govfile ]]; then
    ORIG_GOVERNOR=$(cat "$govfile")
    if [[ "$ORIG_GOVERNOR" != "performance" ]]; then
      echo performance | $SUDO tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 \
        && ok "CPU governor: $ORIG_GOVERNOR -> performance" \
        || warn "Could not change CPU governor (platform may control it in firmware)."
    else
      ok "CPU governor already 'performance'."
      ORIG_GOVERNOR=""
    fi
  else
    warn "No cpufreq interface exposed — governor unchanged (often fine on EPYC with amd_pstate/BIOS control)."
  fi

  # 2. vm.swappiness -> 1
  ORIG_SWAPPINESS=$(cat /proc/sys/vm/swappiness)
  if [[ "$ORIG_SWAPPINESS" != "1" ]]; then
    $SUDO sysctl -q vm.swappiness=1 && ok "vm.swappiness: $ORIG_SWAPPINESS -> 1"
  else ORIG_SWAPPINESS=""; fi

  # 3. Transparent hugepages -> never (databases prefer explicit hugepages)
  local thpfile=/sys/kernel/mm/transparent_hugepage/enabled
  if [[ -f $thpfile ]]; then
    ORIG_THP=$(grep -oP '\[\K[^\]]+' "$thpfile")
    if [[ "$ORIG_THP" != "never" ]]; then
      echo never | $SUDO tee "$thpfile" >/dev/null && ok "Transparent hugepages: $ORIG_THP -> never"
    else ORIG_THP=""; fi
  fi

  # 4. Explicit hugepages sized to buffer pool + 6% headroom (2 MiB pages).
  #    The base runner enables MariaDB large_pages automatically when
  #    vm.nr_hugepages > 0 and mounts /dev/hugepages into the container.
  #    Sized off the TOTAL buffer pool, which correctly covers scale-out
  #    mode too since shard buffer pools are a split of this same total and
  #    all shards for a core count run concurrently.
  ORIG_HUGEPAGES=$(cat /proc/sys/vm/nr_hugepages)
  local bp_mib; bp_mib=$(bp_to_mib "$BUFFER_POOL")
  HP_FOR_BP=$(( bp_mib * 106 / 100 / 2 ))
  if (( ORIG_HUGEPAGES < HP_FOR_BP )); then
    $SUDO sysctl -q vm.nr_hugepages="$HP_FOR_BP" || true
    local got; got=$(cat /proc/sys/vm/nr_hugepages)
    if (( got >= HP_FOR_BP )); then
      ok "Hugepages: $ORIG_HUGEPAGES -> $got x 2MiB (covers ${BUFFER_POOL} buffer pool)"
    else
      warn "Requested $HP_FOR_BP hugepages, kernel granted $got (memory fragmentation)."
      warn "Buffer pool will fall back to normal pages if insufficient — still a valid run."
    fi
  else
    ok "Hugepages already sufficient ($ORIG_HUGEPAGES x 2MiB)."
    ORIG_HUGEPAGES=""
  fi
  TUNING_APPLIED=true
}

revert_host_tuning() {
  $TUNING_APPLIED || return 0
  log "Reverting host tuning ..."
  [[ -n "$ORIG_GOVERNOR"  ]] && echo "$ORIG_GOVERNOR" | $SUDO tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
  [[ -n "$ORIG_SWAPPINESS" ]] && $SUDO sysctl -q vm.swappiness="$ORIG_SWAPPINESS" 2>/dev/null || true
  [[ -n "$ORIG_THP"        ]] && echo "$ORIG_THP" | $SUDO tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
  [[ -n "$ORIG_HUGEPAGES"  ]] && $SUDO sysctl -q vm.nr_hugepages="$ORIG_HUGEPAGES" 2>/dev/null || true
  TUNING_APPLIED=false
  ok "Host tuning reverted."
}

# ── RAPL package power (works on AMD EPYC via the intel-rapl powercap driver) ─
# Only top-level package zones (e.g. "intel-rapl:0") are summed. A glob
# ending in ":[0-9]" also matches Intel's per-package sub-zones -- core
# ("intel-rapl:0:0"), uncore ("intel-rapl:0:1"), etc, since their names end
# in ":<digit>" too -- which are subsets of the package total, not separate
# power draw. Summing those alongside the package total double/triple-counts
# the same energy and inflates readings 2-4x. Intel exposes these sub-zones;
# AMD's RAPL/energy powercap driver generally doesn't, which is why this only
# showed up on Xeon hosts.
#
# When the run is pinned to one NUMA node (--numa-node), RAPL_NODE_PKGS
# (resolved once by resolve_rapl_scope, below) restricts summing to that
# node's physical package(s) -- otherwise a NUMA-pinned run still reports
# combined power for every socket on the host, including idle ones. In
# scale-out mode, all shards for a NUMA-pinned core count are already
# confined to that same node's cpulist (see shard_cpusets), so this scoping
# correctly covers the whole concurrent shard batch too.
RAPL_NODE_PKGS=""   # space-separated physical_package_id list; empty = all packages

# Resolves RAPL_NODE_PKGS from NUMA_NODE's cpulist -> each CPU's
# physical_package_id (assumes RAPL zone index == physical_package_id,
# true for the mainline intel_rapl_msr/amd_energy drivers). Leaves
# RAPL_NODE_PKGS empty -- summing every package, as before -- if NUMA_NODE
# isn't set or the topology sysfs needed to resolve it isn't readable.
resolve_rapl_scope() {
  RAPL_NODE_PKGS=""
  [[ -z "$NUMA_NODE" ]] && return
  local cpulist; cpulist=$(cat "/sys/devices/system/node/node${NUMA_NODE}/cpulist" 2>/dev/null) || return
  [[ -z "$cpulist" ]] && return
  local -a cpus=()
  local part start end i
  IFS=',' read -ra parts <<< "$cpulist"
  for part in "${parts[@]}"; do
    part="${part// /}"
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
      for (( i=start; i<=end; i++ )); do cpus+=("$i"); done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      cpus+=("$part")
    fi
  done
  local cpu pkg seen=""
  for cpu in "${cpus[@]}"; do
    pkg=$(cat "/sys/devices/system/cpu/cpu${cpu}/topology/physical_package_id" 2>/dev/null) || continue
    [[ -z "$pkg" ]] && continue
    [[ " $seen " == *" $pkg "* ]] || seen+=" $pkg"
  done
  RAPL_NODE_PKGS="${seen# }"
}

rapl_energy_uj() {   # prints summed package energy_uj, or empty if unavailable
  local total=0 found=false f base zone
  for f in /sys/class/powercap/*rapl*/energy_uj; do
    [[ -r "$f" ]] || continue
    base=$(basename "$(dirname "$f")")
    [[ "$base" =~ ^[^:]+:([0-9]+)$ ]] || continue
    zone="${BASH_REMATCH[1]}"
    [[ -n "$RAPL_NODE_PKGS" && " $RAPL_NODE_PKGS " != *" $zone "* ]] && continue
    total=$(( total + $(cat "$f") )); found=true
  done
  $found && echo "$total"
}
rapl_max_uj() {
  local total=0 found=false f base zone
  for f in /sys/class/powercap/*rapl*/max_energy_range_uj; do
    [[ -r "$f" ]] || continue
    base=$(basename "$(dirname "$f")")
    [[ "$base" =~ ^[^:]+:([0-9]+)$ ]] || continue
    zone="${BASH_REMATCH[1]}"
    [[ -n "$RAPL_NODE_PKGS" && " $RAPL_NODE_PKGS " != *" $zone "* ]] && continue
    total=$(( total + $(cat "$f") )); found=true
  done
  $found && echo "$total"
}

# energy_uj counters are 32-bit and wrap in well under a minute under real
# load — a single before/after snapshot over a multi-minute run silently
# undercounts (worse the more power is drawn, since higher draw wraps
# faster), which is why higher-core-count runs previously showed lower
# average power than lower-core-count ones. Sample every few seconds
# instead and wrap-correct each short interval individually — the counter
# can't wrap more than once within a couple of seconds even under full
# load, so this is safe regardless of total run length.
# Runs until killed (SIGTERM/SIGINT). Writes the running total to
# $1/rapl_accum.txt after every tick so a kill never loses more than one
# interval's worth of data.
rapl_sample_loop() {
  local mdir=$1 rapl_max=$2 interval=${3:-2}
  local prev cur de total_uj=0 total_s=0
  prev=$(rapl_energy_uj || true)
  while true; do
    sleep "$interval"
    cur=$(rapl_energy_uj || true)
    if [[ -n "$cur" && -n "$prev" ]]; then
      de=$(( cur - prev ))
      (( de < 0 )) && de=$(( de + rapl_max ))
      total_uj=$(( total_uj + de ))
      total_s=$(( total_s + interval ))
      printf 'total_uj=%s\ntotal_s=%s\n' "$total_uj" "$total_s" > "$mdir/rapl_accum.txt"
    fi
    prev=$cur
  done
}

# ── CPU list helpers (scale-out shard pinning) ───────────────────────────────
# Expand "0-3,8-11" into CPULIST_EXPANDED=(0 1 2 3 8 9 10 11)
CPULIST_EXPANDED=()
expand_cpulist() {
  local list=$1 part start end i
  CPULIST_EXPANDED=()
  IFS=',' read -ra _parts <<< "$list"
  for part in "${_parts[@]}"; do
    part="${part// /}"
    [[ -z "$part" ]] && continue
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
      for (( i=start; i<=end; i++ )); do CPULIST_EXPANDED+=("$i"); done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      CPULIST_EXPANDED+=("$part")
    fi
  done
}

# Compacts CPU ids (args) into a range string, e.g. "0-3,8-11"
compact_cpulist() {
  local result="" range_start prev=-1 cpu
  for cpu in "$@"; do
    if [[ $prev -eq -1 ]]; then range_start=$cpu; prev=$cpu
    elif [[ $cpu -eq $(( prev + 1 )) ]]; then prev=$cpu
    else
      [[ -n "$result" ]] && result+=","
      [[ $range_start -eq $prev ]] && result+="$range_start" || result+="${range_start}-${prev}"
      range_start=$cpu; prev=$cpu
    fi
  done
  if [[ $prev -ne -1 ]]; then
    [[ -n "$result" ]] && result+=","
    [[ $range_start -eq $prev ]] && result+="$range_start" || result+="${range_start}-${prev}"
  fi
  echo "$result"
}

# NUMA-grouped pool of usable CPU ids -> CPU_POOL. Consecutive shards stay
# within one node when node sizes line up with --shard-cores.
CPU_POOL=()
build_cpu_pool() {
  CPU_POOL=()
  if [[ -n "$NUMA_NODE" ]]; then
    local cl; cl=$(cat "/sys/devices/system/node/node${NUMA_NODE}/cpulist" 2>/dev/null || echo "")
    if [[ -n "$cl" ]]; then expand_cpulist "$cl"; CPU_POOL=( "${CPULIST_EXPANDED[@]}" ); fi
  elif (( NUMA_NODES > 1 )); then
    local n cl
    for (( n=0; n<NUMA_NODES; n++ )); do
      cl=$(cat "/sys/devices/system/node/node${n}/cpulist" 2>/dev/null || echo "")
      if [[ -n "$cl" ]]; then
        expand_cpulist "$cl"
        CPU_POOL+=( "${CPULIST_EXPANDED[@]}" )
      fi
    done
  fi
  if (( ${#CPU_POOL[@]} == 0 )); then
    local c; for (( c=0; c<HOST_CORES; c++ )); do CPU_POOL+=("$c"); done
  fi
}

# shard_cpusets TOTAL_CORES SHARD_CORES -> fills SHARD_CPUSETS with
# (TOTAL_CORES/SHARD_CORES) disjoint cpuset range strings.
SHARD_CPUSETS=()
shard_cpusets() {
  local total_cores=$1 shard_cores=$2
  build_cpu_pool
  (( ${#CPU_POOL[@]} < total_cores )) \
    && die "Not enough CPUs available (${#CPU_POOL[@]}) to pin ${total_cores} scale-out cores."
  local num_shards=$(( total_cores / shard_cores )) i
  SHARD_CPUSETS=()
  for (( i=0; i<num_shards; i++ )); do
    local -a chunk=( "${CPU_POOL[@]:$(( i * shard_cores )):shard_cores}" )
    SHARD_CPUSETS+=( "$(compact_cpulist "${chunk[@]}")" )
  done
}

# ── mpstat/RAPL sampling helpers (wrap a measured phase) ─────────────────────
# start_sampling MDIR RAPL_MAX -> echoes "mpid rpid" (either may be blank)
start_sampling() {
  local mdir=$1 rapl_max=$2
  mkdir -p "$mdir"
  local mpid="" rpid=""
  if $HAVE_MPSTAT && ! $DRY_RUN; then
    mpstat 10 > "$mdir/mpstat.log" 2>/dev/null & mpid=$!
  fi
  rm -f "$mdir/rapl_accum.txt"
  if [[ -n "${rapl_max:-}" ]] && ! $DRY_RUN; then
    rapl_sample_loop "$mdir" "$rapl_max" 2 & rpid=$!
  fi
  echo "${mpid:-_} ${rpid:-_}"
}

# stop_sampling MDIR MPID RPID T0 T1 -> writes power.txt if RAPL data present
stop_sampling() {
  local mdir=$1 mpid=$2 rpid=$3 t0=$4 t1=$5
  [[ "$mpid" != "_" ]] && { kill "$mpid" 2>/dev/null || true; wait "$mpid" 2>/dev/null || true; }
  [[ "$rpid" != "_" ]] && { kill "$rpid" 2>/dev/null || true; wait "$rpid" 2>/dev/null || true; }
  if [[ -f "$mdir/rapl_accum.txt" ]]; then
    local total_uj total_s
    total_uj=$(grep -oP '(?<=total_uj=)\d+' "$mdir/rapl_accum.txt")
    total_s=$(grep -oP '(?<=total_s=)\d+' "$mdir/rapl_accum.txt")
    if [[ -n "$total_uj" && -n "$total_s" ]] && (( total_s > 0 )); then
      awk -v de="$total_uj" -v s="$total_s" 'BEGIN{printf "avg_pkg_watts=%.1f\n", de/1e6/s}' > "$mdir/power.txt"
      echo "elapsed_s=$(( t1 - t0 ))" >> "$mdir/power.txt"
      ok "Avg package power: $(grep -oP '(?<=avg_pkg_watts=).*' "$mdir/power.txt") W"
    fi
    rm -f "$mdir/rapl_accum.txt"
  fi
}

# ── Interactive wizard ───────────────────────────────────────────────────────
wizard() {
  section "AMD MariaDB PoC — Configuration"
  echo -e "  CPU        : ${BLD}${CPU_MODEL:-unknown}${RST}"
  echo -e "  Topology   : ${SOCKETS:-?} socket(s) x ${CORES_PER_SOCKET:-?} cores, SMT $( [[ "$SMT_ACTIVE" == 1 ]] && echo on || echo off ), ${NUMA_NODES} NUMA node(s)"
  echo -e "  Logical CPUs: ${HOST_CORES}   RAM: ${HOST_RAM_GiB} GiB"
  if [[ "${CPU_VENDOR:-}" != *AMD* ]]; then
    warn "Vendor is '${CPU_VENDOR:-unknown}' — this PoC is tuned for AMD EPYC but will run anywhere."
  fi
  echo ""

  # Scale-out shard size — also drives the default core-count list below
  if ! $YES; then
    prompt SHARD_CORES "Cores per scale-out container (also sets the default core-list step)" "$SHARD_CORES"
    [[ "$SHARD_CORES" =~ ^[0-9]+$ && "$SHARD_CORES" -ge 1 ]] || die "Invalid shard size: '$SHARD_CORES'"
  fi

  # Core counts — default list is every multiple of SHARD_CORES up to the
  # host's actual core count (not capped), so bigger SUTs sweep further.
  local def_cores="" n
  for (( n=SHARD_CORES; n<=HOST_CORES; n+=SHARD_CORES )); do def_cores+="$n "; done
  def_cores="${def_cores% }"
  [[ -z "$def_cores" ]] && def_cores="$HOST_CORES"
  if [[ -z "$CORES_LIST" ]]; then
    prompt CORES_LIST "Core counts to benchmark (space-separated)" "$def_cores"
  fi
  local maxc=0 c
  for c in $CORES_LIST; do
    [[ "$c" =~ ^[0-9]+$ ]] || die "Invalid core count: '$c'"
    (( c > HOST_CORES )) && die "Core count $c exceeds host logical CPUs ($HOST_CORES)."
    (( c > maxc )) && maxc=$c
  done

  # NUMA pinning
  if [[ -z "$NUMA_NODE" && "$NUMA_NODES" -gt 1 ]]; then
    echo ""
    log "This host has ${NUMA_NODES} NUMA nodes. Pinning each run to one node keeps"
    log "memory local and makes per-core scaling honest (recommended for a PoC"
    log "when the largest core count fits in a single node)."
    if $HAVE_NUMACTL; then numactl --hardware | sed 's/^/    /' | head -20; fi
    local node0_cpus
    node0_cpus=$(cat /sys/devices/system/node/node0/cpulist 2>/dev/null || echo "?")
    echo -e "    node0 cpulist: ${node0_cpus}"
    prompt NUMA_NODE "Pin benchmark to NUMA node (number, or 'none')" "0"
    [[ "$NUMA_NODE" == "none" ]] && NUMA_NODE=""
  fi

  # Scale-out toggle
  if $SCALE_OUT && ! $YES; then
    echo ""
    log "Scale-out mode benchmarks every eligible core count TWICE: once as a"
    log "single MariaDB instance, and once as N x ${SHARD_CORES}-core independent"
    log "containers running concurrently, aggregating their throughput. This"
    log "roughly doubles run time for those core counts but shows how much"
    log "horizontal scale-out recovers from single-instance lock contention."
    confirm "Also run scale-out benchmarks?" default_yes || SCALE_OUT=false
  fi

  # Warehouses — >=10x max VUs avoids hot-row contention masking CPU scaling
  if [[ -z "$WAREHOUSES" ]]; then
    local rec=$(( maxc * 10 )); (( rec < 64 )) && rec=64
    echo ""
    log "TPC-C warehouses: for linear core scaling use >= 10x the highest VU"
    log "count, i.e. >= $(( maxc * 10 )) for a ${maxc}-core run. Smaller counts plateau"
    log "early from hot-row contention (schema build takes ~15s/warehouse)."
    prompt WAREHOUSES "TPC-C warehouse count (single-instance runs)" "$rec"
  fi
  if $SCALE_OUT; then
    log "Scale-out containers auto-size warehouses to 10x their own ${SHARD_CORES} cores" \
        "(use --warehouses on the command line to override every shard uniformly)."
  fi

  prompt RAMPUP   "Ramp-up minutes per run"  "$RAMPUP"
  prompt DURATION "Timed minutes per run"    "$DURATION"

  if ! $RUN_TPCH && ! $YES; then
    confirm "Also run TPC-H analytics benchmark?" default_no && RUN_TPCH=true
  fi
  $RUN_TPCH && prompt TPCH_SF "TPC-H scale factor (1/10/30/100)" "$TPCH_SF"

  # Buffer pool
  if [[ -z "$BUFFER_POOL" ]]; then
    local bp=$(( HOST_RAM_GiB * 3 / 4 )); (( bp < 1 )) && bp=1
    prompt BUFFER_POOL "InnoDB buffer pool size (total; scale-out splits this across shards)" "${bp}G"
  fi
  # MariaDB reads a bare number as bytes, so a missing unit (e.g. "16"
  # instead of "16G") silently creates an InnoDB buffer pool far too small
  # to start — mariadbd then fails immediately and the container just sits
  # unhealthy until the base runner's "did not start within 3 minutes" die.
  [[ "$BUFFER_POOL" =~ ^[0-9]+[KMGTkmgt]$ ]] \
    || die "Invalid buffer pool '$BUFFER_POOL' — must include a unit suffix, e.g. 64G or 8192M."

  prompt MARIADB_VER "MariaDB version (Docker tag)" "$MARIADB_VER"

  if $HOST_TUNING && ! $YES; then
    echo ""
    log "Host tuning sets: CPU governor=performance, vm.swappiness=1,"
    log "THP=never, and explicit 2MiB hugepages sized to the buffer pool."
    log "All settings are restored when the script exits."
    confirm "Apply host tuning (needs sudo)?" default_yes || HOST_TUNING=false
  fi

  [[ -z "$CUSTOMER" ]] && prompt CUSTOMER "Customer / PoC name for the report" "AMD EPYC PoC"
  prompt REPORT_FMT "Report format (md / pdf / both)" "$REPORT_FMT"
  case "$REPORT_FMT" in md|pdf|both) : ;; *) REPORT_FMT="both" ;; esac

  # Plan summary
  echo ""
  section "Run Plan"
  printf "  %-22s %s\n" "Core counts:"      "$CORES_LIST"
  printf "  %-22s %s\n" "Scale-out:"        "$($SCALE_OUT && echo "yes — ${SHARD_CORES}c containers" || echo no)"
  printf "  %-22s %s\n" "NUMA node pin:"    "${NUMA_NODE:-none}"
  printf "  %-22s %s\n" "Warehouses:"       "$WAREHOUSES"
  printf "  %-22s %s\n" "Ramp / timed:"     "${RAMPUP}m / ${DURATION}m per run"
  printf "  %-22s %s\n" "TPC-H:"            "$($RUN_TPCH && echo "yes (SF=$TPCH_SF)" || echo no)"
  printf "  %-22s %s\n" "Buffer pool:"      "$BUFFER_POOL"
  printf "  %-22s %s\n" "MariaDB:"          "$MARIADB_VER"
  printf "  %-22s %s\n" "Host tuning:"      "$($HOST_TUNING && echo yes || echo no)"
  printf "  %-22s %s\n" "Report:"           "$REPORT_FMT"
  printf "  %-22s %s\n" "Output dir:"       "$WORKDIR"
  local nruns=0
  for c in $CORES_LIST; do
    nruns=$(( nruns + 1 ))
    $SCALE_OUT && (( c % SHARD_CORES == 0 && c > SHARD_CORES )) && nruns=$(( nruns + 1 ))
  done
  local build_min=$(( WAREHOUSES * 15 / 60 + 1 ))
  local est=$(( nruns * (build_min + RAMPUP + DURATION + 5) ))
  log "Rough time estimate: ~${est} min (schema is rebuilt for every run; scale-out"
  log "runs count separately but its shards build concurrently)."
  echo ""
  if ! $YES && ! $DRY_RUN; then
    confirm "Proceed?" default_yes || die "Aborted by user."
  fi
}

# ── Single-instance run: drive the base runner + sample power/CPU ───────────
run_single_instance() {
  local c=$1 rapl_max=$2; shift 2
  local -a common=( "$@" )
  section "Benchmark: ${c} cores — single instance"
  local mdir="$WORKDIR/metrics/${c}core/single"
  local t0 t1 samp mpid rpid
  t0=$(date +%s)
  samp=$(start_sampling "$mdir" "$rapl_max"); read -r mpid rpid <<< "$samp"

  local -a flags=( "${common[@]}" --workdir "$WORKDIR/bench" --warehouses "$WAREHOUSES"
                    --buffer-pool "$BUFFER_POOL" --cores "$c" )
  [[ -n "$NUMA_NODE" ]] && flags+=( --numa-node "$NUMA_NODE" )

  ( cd "$BASE_DIR" && bash mariadb-tpcc-bench.sh "${flags[@]}" ) \
    || warn "Base runner exited non-zero for ${c}c single instance — check logs in $WORKDIR/bench/results/${c}core/"

  t1=$(date +%s)
  stop_sampling "$mdir" "$mpid" "$rpid" "$t0" "$t1"
}

# ── Scale-out run: N concurrent containers of --shard-cores each ────────────
run_scaleout() {
  local c=$1 rapl_max=$2; shift 2
  local -a common=( "$@" )
  local num_shards=$(( c / SHARD_CORES ))
  section "Benchmark: ${c} cores — scale-out (${num_shards} x ${SHARD_CORES}c containers)"

  shard_cpusets "$c" "$SHARD_CORES"
  local -a cpusets=( "${SHARD_CPUSETS[@]}" )

  local shard_ware
  if $WAREHOUSES_EXPLICIT; then
    shard_ware="$WAREHOUSES"
  else
    shard_ware=$(( SHARD_CORES * 10 )); (( shard_ware < 64 )) && shard_ware=64
  fi

  local bp_mib_total shard_bp_mib shard_bp
  bp_mib_total=$(bp_to_mib "$BUFFER_POOL")
  shard_bp_mib=$(( bp_mib_total / num_shards )); (( shard_bp_mib < 256 )) && shard_bp_mib=256
  shard_bp=$(mib_to_size "$shard_bp_mib")

  log "Per shard: ${SHARD_CORES}c, ${shard_ware} warehouses, buffer pool ${shard_bp}"

  local mdir="$WORKDIR/metrics/${c}core/scaleout"
  local t0 t1 samp mpid rpid
  t0=$(date +%s)
  samp=$(start_sampling "$mdir" "$rapl_max"); read -r mpid rpid <<< "$samp"

  local -a pids=()
  local i
  for (( i=0; i<num_shards; i++ )); do
    local shard_workdir="$WORKDIR/bench-scaleout/${c}core/shard${i}"
    local shard_tmp="$mdir/tmp-s${i}"
    local shard_port=$(( SHARD_PORT_BASE + i ))
    local -a shard_flags=( "${common[@]}"
                            --workdir "$shard_workdir"
                            --warehouses "$shard_ware"
                            --buffer-pool "$shard_bp"
                            --cores "$SHARD_CORES"
                            --port "$shard_port"
                            --container-name "mariadb-bench-${c}c-s${i}"
                            --tmp-dir "$shard_tmp" )
    [[ -n "${cpusets[$i]:-}" ]] && shard_flags+=( --cpuset "${cpusets[$i]}" )
    mkdir -p "$mdir"
    ( cd "$BASE_DIR" && bash mariadb-tpcc-bench.sh "${shard_flags[@]}" ) \
      > "$mdir/shard${i}.log" 2>&1 &
    pids+=( $! )
  done

  local fail=0 p
  for p in "${pids[@]}"; do
    wait "$p" || fail=$(( fail + 1 ))
  done
  (( fail > 0 )) && warn "${fail}/${num_shards} scale-out shards for ${c}c exited non-zero — check $mdir/shard*.log"

  t1=$(date +%s)
  stop_sampling "$mdir" "$mpid" "$rpid" "$t0" "$t1"

  # ── aggregate ────────────────────────────────────────────────────────────
  local total_nopm=0 total_tpm=0 total_vus=0 shards_ok=0
  for (( i=0; i<num_shards; i++ )); do
    local s="$WORKDIR/bench-scaleout/${c}core/shard${i}/results/${SHARD_CORES}core/tpcc_summary.txt"
    [[ -f "$s" ]] || continue
    local sn st sv
    sn=$(grep -oP '(?<=NOPM=)\d+' "$s" 2>/dev/null || echo "")
    st=$(grep -oP '(?<=TPM=)\d+'  "$s" 2>/dev/null || echo "")
    sv=$(grep -oP '(?<=VUs=)\d+'  "$s" 2>/dev/null | head -1 || echo "")
    [[ "$sn" =~ ^[0-9]+$ ]] && total_nopm=$(( total_nopm + sn ))
    [[ "$st" =~ ^[0-9]+$ ]] && total_tpm=$(( total_tpm + st ))
    [[ "$sv" =~ ^[0-9]+$ ]] && total_vus=$(( total_vus + sv ))
    shards_ok=$(( shards_ok + 1 ))
  done
  {
    echo "shards=$num_shards"
    echo "shard_cores=$SHARD_CORES"
    echo "total_nopm=$total_nopm"
    echo "total_tpm=$total_tpm"
    echo "total_vus=$total_vus"
    echo "shards_ok=$shards_ok"
  } > "$mdir/aggregate_summary.txt"
  ok "Scale-out ${c}c: ${shards_ok}/${num_shards} shards ok — aggregate NOPM=$total_nopm TPM=$total_tpm"
}

run_all_configs() {
  local -a base_flags_common=( --rampup "$RAMPUP" --duration "$DURATION"
                                --mariadb-ver "$MARIADB_VER" --yes )
  $RUN_TPCH && base_flags_common+=( --tpch-sf "$TPCH_SF" ) || base_flags_common+=( --skip-tpch )
  $DRY_RUN  && base_flags_common+=( --dry-run )

  local rapl_max; rapl_max=$(rapl_max_uj || true)
  [[ -n "${rapl_max:-}" ]] && log "RAPL package energy counters available — capturing power per run." \
                           || warn "RAPL energy counters not readable — NOPM/Watt will be omitted (try running as root)."

  # NOTE: single-instance always runs before scale-out for a given core
  # count, and the smallest core count in the sweep is always single-only
  # (== SHARD_CORES). This guarantees HammerDB is downloaded/cached by that
  # first sequential run before any concurrent scale-out shards ever launch
  # — avoiding a race on the shared $HOME/HammerDB install. Do not reorder.
  local c
  for c in $CORES_LIST; do
    run_single_instance "$c" "$rapl_max" "${base_flags_common[@]}"

    if $SCALE_OUT && (( c % SHARD_CORES == 0 && c > SHARD_CORES )); then
      run_scaleout "$c" "$rapl_max" "${base_flags_common[@]}"
    elif $SCALE_OUT && (( c % SHARD_CORES != 0 )); then
      warn "Skipping scale-out for ${c}c — not evenly divisible by --shard-cores ${SHARD_CORES}."
    fi
  done
}

# ── Report ───────────────────────────────────────────────────────────────────
md_escape() { sed 's/|/\\|/g'; }

sysinfo_val() { head -1 "$WORKDIR/sysinfo/$1" 2>/dev/null || echo "n/a"; }

build_report() {
  local rdir="$WORKDIR/bench/results"
  local rpt="$WORKDIR/${REPORT_BASENAME}.md"
  section "Building consolidated PoC report"

  # sorted, de-duplicated core-count sweep (independent of how --cores was typed)
  local -a cores_sorted
  IFS=$'\n' cores_sorted=( $(tr ' ' '\n' <<< "$CORES_LIST" | sort -n -u) ); unset IFS

  # one row per (cores, mode) that actually produced results, in sweep order
  local -a row_cores=() row_mode=() row_containers=() row_nopm=() row_vus=() row_watts=()
  local c
  for c in "${cores_sorted[@]}"; do
    local s="$rdir/${c}core/tpcc_summary.txt"
    if [[ -f "$s" ]]; then
      local n v w
      n=$(grep -oP '(?<=NOPM=)\d+' "$s" 2>/dev/null || echo "")
      v=$(grep -oP '(?<=VUs=)\d+'  "$s" 2>/dev/null | head -1 || echo "")
      w=$(grep -oP '(?<=avg_pkg_watts=).*' "$WORKDIR/metrics/${c}core/single/power.txt" 2>/dev/null || echo "")
      row_cores+=("$c"); row_mode+=("single"); row_containers+=("1")
      row_nopm+=("${n:--}"); row_vus+=("${v:--}"); row_watts+=("${w:--}")
    fi
    local agg="$WORKDIR/metrics/${c}core/scaleout/aggregate_summary.txt"
    if [[ -f "$agg" ]]; then
      local n v shards w
      n=$(grep -oP '(?<=total_nopm=)\d+' "$agg" 2>/dev/null || echo "")
      v=$(grep -oP '(?<=total_vus=)\d+'  "$agg" 2>/dev/null || echo "")
      shards=$(grep -oP '(?<=shards=)\d+' "$agg" 2>/dev/null || echo "?")
      w=$(grep -oP '(?<=avg_pkg_watts=).*' "$WORKDIR/metrics/${c}core/scaleout/power.txt" 2>/dev/null || echo "")
      row_cores+=("$c"); row_mode+=("scaleout"); row_containers+=("$shards")
      row_nopm+=("${n:--}"); row_vus+=("${v:--}"); row_watts+=("${w:--}")
    fi
  done
  (( ${#row_cores[@]} )) || { warn "No results found — no report generated."; return 1; }

  # baseline = smallest single-instance row with a numeric NOPM
  local baseline_nopm="" baseline_c="" i
  for i in "${!row_cores[@]}"; do
    if [[ "${row_mode[$i]}" == single && "${row_nopm[$i]}" =~ ^[0-9]+$ ]]; then
      baseline_nopm="${row_nopm[$i]}"; baseline_c="${row_cores[$i]}"; break
    fi
  done

  # largest single-instance row (for the single-instance headline speedup)
  local top_single_i=-1
  for i in "${!row_cores[@]}"; do
    [[ "${row_mode[$i]}" == single && "${row_nopm[$i]}" =~ ^[0-9]+$ ]] && top_single_i=$i
  done

  # largest scale-out row + the single-instance NOPM at that same core count
  local hero_i=-1
  for i in "${!row_cores[@]}"; do
    [[ "${row_mode[$i]}" == scaleout && "${row_nopm[$i]}" =~ ^[0-9]+$ ]] && hero_i=$i
  done
  local hero_single_nopm=""
  if (( hero_i >= 0 )); then
    for i in "${!row_cores[@]}"; do
      if [[ "${row_cores[$i]}" == "${row_cores[$hero_i]}" && "${row_mode[$i]}" == single ]]; then
        hero_single_nopm="${row_nopm[$i]}"
      fi
    done
  fi

  {
    echo "---"
    echo "title: \"${TITLE:-MariaDB Core-Scaling Benchmark — AMD CPU Proof of Concept}\""
    echo "subtitle: \"${CUSTOMER}\""
    echo "date: \"$(date '+%Y-%m-%d %H:%M %Z')\""
    echo "geometry: margin=2.2cm"
    echo "---"
    echo ""
    echo "# Executive Summary"
    echo ""
    if [[ -n "$baseline_nopm" && $top_single_i -ge 0 ]]; then
      local top_speedup
      top_speedup=$(awk -v a="${row_nopm[$top_single_i]}" -v b="$baseline_nopm" 'BEGIN{printf "%.2f", a/b}')
      echo "MariaDB ${MARIADB_VER} was benchmarked with the industry-standard HammerDB"
      echo "TPC-C OLTP workload across ${#cores_sorted[@]} CPU-core configurations"
      echo "(${cores_sorted[*]} cores) on the system described below. Single-instance"
      echo "throughput scaled from **$(printf "%'d" "$baseline_nopm") NOPM** at ${baseline_c} cores to"
      echo "**$(printf "%'d" "${row_nopm[$top_single_i]}") NOPM** at ${row_cores[$top_single_i]} cores —"
      echo "a **${top_speedup}x** increase, demonstrating how additional AMD CPU cores"
      echo "translate directly into database transaction throughput."
    else
      echo "MariaDB ${MARIADB_VER} was benchmarked with HammerDB TPC-C across core"
      echo "configurations: ${cores_sorted[*]}."
    fi
    if [[ -n "$hero_single_nopm" && "$hero_single_nopm" =~ ^[0-9]+$ && $hero_i -ge 0 ]]; then
      local uplift
      uplift=$(awk -v a="${row_nopm[$hero_i]}" -v b="$hero_single_nopm" 'BEGIN{printf "%.2f", a/b}')
      echo ""
      echo "At ${row_cores[$hero_i]} cores, sharding into ${row_containers[$hero_i]} x ${SHARD_CORES}-core"
      echo "independent MariaDB containers raised aggregate throughput to"
      echo "**$(printf "%'d" "${row_nopm[$hero_i]}") NOPM**, versus **$(printf "%'d" "$hero_single_nopm") NOPM**"
      echo "for a single ${row_cores[$hero_i]}-core instance — a **${uplift}x** improvement from"
      echo "horizontal scale-out alone, recovering throughput that single-instance"
      echo "lock/latch contention otherwise leaves on the table."
    fi
    echo ""
    echo "# System Under Test"
    echo ""
    echo "| Component | Detail |"
    echo "|---|---|"
    echo "| CPU | ${CPU_MODEL:-n/a} |"
    echo "| Topology | ${SOCKETS:-?} socket(s) x ${CORES_PER_SOCKET:-?} cores/socket, ${THREADS_PER_CORE:-?} thread(s)/core |"
    echo "| Logical CPUs | ${HOST_CORES} |"
    echo "| NUMA nodes | ${NUMA_NODES} (benchmark pinned to node: ${NUMA_NODE:-not pinned}) |"
    echo "| Memory | ${HOST_RAM_GiB} GiB |"
    echo "| Kernel | $(sysinfo_val uname.txt | md_escape) |"
    echo "| OS | $(grep -oP '(?<=PRETTY_NAME=\").*(?=\")' "$WORKDIR/sysinfo/os-release.txt" 2>/dev/null || echo n/a) |"
    echo "| Docker | $(sysinfo_val docker.txt) |"
    echo "| CPU governor | $(sysinfo_val governor.txt)$( $HOST_TUNING && echo ' -> performance (during run)' ) |"
    echo "| THP / hugepages | $(sysinfo_val thp.txt)$( $HOST_TUNING && echo ' -> never; explicit 2MiB hugepages for buffer pool' ) |"
    echo "| SMT | $( [[ "$SMT_ACTIVE" == 1 ]] && echo enabled || echo disabled ) |"
    echo ""
    echo "# Benchmark Configuration"
    echo ""
    echo "| Parameter | Value |"
    echo "|---|---|"
    echo "| Workload | HammerDB $(grep -oP '(?<=HAMMERDB_VERSION=\")[^\"]+' "$BASE_DIR/mariadb-tpcc-bench.sh" 2>/dev/null || echo 5.0) TPC-C (OLTP)$($RUN_TPCH && echo " + TPC-H SF=${TPCH_SF}") |"
    echo "| MariaDB | ${MARIADB_VER} (official Docker image, fresh instance per config) |"
    local shard_default_ware=$(( SHARD_CORES * 10 )); (( shard_default_ware < 64 )) && shard_default_ware=64
    echo "| Warehouses | ${WAREHOUSES} (single-instance); scale-out shards auto-sized to ${shard_default_ware} (10x${SHARD_CORES}c) unless --warehouses overridden |"
    echo "| Ramp-up / timed | ${RAMPUP} min / ${DURATION} min |"
    echo "| Virtual users | = core count (capped at 128) |"
    echo "| Buffer pool | ${BUFFER_POOL} total (scale-out splits evenly across shards) |"
    echo "| Scale-out | $($SCALE_OUT && echo "enabled — N x ${SHARD_CORES}-core independent containers per eligible core count" || echo disabled) |"
    echo "| CPU limiting | Docker cpu limit per run$( [[ -n "$NUMA_NODE" ]] && echo "; cpuset auto-derived from NUMA node ${NUMA_NODE}" ) |"
    echo "| InnoDB tuning | Per AMD EPYC RDBMS Tuning Guide (full my.cnf in Appendix A) |"
    echo ""
    echo "# TPC-C Results — Core Scaling"
    echo ""
    if [[ -n "$baseline_nopm" ]]; then
      echo "| Cores | Mode | Containers | VUs | NOPM | Speedup vs ${baseline_c}c | Scaling efficiency | Avg pkg power (W) | NOPM/W |"
      echo "|---:|---|---:|---:|---:|---:|---:|---:|---:|"
      for i in "${!row_cores[@]}"; do
        c="${row_cores[$i]}"
        local n="${row_nopm[$i]}" v="${row_vus[$i]}" w="${row_watts[$i]}" containers="${row_containers[$i]}"
        local mode_label="single"; [[ "${row_mode[$i]}" == scaleout ]] && mode_label="scale-out"
        local sp="-" eff="-" npw="-"
        if [[ "$n" =~ ^[0-9]+$ ]]; then
          sp=$(awk -v a="$n" -v b="$baseline_nopm" 'BEGIN{printf "%.2fx", a/b}')
          eff=$(awk -v a="$n" -v b="$baseline_nopm" -v c="$c" -v bc="$baseline_c" \
                'BEGIN{printf "%.0f%%", (a/b)/(c/bc)*100}')
          [[ "$w" != "-" ]] && npw=$(awk -v a="$n" -v w="$w" 'BEGIN{printf "%.0f", a/w}')
          n=$(printf "%'d" "$n")
        fi
        echo "| $c | $mode_label | $containers | $v | $n | $sp | $eff | $w | $npw |"
      done
      echo ""
      echo "Scaling efficiency = (NOPM speedup) / (core-count ratio); 100% is perfectly"
      echo "linear. Scale-out rows are the sum of NOPM across N independent MariaDB"
      echo "containers running concurrently — not a single-instance number — with"
      echo "efficiency measured against total cores committed (N x shard size)."
      echo "Power is the average CPU package draw (RAPL) over the whole config"
      echo "including schema build, so treat NOPM/W as indicative."
      if [[ -n "$NUMA_NODE" ]]; then
        if [[ -n "$RAPL_NODE_PKGS" ]]; then
          echo "Scoped to NUMA node ${NUMA_NODE}'s physical package(s) (${RAPL_NODE_PKGS});"
          echo "idle sockets are excluded."
        else
          echo "Could not resolve NUMA node ${NUMA_NODE} to a physical package (topology"
          echo "sysfs unavailable) -- power reflects every package on the host, including"
          echo "idle ones, despite the NUMA pin."
        fi
      fi
      echo ""
      echo "## Throughput chart"
      echo ""
      echo '```'
      local max_n=1
      for i in "${!row_cores[@]}"; do [[ "${row_nopm[$i]}" =~ ^[0-9]+$ ]] && (( row_nopm[i] > max_n )) && max_n=${row_nopm[$i]}; done
      for i in "${!row_cores[@]}"; do
        c="${row_cores[$i]}"; local n="${row_nopm[$i]}"
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        local label="${c}c"
        [[ "${row_mode[$i]}" == scaleout ]] && label="${c}c x${row_containers[$i]}(${SHARD_CORES}c)"
        local bars=$(( n * 50 / max_n )); (( bars < 1 )) && bars=1
        printf "%14s | %s %s NOPM\n" "$label" "$(printf '#%.0s' $(seq 1 $bars))" "$(printf "%'d" "$n")"
      done
      echo '```'
    else
      echo "_NOPM values could not be parsed — see raw logs under bench/results/._"
    fi
    echo ""

    # Latency section lifted from the base runner's single-instance report
    local base_rpt="$rdir/benchmark_report.md"
    if [[ -f "$base_rpt" ]]; then
      echo "# Transaction Latency & Detailed Results (single-instance runs)"
      echo ""
      awk '/^### Transaction Latency/,/^## Notes/' "$base_rpt" | sed '$d' \
        | sed 's/^####/##/; s/^###/#/' | sed 's/^# /## /'
      if $RUN_TPCH; then
        awk '/^## TPC-H Results/,/^---/' "$base_rpt" | sed '$d'
        echo ""
      fi
    fi

    echo "# Methodology Notes"
    echo ""
    echo "- NOPM (New Orders Per Minute) is the primary TPC-C metric and is"
    echo "  comparable across database engines; TPM counts all five transaction types."
    echo "- Each core count runs in a fresh MariaDB container with a my.cnf scaled"
    echo "  to that core budget; the datadir volume is destroyed between configs."
    echo "- Scale-out rows sum NOPM/TPM across N independently-sharded MariaDB"
    echo "  containers benchmarked concurrently, each with its own schema, buffer"
    echo "  pool slice, and CPU pin — a proxy for horizontal/sharded deployment,"
    echo "  not a single logically-consistent database."
    echo "- Durability is relaxed for peak-throughput measurement"
    echo "  (\`innodb_flush_log_at_trx_commit=0\`, \`innodb_doublewrite=0\`);"
    echo "  production deployments should use safer settings."
    echo "- Results are for relative core-scaling comparison on this system and are"
    echo "  not audited TPC results; TPC-C/TPC-H are used per HammerDB fair-use."
    echo ""
    echo "# Appendix A — MariaDB Configuration Per Core Count (single-instance)"
    echo ""
    for c in "${cores_sorted[@]}"; do
      local cnf="$WORKDIR/bench/configs/${c}core.cnf"
      [[ -f "$cnf" ]] || continue
      echo "## ${c}-core my.cnf"
      echo ""
      echo '```ini'
      cat "$cnf"
      echo '```'
      echo ""
    done
    if $SCALE_OUT && (( hero_i >= 0 )); then
      local first_scaleout_c=""
      for i in "${!row_cores[@]}"; do
        if [[ "${row_mode[$i]}" == scaleout ]]; then first_scaleout_c="${row_cores[$i]}"; break; fi
      done
      local shard_cnf="$WORKDIR/bench-scaleout/${first_scaleout_c}core/shard0/configs/${SHARD_CORES}core.cnf"
      if [[ -f "$shard_cnf" ]]; then
        echo "# Appendix A2 — Scale-out Shard my.cnf (${SHARD_CORES}-core, used by every scale-out container)"
        echo ""
        echo '```ini'
        cat "$shard_cnf"
        echo '```'
        echo ""
      fi
    fi
    echo "# Appendix B — Host Details"
    echo ""
    echo '```'
    cat "$WORKDIR/sysinfo/lscpu.txt" 2>/dev/null || true
    echo ""
    cat "$WORKDIR/sysinfo/free.txt" 2>/dev/null || true
    echo '```'
  } > "$rpt"

  ok "Markdown report: $rpt"

  if [[ "$REPORT_FMT" != "md" ]] && $HAVE_PANDOC; then
    local pdf="$WORKDIR/${REPORT_BASENAME}.pdf"
    if pandoc "$rpt" -o "$pdf" --toc -V colorlinks=true 2>"$WORKDIR/pandoc.err"; then
      ok "PDF report:      $pdf"
    else
      warn "pandoc PDF conversion failed (see $WORKDIR/pandoc.err) — is a LaTeX engine installed?"
      warn "  sudo apt-get install -y texlive-latex-recommended texlive-fonts-recommended"
    fi
  fi
  [[ "$REPORT_FMT" == "pdf" ]] && log "(Markdown kept alongside the PDF as the source of truth.)"
  return 0
}

# ── Cleanup ──────────────────────────────────────────────────────────────────
cleanup() {
  revert_host_tuning || true
}
trap cleanup EXIT INT TERM

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════
main() {
  section "AMD CPU PoC — MariaDB Core-Scaling Benchmark"
  check_deps
  detect_system

  [[ -z "$WORKDIR" ]] && WORKDIR="$(pwd)/amd-poc-$(date +%Y%m%d-%H%M)"
  mkdir -p "$WORKDIR"
  WORKDIR="$(cd "$WORKDIR" && pwd)"
  REPORT_BASENAME="amd-mariadb-poc-report"

  fetch_base_repo
  check_scaleout_support
  wizard
  collect_sysinfo
  resolve_rapl_scope

  $HOST_TUNING && apply_host_tuning

  local t_start=$SECONDS
  run_all_configs
  local t_total=$(( SECONDS - t_start ))

  revert_host_tuning

  if $DRY_RUN; then
    ok "Dry run complete — no benchmarks executed, no report generated."
    exit 0
  fi

  build_report || true

  echo ""
  section "PoC complete in $(( t_total / 60 )) min"
  log "Everything you need for the customer:"
  log "  Report      : $WORKDIR/${REPORT_BASENAME}.md$( [[ -f "$WORKDIR/${REPORT_BASENAME}.pdf" ]] && echo " (+ .pdf)" )"
  log "  Raw results : $WORKDIR/bench/results/  (single-instance)"
  $SCALE_OUT && log "  Scale-out   : $WORKDIR/bench-scaleout/  (per-shard results)"
  log "  Configs     : $WORKDIR/bench/configs/"
  log "  Metrics     : $WORKDIR/metrics/   (power, mpstat, scale-out aggregates)"
  log "  Sysinfo     : $WORKDIR/sysinfo/"
}

main "$@"
