#!/usr/bin/env bash
##
## Rust cluster member launcher — the A′ seam's four verbs.
##
##   launch.sh start|stop|check|counters <cell_dir>
##
## Four processes: `deepmsg-driver`, `deepmsg-archive`,
## `deepmsg-cluster-node` (the consensus module) and
## `deepmsg-clustered-service-container`. The driver + archive split is not a
## performance claim: the combined archiving driver accepts only SHARED or
## INVOKER, while the reference runs DEDICATED (plan §2.6 A′-9, §7).
##
## The archive has no `aeron.archive.*.cpu.affinity` in this build, so it is
## pinned as a process with taskset over its three agents' cores. The driver's
## three agents are pinned by their properties; CM and container are
## single-agent processes and are pinned with taskset.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LAUNCHER_DIR="${DIR}"
action=${1:?usage: launch.sh start|stop|check|counters <cell_dir>}
CELL_DIR=${2:?usage: launch.sh start|stop|check|counters <cell_dir>}
source "${DIR}/../common/contract.sh"

require_binary()
{
  local key=${1}
  local what=${2}
  local path
  path=$(cell_prop "${key}")
  require_executable "${what}" "${path}"
  printf '%s' "${path}"
}

archive_cpuset()
{
  local configured
  configured=$(cell_prop archive_cpuset)
  if [[ -n "${configured}" ]]
  then
    printf '%s' "${configured}"
    return
  fi
  local conductor recorder replayer
  conductor=$(cell_prop archive_conductor_cpu)
  recorder=$(cell_prop archive_recorder_cpu)
  replayer=$(cell_prop archive_replayer_cpu)
  local list=""
  for cpu in "${conductor}" "${recorder}" "${replayer}"
  do
    [[ -z "${cpu}" ]] && continue
    [[ -n "${list}" ]] && list+=","
    list+="${cpu}"
  done
  printf '%s' "${list}"
}

write_driver_properties()
{
  local target="${CELL_DIR}/driver.properties"
  local harness_file
  harness_file=$(cell_prop driver_properties_file)
  : >"${target}"
  if [[ -n "${harness_file}" && -f "${harness_file}" ]]
  then
    cat "${harness_file}" >>"${target}"
  else
    log "no harness benchmark.properties (${harness_file}); the driver gets only the launcher's values"
  fi
  "${DIR}/translate.sh" driver "${CELL_DIR}" >>"${target}"
}

# deepmsg-driver takes the reference aeronmd's argument shape — `-Dname=value`
# — not a properties file path (crates/driver/src/config.rs, `from_args`,
# "expected -Dname=value"). The C++ driver does read a file; the Rust one does
# not, and handing it one makes it exit before the CnC exists. The file is
# still written: it is the cell's record of what the driver was given.
driver_args()
{
  local line key value
  while IFS= read -r line
  do
    [[ -n "${line}" && "${line}" != \#* && "${line}" == *=* ]] || continue
    key=${line%%=*}
    value=${line#*=}
    printf -- '-D%s=%s\n' "${key}" "${value}"
  done <"${CELL_DIR}/driver.properties"
}

do_start()
{
  load_cell
  local driver_mode aeron_dir cluster_dir archive_dir
  driver_mode=$(cell_prop driver_mode external)
  aeron_dir=$(require_prop aeron_dir)
  cluster_dir=$(require_prop cluster_dir)
  archive_dir=$(require_prop archive_dir)

  local driver archive cm container
  driver=$(require_binary rust_driver "rust_driver")
  archive=$(require_binary rust_archive "rust_archive")
  cm=$(require_binary rust_cluster_node "rust_cluster_node")
  container=$(require_binary rust_container "rust_container")

  if [[ "${driver_mode}" == "embedded" ]]
  then
    rm -rf "${aeron_dir}" "${cluster_dir}" "${archive_dir}"
  else
    rm -rf "${cluster_dir}" "${archive_dir}"
  fi
  # Same cold start as the Java arm (contract.sh); see the comment there.
  drop_caches_and_trim
  mkdir -p "${aeron_dir}" "${cluster_dir}" "${archive_dir}"

  if [[ "${driver_mode}" == "embedded" ]]
  then
    write_driver_properties
    local -a driver_defines=()
    mapfile -t driver_defines < <(driver_args)
    start_bg "${CELL_DIR}/driver.log" "$(cell_prop driver_cpuset)" "${driver}" "${driver_defines[@]}"
    wait_for_cnc 60
  else
    wait_for_cnc 60
  fi

  local -a archive_defines=()
  mapfile -t archive_defines < <("${DIR}/translate.sh" archive "${CELL_DIR}")
  start_bg "${CELL_DIR}/archive.log" "$(archive_cpuset)" "${archive}" "${archive_defines[@]}"
  wait_for_archive_mark 60 || die "no archive-mark.dat over 8192 bytes after 60s"

  local -a node_defines=()
  mapfile -t node_defines < <("${DIR}/translate.sh" node "${CELL_DIR}")
  start_bg "${CELL_DIR}/module.log" "$(cell_prop cm_cpu)" "${cm}" "${node_defines[@]}"
  sleep 1
  require_alive "deepmsg-cluster-node" "${LAST_PID}"

  # Same race as the C++ arm: the container needs the CM's mark.
  wait_for_file "${cluster_dir}/cluster-mark.dat" 30 || \
    die "no ${cluster_dir}/cluster-mark.dat after 30s"

  local -a container_defines=()
  mapfile -t container_defines < <("${DIR}/translate.sh" container "${CELL_DIR}")
  start_bg "${CELL_DIR}/container.log" "$(cell_prop container_cpu)" "${container}" "${container_defines[@]}"
  sleep 1
  require_alive "deepmsg-clustered-service-container" "${LAST_PID}"

  up
}

do_stop()
{
  do_counters || true
  stop_pids
}

do_check()
{
  [[ -s "${PIDS_FILE}" ]] || { log "no pid list"; return 1; }
  local pid dead=0
  while read -r pid
  do
    [[ -n "${pid}" ]] || continue
    if ! alive "${pid}"
    then
      log "pid ${pid} is gone"
      dead=1
    fi
  done <"${PIDS_FILE}"
  return "${dead}"
}

do_counters()
{
  local aeron_dir cnc_dump
  aeron_dir=$(cell_prop aeron_dir)
  cnc_dump=$(cell_prop cnc_dump)
  if [[ -z "${cnc_dump}" || ! -x "${cnc_dump}" ]]
  then
    log "no executable cnc_dump (DEEPMSG_CNC_DUMP); evidence is missing"
    return 1
  fi
  if [[ ! -f "${aeron_dir}/cnc.dat" ]]
  then
    log "no cnc.dat under ${aeron_dir}; nothing to dump"
    return 1
  fi
  "${cnc_dump}" --all "${aeron_dir}" >"${CELL_DIR}/counters.txt" 2>&1
  log "counters -> ${CELL_DIR}/counters.txt"
}

case "${action}" in
  start) begin; do_start ;;
  stop) do_stop ;;
  check) do_check ;;
  counters) do_counters ;;
  *) die "unknown action '${action}' (start|stop|check|counters)" ;;
esac
