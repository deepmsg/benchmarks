#!/usr/bin/env bash
##
## Preflight for `environments/c6.env` (A′, 2026-11-27).
##
##   preflight-env.sh <env-file>
##
## Refuses a template that was never filled in, a missing core/channel, and an
## arm whose binary is not named. It does not talk to the machines; it checks
## the file the batch will source.
##
## The real env file is deliberately not in git (`.gitignore` keeps only
## `*.env.example`). This script is the gate that keeps a copied template from
## turning into a batch that starts a member with a REPLACE_ME address.

set -euo pipefail

env_file=${1:?usage: preflight-env.sh <env-file>}
[[ -f "${env_file}" ]] || { echo "preflight: no ${env_file}" >&2; exit 1; }

# A value, not a comment, that still says REPLACE_ME.
if grep -vE '^[[:space:]]*#' "${env_file}" | grep -q 'REPLACE_ME'
then
  echo "preflight: ${env_file} still contains REPLACE_ME values:" >&2
  grep -nE 'REPLACE_ME' "${env_file}" | grep -vE '^[0-9]+:[[:space:]]*#' >&2 || true
  exit 1
fi

# shellcheck disable=SC1090
source "${env_file}"

missing=()
need()
{
  local name=${1}
  if [[ -z "${!name:-}" ]]
  then
    missing+=("${name}")
  fi
}

for name in SSH_USER SSH_KEY_FILE SSH_CLIENT_USER SSH_CLIENT_KEY_FILE \
  SSH_SERVER_USER SSH_SERVER_KEY_FILE SSH_CLIENT_NODE SSH_SERVER_NODE \
  CLUSTER_SIZE CLUSTER_ID CLUSTER_MEMBERS CLUSTER_CONSENSUS_ENDPOINTS \
  CLIENT_BENCHMARKS_PATH CLIENT_JAVA_HOME CLIENT_CPU_NODE \
  CLIENT_DRIVER_CONDUCTOR_CPU_CORE CLIENT_DRIVER_SENDER_CPU_CORE \
  CLIENT_DRIVER_RECEIVER_CPU_CORE CLIENT_LOAD_TEST_RIG_MAIN_CPU_CORE \
  CLIENT_NON_ISOLATED_CPU_CORES CLIENT_INGRESS_CHANNEL \
  CLIENT_INGRESS_ENDPOINTS CLIENT_EGRESS_CHANNEL \
  SERVER_IMPL SERVER_DRIVER_MODE
do
  need "${name}"
done

for ((n = 0; n < ${CLUSTER_SIZE:-0}; n++))
do
  for suffix in BENCHMARKS_PATH JAVA_HOME CPU_NODE \
    DRIVER_CONDUCTOR_CPU_CORE DRIVER_SENDER_CPU_CORE DRIVER_RECEIVER_CPU_CORE \
    ARCHIVE_RECORDER_CPU_CORE ARCHIVE_REPLAYER_CPU_CORE ARCHIVE_CONDUCTOR_CPU_CORE \
    CONSENSUS_MODULE_CPU_CORE CLUSTERED_SERVICE_CPU_CORE NON_ISOLATED_CPU_CORES \
    CLUSTER_DIR ARCHIVE_DIR CLUSTER_CONSENSUS_CHANNEL CLUSTER_INGRESS_CHANNEL \
    CLUSTER_LOG_CHANNEL CLUSTER_REPLICATION_CHANNEL ARCHIVE_CONTROL_CHANNEL \
    ARCHIVE_REPLICATION_CHANNEL
  do
    need "NODE${n}_${suffix}"
  done
  need "SSH_CLUSTER_USER${n}"
  need "SSH_CLUSTER_KEY_FILE${n}"
  need "SSH_CLUSTER_NODE${n}"
done

case "${SERVER_IMPL}" in
  java) ;;
  cpp)
    need DEEPMSG_CPP_CLUSTER_NODE
    need DEEPMSG_CPP_CLUSTER_CONTAINER
    need DEEPMSG_CNC_DUMP
    ;;
  rust)
    need DEEPMSG_RUST_DRIVER
    need DEEPMSG_RUST_ARCHIVE
    need DEEPMSG_RUST_CLUSTER_NODE
    need DEEPMSG_RUST_CONTAINER
    need DEEPMSG_CNC_DUMP
    ;;
  *)
    echo "preflight: SERVER_IMPL='${SERVER_IMPL}' is not java|cpp|rust" >&2
    exit 1
    ;;
esac

if [[ "${SERVER_DRIVER_MODE}" == "embedded" && "${SERVER_IMPL}" == "java" ]]
then
  echo "preflight: embedded driver mode is only for cpp/rust (the Java node attaches to an external driver)" >&2
  exit 1
fi

# `interface=` is resolved with InetAddress.getByName: a bare NIC name is the
# mistake P3a paid for. Check the client/node channels the harness reads.
for name in CLIENT_INGRESS_CHANNEL NODE0_CLUSTER_INGRESS_CHANNEL \
  NODE0_CLUSTER_CONSENSUS_CHANNEL NODE0_CLUSTER_LOG_CHANNEL \
  NODE0_CLUSTER_REPLICATION_CHANNEL
do
  value=${!name:-}
  if [[ "${value}" == *"interface="* ]]
  then
    iface=${value#*interface=}
    iface=${iface%%[|&]*}
    if [[ ! "${iface}" =~ [.:] ]]
    then
      echo "preflight: ${name}: interface='${iface}' looks like a NIC name; use the host's data IP" >&2
      exit 1
    fi
  fi
done

if [[ "${CLIENT_EGRESS_CHANNEL}" == *"interface="* ]]
then
  echo "preflight: CLIENT_EGRESS_CHANNEL must not carry interface= (it is copied into each member's response publication)" >&2
  exit 1
fi

if (( ${#missing[@]} > 0 ))
then
  echo "preflight: missing or empty:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

echo "preflight: ok (impl=${SERVER_IMPL}, driver_mode=${SERVER_DRIVER_MODE}, nodes=${CLUSTER_SIZE}, client=${SSH_CLIENT_NODE})"
