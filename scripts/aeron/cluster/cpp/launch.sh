#!/usr/bin/env bash
##
## C++ cluster member launcher — the A′ seam's four verbs.
##
##   launch.sh start|stop|check|counters <cell_dir>
##
## Main arm: `deepmsg-cluster-node --embedded-driver` (driver + archive + CM) +
## `deepmsg-clustered-service-container`. That is two processes, the same count
## as the Java reference's external driver + JVM.
##
## `driver_mode=external` runs the same aggregate node against a media driver
## the harness started (the P4b `c-j` diagnostic, or P4c's first step). The
## four-process split (driver + archive + CM + container) is P4c and is not
## implemented here yet: it must not quietly masquerade as the main arm.
##
## The launcher reads only cell.properties (plan §2.6 A′-2). Binary paths come
## from DEEPMSG_CPP_* environment variables, written into the cell by the
## harness; nothing here invents a channel, mtu, sync level or core.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LAUNCHER_DIR="${DIR}"
action=${1:?usage: launch.sh start|stop|check|counters <cell_dir>}
CELL_DIR=${2:?usage: launch.sh start|stop|check|counters <cell_dir>}
source "${DIR}/../common/contract.sh"

node_bin()
{
  local path
  path=$(cell_prop cpp_cluster_node)
  require_executable "cpp_cluster_node" "${path}"
  printf '%s' "${path}"
}

container_bin()
{
  local path
  path=$(cell_prop cpp_container)
  require_executable "cpp_container" "${path}"
  printf '%s' "${path}"
}

do_start()
{
  load_cell
  local driver_mode aeron_dir cluster_dir archive_dir container_cpu
  driver_mode=$(cell_prop driver_mode external)
  aeron_dir=$(require_prop aeron_dir)
  cluster_dir=$(require_prop cluster_dir)
  archive_dir=$(require_prop archive_dir)
  container_cpu=$(cell_prop container_cpu)

  local node
  node=$(node_bin)
  local container
  container=$(container_bin)

  if [[ "${driver_mode}" == "embedded" ]]
  then
    rm -rf "${aeron_dir}" "${cluster_dir}" "${archive_dir}"
  else
    # The harness owns the external driver. Its directory is live; only the
    # cluster's own state is cleared.
    rm -rf "${cluster_dir}" "${archive_dir}"
  fi
  mkdir -p "${aeron_dir}" "${cluster_dir}" "${archive_dir}"

  if [[ "${driver_mode}" == "external" ]]
  then
    wait_for_cnc 60
  fi

  local -a node_defines=()
  mapfile -t node_defines < <("${DIR}/translate.sh" node "${CELL_DIR}")

  if [[ "${driver_mode}" == "embedded" ]]
  then
    start_bg "${CELL_DIR}/node.log" "" "${node}" "${node_defines[@]}" --embedded-driver
    wait_for_cnc 60
  else
    start_bg "${CELL_DIR}/node.log" "" "${node}" "${node_defines[@]}"
  fi
  sleep 1
  require_alive "deepmsg-cluster-node" "${LAST_PID}"
  local node_pid=${LAST_PID}

  pin_tid_by_name "${node_pid}" "archive-conduct" "$(cell_prop archive_conductor_cpu)"
  pin_tid_by_name "${node_pid}" "archive-recorde" "$(cell_prop archive_recorder_cpu)"
  pin_tid_by_name "${node_pid}" "archive-replaye" "$(cell_prop archive_replayer_cpu)"

  # The container attaches to the CM's mark; starting it before the mark is
  # written is a start-up race that reads as "the service container died".
  wait_for_file "${cluster_dir}/cluster-mark.dat" 30 || \
    die "no ${cluster_dir}/cluster-mark.dat after 30s"

  local -a container_defines=()
  mapfile -t container_defines < <("${DIR}/translate.sh" container "${CELL_DIR}")
  start_bg "${CELL_DIR}/container.log" "${container_cpu}" "${container}" "${container_defines[@]}"
  sleep 1
  require_alive "deepmsg-clustered-service-container" "${LAST_PID}"

  # The CM's agent thread starts after the service container joins; pin it
  # after the container is up, with a longer window than the archive agents.
  pin_tid_by_name "${node_pid}" "consensus-modul" "$(cell_prop cm_cpu)" \
    "$(cell_prop pin_attempts_cm 300)"

  up
}

do_stop()
{
  # Evidence before the shutdown: a SIGTERM stamps the driver counters
  # RECLAIMED and the heartbeat stops moving.
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
