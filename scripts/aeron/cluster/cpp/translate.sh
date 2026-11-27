#!/usr/bin/env bash
##
## C++ property translation: cell.properties (the harness's values) -> `-D`
## arguments the `deepmsg-*` binaries accept.
##
##   translate.sh node|container <cell_dir>
##
## The table is plan §2.5. Values that must be identical across arms come from
## cell.properties; this file may choose *how* to spell them, never *what* they
## are. `archive` is not a separate process in the main C++ arm: it is part of
## `deepmsg-cluster-node --embedded-driver`, so its settings ride on `node`.
##
## ★ `aeron.cluster.file.sync.level` defaults to 0 in the reference
## (`ConsensusModule.FILE_SYNC_LEVEL_DEFAULT`), while the harness's
## `--file-sync-level` sets the archive's level. `sync_cluster` therefore comes
## from its own cell key (default 0), not from `sync_archive` (P3a parity).

set -euo pipefail

mode=${1:?usage: translate.sh node|container <cell_dir>}
CELL_DIR=${2:?usage: translate.sh node|container <cell_dir>}
LAUNCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "${LAUNCHER_DIR}/../common/contract.sh"

emit()
{
  printf -- '-D%s=%s\n' "$1" "$2"
}

emit_if_set()
{
  [[ -n "${2}" ]] && emit "$1" "$2" || true
}

# The ingress endpoint of one member from the six-field members string.
# The reference appends it to the ingress channel when the channel has no
# `endpoint` (`ConsensusModuleAgent.connectIngress`, `:3389-3392`); this
# build does not, so the translation does it here.
member_endpoint()
{
  local members=${1}
  local member_id=${2}
  local field=${3}
  local -a entries fields
  local entry
  IFS='|' read -ra entries <<<"${members}"
  for entry in "${entries[@]}"
  do
    IFS=',' read -ra fields <<<"${entry}"
    if [[ "${fields[0]}" == "${member_id}" ]]
    then
      printf '%s' "${fields[field]}"
      return 0
    fi
  done
  return 1
}

