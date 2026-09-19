#!/usr/bin/env bash
# Portable hardware probe for the local AI server plugin.
#
# Emits one flat JSON object describing the GPU, VRAM, RAM and CPU of the
# host, so the plugin can suggest launch parameters instead of shipping
# constants bisected against one particular laptop.
#
# Every field is best-effort: anything undetectable comes back as 0 or "",
# and the caller treats that as "no suggestion" rather than an error. The
# script must therefore never fail hard -- a machine with no GPU, no
# nvidia-smi and no /proc is still a valid CPU-only target.

set -uo pipefail

vendor=""
vram_mb=0
gpu_name=""

# --- GPU / VRAM ---------------------------------------------------------
# Tried in order of specificity: vendor tools report real per-device VRAM,
# the sysfs and Metal fallbacks are coarser but need no extra packages.

if command -v nvidia-smi >/dev/null 2>&1; then
  # memory.total is queried first so the numeric field can be split off the
  # front on the comma -- GPU names contain spaces, which would otherwise
  # word-split across fields and swallow the VRAM figure.
  nv_line=$(nvidia-smi --query-gpu=memory.total,name --format=csv,noheader,nounits 2>/dev/null | head -n 1)
  if [[ -n ${nv_line:-} ]]; then
    nv_vram=$(printf '%s' "$nv_line" | cut -d, -f1 | tr -dc '0-9')
    if [[ -n $nv_vram ]]; then
      vram_mb=$nv_vram
      gpu_name=$(printf '%s' "$nv_line" | cut -d, -f2- | sed 's/^ *//')
      vendor="nvidia"
    fi
  fi
fi

if [[ -z $vendor ]] && command -v rocm-smi >/dev/null 2>&1; then
  # rocm-smi prints VRAM in bytes under a "Total VRAM" style heading; the
  # exact wording varies by version, so match loosely on the first number.
  vram_bytes=$(rocm-smi --showmeminfo vram --csv 2>/dev/null | awk -F, 'NR==2 {print $2}' | tr -dc '0-9')
  if [[ -n $vram_bytes ]]; then
    vram_mb=$(( vram_bytes / 1024 / 1024 ))
    vendor="amd"
    gpu_name=$(rocm-smi --showproductname --csv 2>/dev/null | awk -F, 'NR==2 {print $2}')
  fi
fi

if [[ -z $vendor ]]; then
  # AMD/Intel discrete cards expose VRAM through sysfs without any vendor
  # tooling installed.
  for f in /sys/class/drm/card*/device/mem_info_vram_total; do
    [[ -r $f ]] || continue
    bytes=$(cat "$f" 2>/dev/null | tr -dc '0-9')
    [[ -n $bytes ]] || continue
    vram_mb=$(( bytes / 1024 / 1024 ))
    vendor="drm"
    break
  done
fi

if [[ -z $vendor ]] && [[ $(uname -s 2>/dev/null) == "Darwin" ]]; then
  # Apple Silicon shares one pool between CPU and GPU, so total system
  # memory is the honest VRAM figure.
  bytes=$(sysctl -n hw.memsize 2>/dev/null | tr -dc '0-9')
  if [[ -n $bytes ]]; then
    vram_mb=$(( bytes / 1024 / 1024 ))
    vendor="metal"
    gpu_name=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  fi
fi

[[ -z $vendor ]] && vendor="cpu"
[[ -z ${vram_mb:-} || ! $vram_mb =~ ^[0-9]+$ ]] && vram_mb=0

# Name the GPU even when only lspci can see it, so the UI can say what it
# found rather than showing an empty field.
if [[ -z ${gpu_name:-} ]] && command -v lspci >/dev/null 2>&1; then
  gpu_name=$(lspci 2>/dev/null | grep -iE 'vga|3d controller' | head -n 1 | cut -d: -f3- | sed 's/^ *//')
fi

# --- RAM ----------------------------------------------------------------

ram_mb=0
if [[ -r /proc/meminfo ]]; then
  kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
  [[ -n $kb ]] && ram_mb=$(( kb / 1024 ))
elif command -v sysctl >/dev/null 2>&1; then
  bytes=$(sysctl -n hw.memsize 2>/dev/null | tr -dc '0-9')
  [[ -n $bytes ]] && ram_mb=$(( bytes / 1024 / 1024 ))
fi

# --- CPU ----------------------------------------------------------------
# Physical cores, not threads: llama.cpp throughput degrades past the
# physical count, so -t should not be set from nproc.

threads=$(nproc 2>/dev/null || echo 0)
cores=0
if command -v lscpu >/dev/null 2>&1; then
  sockets=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/ {gsub(/ /,"",$2); print $2; exit}')
  per_socket=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/ {gsub(/ /,"",$2); print $2; exit}')
  [[ -n ${sockets:-} && -n ${per_socket:-} ]] && cores=$(( sockets * per_socket ))
fi
if [[ $cores -eq 0 && -r /proc/cpuinfo ]]; then
  cores=$(awk -F: '/^core id/ {print $2}' /proc/cpuinfo | sort -u | wc -l)
fi
[[ $cores -eq 0 ]] && cores=$threads
[[ -z ${threads:-} || $threads -eq 0 ]] && threads=$cores

json_escape() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'; }

printf '{"vendor":"%s","gpuName":"%s","vramMb":%d,"ramMb":%d,"cores":%d,"threads":%d}\n' \
  "$(json_escape "$vendor")" \
  "$(json_escape "${gpu_name:-}")" \
  "${vram_mb:-0}" "${ram_mb:-0}" "${cores:-0}" "${threads:-0}"
