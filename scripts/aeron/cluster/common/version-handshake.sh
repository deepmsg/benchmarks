#!/usr/bin/env bash
##
## Version handshake for the cluster batch (A′, 2026-11-27).
##
##   version-handshake.sh [env-file]
##
## Prints the fingerprints a RUN-INFO must carry, and compares them with
## EXPECT_* when those are set. It only reads; it never starts a process.
##
##   EXPECT_JAVA_VERSION=1.54.2
##   EXPECT_CLUSTER_VERSION=1.54.2
##   EXPECT_HARNESS_SHA256=<sha256 of benchmarks.jar>
##   EXPECT_CPP_SHA256=<sha256 of deepmsg-cluster-node>
##   EXPECT_RUST_SHA256=<sha256 of deepmsg-driver>
##
## The Java 1.54.2 jar is identified by `AeronVersion.VERSION` and
## `AeronVersion.GIT_SHA`; C++/Rust by sha256 and, when the binary supports it,
## `--version`. A mismatch is a hard failure: a cell run across versions is not
## a reading (plan §3.2).

set -euo pipefail

env_file=${1:-}
if [[ -n "${env_file}" ]]
then
  [[ -f "${env_file}" ]] || { echo "handshake: no ${env_file}" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "${env_file}"
fi

fail=0
want()
{
  local name=${1}
  local expected=${2:-}
  local actual=${3:-}
  if [[ -n "${expected}" && "${expected}" != "${actual}" ]]
  then
    echo "MISMATCH ${name}: expected '${expected}', got '${actual}'" >&2
    fail=1
  else
    printf '%-24s %s\n' "${name}" "${actual:-<not set>}"
  fi
}

sha256_of()
{
  local path=${1}
  if [[ -n "${path}" && -f "${path}" ]]
  then
    sha256sum "${path}" | awk '{print $1}'
  else
    printf '<missing:%s>' "${path}"
  fi
}

show()
{
  printf '%-24s %s\n' "${1}" "${2:-<not set>}"
}

require_file()
{
  local what=${1}
  local path=${2}
  if [[ -z "${path}" || ! -f "${path}" ]]
  then
    echo "MISSING ${what}: '${path}'" >&2
    fail=1
  fi
}

java_version()
{
  local java_home=${1}
  local jar=${2}
  if [[ -z "${java_home}" || ! -x "${java_home}/bin/javap" || ! -f "${jar}" ]]
  then
    printf '<missing:%s or %s>' "${java_home}/bin/javap" "${jar}"
    return
  fi
  "${java_home}/bin/javap" -classpath "${jar}" -constants io.aeron.AeronVersion 2>/dev/null |
    sed -nE 's/.*String (VERSION|GIT_SHA) = "([^"]*)".*/\1=\2/p' |
    tr '\n' ' '
}

java_version_only()
{
  java_version "$@" | sed -nE 's/.*VERSION=([^ ]+).*/\1/p'
}

java_git_sha()
{
  java_version "$@" | sed -nE 's/.*GIT_SHA=([^ ]+).*/\1/p'
}

binary_version()
{
  local path=${1}
  if [[ -n "${path}" && -x "${path}" ]]
  then
    if "${path}" --version >/dev/null 2>&1
    then
      "${path}" --version 2>&1 | head -1
    else
      printf '<no --version>'
    fi
  else
    printf '<missing:%s>' "${path}"
  fi
}

jar="${CLIENT_BENCHMARKS_PATH:-}/benchmarks-all/build/libs/benchmarks.jar"
require_file "java.javap" "${CLIENT_JAVA_HOME:-}/bin/javap"
require_file "harness.jar" "${jar}"
case "${SERVER_IMPL:-java}" in
  java) ;;
  cpp)
    require_file "cpp.cluster_node" "${DEEPMSG_CPP_CLUSTER_NODE:-}"
    require_file "cpp.container" "${DEEPMSG_CPP_CLUSTER_CONTAINER:-}"
    require_file "cnc_dump" "${DEEPMSG_CNC_DUMP:-}"
    ;;
  rust)
    require_file "rust.driver" "${DEEPMSG_RUST_DRIVER:-}"
    require_file "rust.archive" "${DEEPMSG_RUST_ARCHIVE:-}"
    require_file "rust.cluster_node" "${DEEPMSG_RUST_CLUSTER_NODE:-}"
    require_file "rust.container" "${DEEPMSG_RUST_CONTAINER:-}"
    require_file "cnc_dump" "${DEEPMSG_CNC_DUMP:-}"
    ;;
esac
want "java" "${EXPECT_JAVA_VERSION:-}" "$(java_version_only "${CLIENT_JAVA_HOME:-}" "${jar}")"
show "java.git_sha" "$(java_git_sha "${CLIENT_JAVA_HOME:-}" "${jar}")"
want "harness.jar.sha256" "${EXPECT_HARNESS_SHA256:-}" "$(sha256_of "${jar}")"

case "${SERVER_IMPL:-java}" in
  cpp)
    want "cpp.sha256" "${EXPECT_CPP_SHA256:-}" "$(sha256_of "${DEEPMSG_CPP_CLUSTER_NODE:-}")"
    show "cpp.binary" "$(binary_version "${DEEPMSG_CPP_CLUSTER_NODE:-}")"
    ;;
  rust)
    want "rust.sha256" "${EXPECT_RUST_SHA256:-}" "$(sha256_of "${DEEPMSG_RUST_DRIVER:-}")"
    show "rust.binary" "$(binary_version "${DEEPMSG_RUST_DRIVER:-}")"
    ;;
  java) ;;
  *)
    echo "handshake: SERVER_IMPL='${SERVER_IMPL}' is not java|cpp|rust" >&2
    fail=1
    ;;
esac

if (( fail != 0 ))
then
  exit 1
fi
echo "handshake: ok"
