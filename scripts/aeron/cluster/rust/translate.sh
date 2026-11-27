#!/usr/bin/env bash
##
## Rust property translation: cell.properties -> `-D` (or key=value for the
## driver's properties file).
##
##   translate.sh node|archive|container|driver <cell_dir>
##
## The arm is four processes: `deepmsg-driver`, `deepmsg-archive`,
## `deepmsg-cluster-node` (the consensus module) and
## `deepmsg-clustered-service-container`. The split is what lets the driver
## run DEDICATED, the same threading model as the Java reference; the combined
## archiving driver accepts only SHARED/INVOKER.
##
## ★ `aeron.cluster.file.sync.level` is the cluster's own default (0 in the
## reference), not the harness's archive `--file-sync-level`.

set -euo pipefail

mode=${1:?usage: translate.sh node|archive|container|driver <cell_dir>}
CELL_DIR=${2:?usage: translate.sh node|archive|container|driver <cell_dir>}
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

node_defines()
{
  emit aeron.dir "$(require_prop aeron_dir)"
  emit aeron.cluster.dir "$(require_prop cluster_dir)"
  emit aeron.cluster.id "$(require_prop cluster_id)"
  emit aeron.cluster.member.id "$(require_prop member_id)"
  emit aeron.cluster.members "$(require_prop members)"
  local leader
  leader=$(cell_prop appointed_leader -1)
  if [[ "${leader}" =~ ^[0-9]+$ ]]
  then
    emit aeron.cluster.appointed.leader.id "${leader}"
  fi
  emit aeron.cluster.ingress.channel "$(require_prop ingress)"
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
}

archive_defines()
{
  emit aeron.dir "$(require_prop aeron_dir)"
  emit aeron.archive.dir "$(require_prop archive_dir)"
  emit aeron.archive.dir.delete.on.start true
  emit aeron.archive.mark.file.dir "$(require_prop aeron_dir)"
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
  # This build's archive does not read `aeron.archive.*.cpu.affinity`; the
  # launcher pins the archive process with taskset (archive_cpuset).
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

# key=value for the driver's properties file; the launcher prepends the
# harness's benchmark.properties (the per-cell driver values).
driver_properties()
{
  emit_key()
  {
    printf '%s=%s\n' "$1" "$2"
  }
  emit_key_if_set()
  {
    [[ -n "${2}" ]] && emit_key "$1" "$2" || true
  }
  emit_key aeron.dir "$(require_prop aeron_dir)"
  emit_key aeron.threading.mode DEDICATED
  emit_key aeron.conductor.idle.strategy spin
  emit_key aeron.sender.idle.strategy noop
  emit_key aeron.receiver.idle.strategy noop
  emit_key aeron.driver.conductor.cycle.threshold 1ms
  emit_key aeron.driver.sender.cycle.threshold 1ms
  emit_key aeron.driver.receiver.cycle.threshold 1ms
  emit_key aeron.driver.timeout 30000
  emit_key aeron.term.buffer.sparse.file true
  emit_key aeron.pre.touch.mapped.memory false
  emit_key aeron.perform.storage.checks false
  emit_key aeron.file.page.size 4k
  emit_key aeron.mtu.length "$(require_prop mtu)"
  emit_key aeron.ipc.mtu.length "$(require_prop mtu)"
  emit_key aeron.socket.so_sndbuf 2m
  emit_key aeron.socket.so_rcvbuf 2m
  emit_key aeron.rcv.initial.window.length 2m
  emit_key aeron.network.publication.max.messages.per.send 2
  emit_key aeron.receiver.io.vector.capacity 2
  emit_key aeron.sender.io.vector.capacity 2
  emit_key_if_set aeron.conductor.cpu.affinity "$(cell_prop driver_conductor_cpu)"
  emit_key_if_set aeron.sender.cpu.affinity "$(cell_prop driver_sender_cpu)"
  emit_key_if_set aeron.receiver.cpu.affinity "$(cell_prop driver_receiver_cpu)"
}

case "${mode}" in
  node) node_defines ;;
  archive) archive_defines ;;
  container) container_defines ;;
  driver) driver_properties ;;
  *) die "unknown translate mode '${mode}'" ;;
esac