node_defines()
{
  local aeron_dir cluster_dir archive_dir members ingress member_id
  aeron_dir=$(require_prop aeron_dir)
  cluster_dir=$(require_prop cluster_dir)
  archive_dir=$(require_prop archive_dir)
  members=$(require_prop members)
  member_id=$(require_prop member_id)
  ingress=$(require_prop ingress)
  if [[ "${ingress}" != *"endpoint="* ]]
  then
    local ingress_endpoint
    ingress_endpoint=$(member_endpoint "${members}" "${member_id}" 1) || \
      die "no ingress endpoint for member ${member_id} in '${members}'"
    if [[ "${ingress}" == *"?"* ]]
    then
      ingress+="|endpoint=${ingress_endpoint}"
    else
      ingress+="?endpoint=${ingress_endpoint}"
    fi
  fi

  emit aeron.dir "${aeron_dir}"
  emit aeron.cluster.dir "${cluster_dir}"
  emit aeron.cluster.id "$(require_prop cluster_id)"
  emit aeron.cluster.member.id "${member_id}"
  emit aeron.cluster.members "${members}"
  local leader
  leader=$(cell_prop appointed_leader -1)
  if [[ "${leader}" =~ ^[0-9]+$ ]]
  then
    emit aeron.cluster.appointed.leader.id "${leader}"
  fi
  emit aeron.cluster.ingress.channel "${ingress}"
  emit aeron.cluster.consensus.channel "$(require_prop consensus)"
  emit aeron.cluster.log.channel "$(require_prop log)"
  emit aeron.cluster.replication.channel "$(require_prop replication)"
  emit_if_set aeron.cluster.catchup.channel "$(cell_prop catchup)"
  emit aeron.cluster.control.channel "$(require_prop control)"
  emit aeron.cluster.service.count "$(cell_prop service_count 1)"
  emit aeron.cluster.service.id "$(cell_prop service_id 0)"
  emit aeron.cluster.file.sync.level "$(cell_prop sync_cluster 0)"
  emit aeron.cluster.idle.strategy "$(cell_prop idle_strategy spin)"
  emit aeron.cluster.cycle.threshold 1ms
  emit aeron.cluster.service.cycle.threshold 1ms
  emit_if_set aeron.cluster.session.timeout "$(cell_prop session_timeout)"

  emit aeron.archive.dir "${archive_dir}"
  emit aeron.archive.dir.delete.on.start true
  emit aeron.archive.mark.file.dir "${aeron_dir}"
  emit aeron.archive.control.channel "$(require_prop archive_control)"
  emit aeron.archive.replication.channel "$(require_prop archive_replication)"
  emit aeron.archive.local.control.channel "$(require_prop local_archive_control)"
  emit aeron.archive.control.stream.id "$(cell_prop archive_control_stream_id 110)"
  emit aeron.archive.control.response.stream.id "$(cell_prop archive_control_response_stream_id 120)"
  emit aeron.archive.local.control.stream.id "$(cell_prop archive_local_control_stream_id 110)"
  emit aeron.archive.id "$(cell_prop archive_id 23)"
  emit aeron.archive.file.sync.level "$(require_prop sync_archive)"
  emit aeron.archive.catalog.file.sync.level "$(require_prop sync_archive)"
  emit aeron.archive.recording.events.enabled false
  emit aeron.archive.threading.mode DEDICATED
  emit aeron.archive.control.term.buffer.sparse true
  emit aeron.archive.file.io.max.length 1m
  emit aeron.archive.idle.strategy spin
  emit aeron.archive.recorder.idle.strategy noop
  emit aeron.archive.replayer.idle.strategy noop
  emit aeron.archive.conductor.cycle.threshold 1ms
  emit aeron.archive.recorder.cycle.threshold 1ms
  emit aeron.archive.replayer.cycle.threshold 1ms
  emit_if_set aeron.archive.conductor.cpu.affinity "$(cell_prop archive_conductor_cpu)"
  emit_if_set aeron.archive.recorder.cpu.affinity "$(cell_prop archive_recorder_cpu)"
  emit_if_set aeron.archive.replayer.cpu.affinity "$(cell_prop archive_replayer_cpu)"

  # The embedded driver. The harness writes the per-cell driver values into
  # `benchmark.properties` (the same file the external Java driver reads), so
  # start from those and add the keys that file does not carry. This is what
  # keeps `aeron.mtu.length`, the socket buffers and the vector capacities
  # identical across arms even when an AERON_* environment override is set.
  local benchmark_properties
  benchmark_properties=$(cell_prop driver_properties_file)
  if [[ -n "${benchmark_properties}" && -f "${benchmark_properties}" ]]
  then
    local line
    while IFS= read -r line
    do
      case "${line}" in
        ''|'#'*) continue ;;
        aeron.dir=*) continue ;;   # the cell's directory is the authority
      esac
      emit "${line%%=*}" "${line#*=}"
    done <"${benchmark_properties}"
  fi
  emit aeron.threading.mode DEDICATED
  emit aeron.conductor.idle.strategy spin
  emit aeron.sender.idle.strategy noop
  emit aeron.receiver.idle.strategy noop
  emit aeron.driver.conductor.cycle.threshold 1ms
  emit aeron.driver.sender.cycle.threshold 1ms
  emit aeron.driver.receiver.cycle.threshold 1ms
  emit aeron.term.buffer.sparse.file true
  emit aeron.pre.touch.mapped.memory false
  emit aeron.perform.storage.checks false
  emit aeron.driver.timeout 30000
  emit aeron.file.page.size 4k
  emit aeron.mtu.length "$(require_prop mtu)"
  emit aeron.ipc.mtu.length "$(require_prop mtu)"
  emit aeron.socket.so_sndbuf 2m
  emit aeron.socket.so_rcvbuf 2m
  emit aeron.rcv.initial.window.length 2m
  emit aeron.network.publication.max.messages.per.send 2
  emit aeron.receiver.io.vector.capacity 2
  emit aeron.sender.io.vector.capacity 2
  emit_if_set aeron.conductor.cpu.affinity "$(cell_prop driver_conductor_cpu)"
  emit_if_set aeron.sender.cpu.affinity "$(cell_prop driver_sender_cpu)"
  emit_if_set aeron.receiver.cpu.affinity "$(cell_prop driver_receiver_cpu)"
}

container_defines()
{
  emit aeron.dir "$(require_prop aeron_dir)"
  emit aeron.cluster.dir "$(require_prop cluster_dir)"
  emit aeron.cluster.id "$(require_prop cluster_id)"
  emit aeron.cluster.service.id "$(cell_prop service_id 0)"
  emit deepmsg.cluster.service "$(cell_prop service echo)"
  emit aeron.cluster.control.channel "$(require_prop control)"
  emit aeron.archive.local.control.channel "$(require_prop local_archive_control)"
  emit aeron.archive.local.control.stream.id "$(cell_prop archive_local_control_stream_id 110)"
  emit aeron.cluster.idle.strategy "$(cell_prop idle_strategy spin)"
  emit aeron.cluster.service.cycle.threshold 1ms
}

case "${mode}" in
  node) node_defines ;;
  container) container_defines ;;
  *) die "unknown translate mode '${mode}'" ;;
esac
