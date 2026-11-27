#!/usr/bin/env bash
##
## The four-verb contract shared by every cluster launcher (A′, 2026-11-27).
##
## A launcher is called by `remote-cluster-benchmarks` as
##
##   cluster/<impl>/launch.sh <start|stop|check|counters> <cell_dir>
##
## and `<cell_dir>/cell.properties` carries every value the harness chose for
## this member and this cell. Nothing here defines a cell value: the properties
## are the single source (plan 2026-11-26, §2.6 A′-2). An implementation may
## translate them, start processes, pin threads and take evidence; it may not
## invent a different channel, mtu, sync level or core.
##
## The launcher owns its processes: the harness knows only the verb and the
## directory. That is why wait/kill/pin live here rather than in the 700-line
## script that still carries the Java node's assumptions.

set -euo pipefail

: "${CELL_DIR:?contract.sh: CELL_DIR must be set before sourcing}"
PROPERTIES="${CELL_DIR}/cell.properties"
PIDS_FILE="${CELL_DIR}/pids"
LAST_PID=""

die()
{
  echo "launch(${CELL_DIR}): $*" >&2
  exit 1
}

log()
{
  echo "[$(date --rfc-3339=seconds)] $*" >&2
}

# One `key=value` a line. The first match wins; a missing key yields the
# default (empty when none was given).
cell_prop()
{
  local key=${1}
  local default=${2-}
  local line
  line=$(awk -v key="${key}" 'index($0, key "=") == 1 { print; exit }' "${PROPERTIES}" 2>/dev/null || true)
  if [[ -z "${line}" ]]
  then
    printf '%s' "${default}"
  else
    printf '%s' "${line#*=}"
  fi
}

require_prop()
{
  local key=${1}
  local value
  value=$(cell_prop "${key}")
  [[ -n "${value}" ]] || die "cell.properties: '${key}' is missing or empty"
  printf '%s' "${value}"
}

require_executable()
{
  local what=${1}
  local path=${2}
  [[ -n "${path}" ]] || die "${what} is not set in cell.properties (binary path)"
  [[ -x "${path}" ]] || die "${what} is not executable: ${path}"
}

load_cell()
{
  [[ -f "${PROPERTIES}" ]] || die "no ${PROPERTIES}"
  [[ "$(cell_prop impl)" == "$(basename "${LAUNCHER_DIR}")" ]] || \
    die "cell.properties impl=$(cell_prop impl) does not match launcher ${LAUNCHER_DIR}"
}

record_pid()
{
  local pid=${1}
  echo "${pid}" >>"${PIDS_FILE}"
}

# start_bg <log> <cpuset-or-empty> <command...>
# The cpuset is for a single-threaded agent (the container); multi-agent
# processes are pinned by name with pin_tid_by_name after they start.
start_bg()
{
  local logfile=${1}
  local cpuset=${2}
  shift 2
  if [[ -n "${cpuset}" ]]
  then
    taskset -c "${cpuset}" "$@" >>"${logfile}" 2>&1 &
  else
    "$@" >>"${logfile}" 2>&1 &
  fi
  LAST_PID=$!
  record_pid "${LAST_PID}"
  log "started pid=${LAST_PID} cpuset='${cpuset}' -> ${logfile}"
}

wait_for_file()
{
  local path=${1}
  local timeout=${2:-60}
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline ))
  do
    [[ -e "${path}" ]] && return 0
    sleep 0.1
  done
  return 1
}

wait_for_cnc()
{
  wait_for_file "$(cell_prop aeron_dir)/cnc.dat" "${1:-60}" || \
    die "no cnc.dat under $(cell_prop aeron_dir) after ${1:-60}s"
}

wait_for_archive_mark()
{
  local mark_dir
  mark_dir=$(cell_prop aeron_dir)
  local marker="${mark_dir}/archive-mark.dat"
  local deadline=$((SECONDS + ${1:-60}))
  while (( SECONDS < deadline ))
  do
    if [[ -s "${marker}" ]] && (( $(stat -c '%s' "${marker}") > 8192 ))
    then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

alive()
{
  kill -0 "${1}" 2>/dev/null
}

require_alive()
{
  local what=${1}
  local pid=${2}
  alive "${pid}" || die "${what} (pid ${pid}) did not stay up"
}

# pin_tid_by_name <pid> <comm-prefix> <cpu> [attempts]
# The kernel truncates comm to 15 characters; callers pass the prefix the
# reference's names already use (`archive-recorde`, `consensus-modul`, …).
# A silently failed pin is worse than no pin, so the read-back is checked.
pin_tid_by_name()
{
  local pid=${1}
  local name=${2}
  local cpu=${3}
  local attempts=${4:-${PIN_ATTEMPTS:-100}}
  [[ -n "${cpu}" ]] || return 0
  local tid=""
  local _ attempt
  # Threads appear within the first second of a real process; the CM thread can
  # take longer because it starts after the service container joins. Callers
  # choose the window; the default is ten seconds.
  for attempt in $(seq 1 "${attempts}")
  do
    tid=$(ps -L -o tid=,comm= -p "${pid}" 2>/dev/null | awk -v n="${name}" 'index($2, n) == 1 { print $1; exit }' || true)
    [[ -n "${tid}" ]] && break
    sleep 0.1
  done
  if [[ -z "${tid}" ]]
  then
    log "WARNING: no thread '${name}' in pid ${pid}; not pinned"
    return 0
  fi
  taskset -pc "${cpu}" "${tid}" >/dev/null 2>&1 || true
  local got
  got=$(taskset -pc "${tid}" 2>/dev/null | sed 's/.*: //' || true)
  if [[ "${got}" != "${cpu}" && ",${got}," != *",${cpu},"* ]]
  then
    log "WARNING: thread '${name}' asked for core ${cpu}, holds '${got}'"
  fi
}

stop_pids()
{
  [[ -f "${PIDS_FILE}" ]] || return 0
  local -a pids=()
  mapfile -t pids <"${PIDS_FILE}"
  local pid
  for (( i=${#pids[@]}-1; i>=0; i-- ))
  do
    pid=${pids[i]}
    [[ -n "${pid}" ]] && kill -TERM "${pid}" 2>/dev/null || true
  done
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline ))
  do
    local any=0
    for pid in "${pids[@]}"
    do
      [[ -n "${pid}" ]] && alive "${pid}" && any=1
    done
    (( any == 0 )) && break
    sleep 0.1
  done
  for pid in "${pids[@]}"
  do
    [[ -n "${pid}" ]] && alive "${pid}" && kill -KILL "${pid}" 2>/dev/null || true
  done
  : >"${PIDS_FILE}"
}

on_error()
{
  local rc=$?
  trap - ERR
  : >"${CELL_DIR}/failed"
  log "FAILED (rc=${rc}); stopping what is up"
  stop_pids || true
  exit "${rc}"
}

begin()
{
  mkdir -p "${CELL_DIR}"
  rm -f "${CELL_DIR}/up" "${CELL_DIR}/failed"
  : >"${PIDS_FILE}"
  trap on_error ERR
}

up()
{
  : >"${CELL_DIR}/up"
  log "up: $(tr '\n' ' ' <"${PIDS_FILE}")"
}
