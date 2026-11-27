#!/usr/bin/env bash
##
## Self-test for the A′ launcher skeleton (2026-11-27).
##
##   scripts/aeron/cluster/selftest.sh
##
## Runs without a cluster, a Java jar or any deepmsg binary. It checks:
##   - every shell file parses;
##   - the C++/Rust translations carry the required keys and no empty value;
##   - preflight rejects the untouched template and accepts a filled one;
##   - the four verbs work against stub binaries (start/check/stop), so a
##     launcher cannot pass by never having been run.
##
## It is a plumbing check, not a reading: no cell in this file produces a
## number that belongs in a report.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
tmp="$(mktemp -d)"
cleanup()
{
  if [[ -f "${tmp}/cpp-cell/pids" ]]
  then
    "${ROOT}/cpp/launch.sh" stop "${tmp}/cpp-cell" >/dev/null 2>&1 || true
  fi
  if [[ -f "${tmp}/rust-cell/pids" ]]
  then
    "${ROOT}/rust/launch.sh" stop "${tmp}/rust-cell" >/dev/null 2>&1 || true
  fi
  rm -rf "${tmp}"
}
trap cleanup EXIT

fail()
{
  echo "SELFTEST FAILED: $*" >&2
  exit 1
}

pass()
{
  echo "ok: $*"
}

echo "== syntax"
while IFS= read -r file
do
  bash -n "${file}" || fail "syntax: ${file}"
done < <(find "${ROOT}" -name '*.sh' -o -name 'remote-cluster-benchmarks')
pass "all shell files parse"

# ---- stubs ----------------------------------------------------------------
mkdir -p "${tmp}/bin"
cat >"${tmp}/bin/sleeper" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "${tmp}/bin/sleeper"
cp "${tmp}/bin/sleeper" "${tmp}/bin/cpp-container"
cp "${tmp}/bin/sleeper" "${tmp}/bin/rust-container"
cat >"${tmp}/bin/cluster-node-stub" <<'EOF'
#!/usr/bin/env bash
# The CM writes cluster-mark.dat; the launcher waits for it before the
# container starts.
dir=""
for a in "$@"; do
  case "$a" in
    -Daeron.cluster.dir=*) dir=${a#-Daeron.cluster.dir=} ;;
  esac
done
if [[ -n "$dir" ]]; then
  mkdir -p "$dir"
  : >"$dir/cluster-mark.dat"
fi
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "${tmp}/bin/cluster-node-stub"
cp "${tmp}/bin/cluster-node-stub" "${tmp}/bin/cpp-node"
cp "${tmp}/bin/cluster-node-stub" "${tmp}/bin/rust-cm"
cat >"${tmp}/bin/cpp-cnc-dump" <<'EOF'
#!/usr/bin/env bash
echo "0 loss entries"
EOF
chmod +x "${tmp}/bin/cpp-cnc-dump"
cp "${tmp}/bin/cpp-cnc-dump" "${tmp}/bin/rust-cnc-dump"
cat >"${tmp}/bin/rust-driver" <<'EOF'
#!/usr/bin/env bash
# deepmsg-driver takes the reference aeronmd's shape — `-Dname=value`, no
# properties file (crates/driver/src/config.rs, `from_args`). A positional
# argument is the bug this stub exists to keep out: the launcher once handed
# it driver.properties and the driver exited before making the CnC.
dir=""
for a in "$@"; do
  case "$a" in
    -Daeron.dir=*) dir=${a#-Daeron.dir=} ;;
    -*) ;;
    *) echo "rust-driver: unexpected positional argument '$a'" >&2; exit 2 ;;
  esac
done
[[ -n "$dir" ]] && mkdir -p "$dir" && : >"$dir/cnc.dat"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "${tmp}/bin/rust-driver"
cat >"${tmp}/bin/rust-archive" <<'EOF'
#!/usr/bin/env bash
dir=""
for a in "$@"; do
  case "$a" in
    -Daeron.dir=*) dir=${a#-Daeron.dir=} ;;
  esac
done
if [[ -n "$dir" ]]; then
  mkdir -p "$dir"
  head -c 9000 /dev/zero >"$dir/archive-mark.dat"
fi
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "${tmp}/bin/rust-archive"

# ---- a cell ---------------------------------------------------------------
make_cell()
{
  local dir=${1} impl=${2} mode=${3}
  mkdir -p "${dir}"
  cat >"${dir}/cell.properties" <<EOF
impl=${impl}
driver_mode=${mode}
benchmarks_path=${tmp}
output_dir=results
member_id=0
cluster_id=0
members=0,127.0.0.1:20000,127.0.0.1:20001,127.0.0.1:20002,127.0.0.1:20003,127.0.0.1:20004
appointed_leader=0
aeron_dir=${dir}/aeron
cluster_dir=${dir}/cluster
archive_dir=${dir}/archive
ingress=aeron:udp?interface=127.0.0.1
consensus=aeron:udp?term-length=64k|interface=127.0.0.1
log=aeron:udp?term-length=64m|control-mode=manual|control=127.0.0.1:20002|interface=127.0.0.1
replication=aeron:udp?endpoint=127.0.0.1:0|interface=127.0.0.1
catchup=
archive_control=aeron:udp?endpoint=127.0.0.1:8010|interface=127.0.0.1
archive_replication=aeron:udp?endpoint=127.0.0.1:0|interface=127.0.0.1
local_archive_control=aeron:ipc?term-length=64k
archive_control_stream_id=110
archive_control_response_stream_id=120
archive_local_control_stream_id=110
archive_id=23
control=aeron:ipc
service=echo
service_count=1
service_id=0
sync_archive=0
sync_cluster=0
mtu=1408
idle_strategy=spin
session_timeout=
driver_properties_file=${tmp}/benchmark.properties
driver_conductor_cpu=0
driver_sender_cpu=1
driver_receiver_cpu=2
archive_conductor_cpu=3
archive_recorder_cpu=4
archive_replayer_cpu=5
cm_cpu=6
container_cpu=7
pin_attempts_cm=10
non_isolated_cpu_cores=0-7
driver_cpuset=
archive_cpuset=
cpp_cluster_node=${tmp}/bin/cpp-node
cpp_container=${tmp}/bin/cpp-container
cpp_archive=
cpp_cm=
cpp_driver=
rust_driver=${tmp}/bin/rust-driver
rust_archive=${tmp}/bin/rust-archive
rust_cluster_node=${tmp}/bin/rust-cm
rust_container=${tmp}/bin/rust-container
cnc_dump=${tmp}/bin/${impl}-cnc-dump
EOF
}

make_cell "${tmp}/cpp-cell" cpp external
make_cell "${tmp}/rust-cell" rust embedded
cat >"${tmp}/benchmark.properties" <<EOF
aeron.dir=${tmp}/rust-cell/aeron
aeron.mtu.length=1408
aeron.ipc.mtu.length=1408
aeron.conductor.cpu.affinity=0
aeron.sender.cpu.affinity=1
aeron.receiver.cpu.affinity=2
EOF

# ---- translation ----------------------------------------------------------
echo "== translation"
cpp_node=$("${ROOT}/cpp/translate.sh" node "${tmp}/cpp-cell")
grep -qx -- '-Daeron.cluster.id=0' <<<"${cpp_node}" || fail "cpp node: no cluster id"
grep -qx -- '-Daeron.cluster.file.sync.level=0' <<<"${cpp_node}" || fail "cpp node: cluster sync must default to 0"
grep -qx -- '-Daeron.archive.file.sync.level=0' <<<"${cpp_node}" || fail "cpp node: archive sync"
grep -qx -- '-Daeron.cluster.members=0,127.0.0.1:20000,127.0.0.1:20001,127.0.0.1:20002,127.0.0.1:20003,127.0.0.1:20004' <<<"${cpp_node}" || fail "cpp node: members"
grep -qx -- '-Daeron.cluster.ingress.channel=aeron:udp?interface=127.0.0.1|endpoint=127.0.0.1:20000' <<<"${cpp_node}" || fail "cpp node: ingress endpoint not appended"
if grep -q -- '-D.*=$' <<<"${cpp_node}"
then
  fail "cpp node: an empty -D value"
fi
cpp_container=$("${ROOT}/cpp/translate.sh" container "${tmp}/cpp-cell")
grep -qx -- '-Ddeepmsg.cluster.service=echo' <<<"${cpp_container}" || fail "cpp container: service"
rust_node=$("${ROOT}/rust/translate.sh" node "${tmp}/rust-cell")
grep -qx -- '-Daeron.cluster.file.sync.level=0' <<<"${rust_node}" || fail "rust node: cluster sync"
# The member reaches its own archive over the *local* control stream; with the
# built-in default (10) a member never connects to an archive started on this
# cell's 110 (2026-11-27: `cluster: connect timeout`).
grep -qx -- '-Daeron.archive.local.control.stream.id=110' <<<"${rust_node}" || fail "rust node: archive local control stream"
grep -qx -- '-Daeron.archive.local.control.channel=aeron:ipc?term-length=64k' <<<"${rust_node}" || fail "rust node: archive local control channel"
rust_driver=$("${ROOT}/rust/translate.sh" driver "${tmp}/rust-cell")
grep -qx 'aeron.threading.mode=DEDICATED' <<<"${rust_driver}" || fail "rust driver: DEDICATED"
pass "translations"

# ---- cell directory -------------------------------------------------------
echo "== cell directory"
extract_function()
{
  awk "/^function $1\\(\\)/{f=1} f{print} f&&/^}/{exit}" "${ROOT}/../remote-cluster-benchmarks"
}
eval "$(extract_function cluster_cell_dir)"
NODE0_BENCHMARKS_PATH=/x
[[ "$(cluster_cell_dir 0 scripts/results/t)" == "/x/scripts/results/t/node-0" ]] || \
  fail "relative output_dir must resolve under the benchmarks path"
[[ "$(cluster_cell_dir 0 /x/scripts/results/t)" == "/x/scripts/results/t/node-0" ]] || \
  fail "absolute output_dir must not be prefixed again"
pass "start and stop name the same cell"

# ---- preflight ------------------------------------------------------------
echo "== preflight"
if "${ROOT}/common/preflight-env.sh" "${ROOT}/../../../environments/c6.env.example" >/dev/null 2>&1
then
  fail "preflight accepted the untouched template"
fi
filled="${tmp}/filled.env"
sed -e 's/REPLACE_ME_NODE0_DATA/10.42.0.58/g' \
  -e 's/REPLACE_ME_NODE1_DATA/10.42.0.59/g' \
  -e 's/REPLACE_ME_NODE2_DATA/10.42.0.60/g' \
  -e 's/REPLACE_ME_CLIENT_DATA/10.42.0.61/g' \
  -e 's/REPLACE_ME_NODE0_MGMT/10.0.1.10/g' \
  -e 's/REPLACE_ME_NODE1_MGMT/10.0.1.11/g' \
  -e 's/REPLACE_ME_NODE2_MGMT/10.0.1.12/g' \
  -e 's/REPLACE_ME_CLIENT_MGMT/10.0.1.13/g' \
  -e 's#REPLACE_ME\.pem#aliyun-cluster.pem#g' \
  -e 's/REPLACE_ME-results/results/g' \
  -e 's/REPLACE_ME_DEEPMSG_CPP_CLUSTER_NODE/\/tmp\/cpp-node/g' \
  -e 's/REPLACE_ME_DEEPMSG_CPP_CLUSTER_CONTAINER/\/tmp\/cpp-container/g' \
  -e 's/REPLACE_ME_DEEPMSG_RUST_DRIVER/\/tmp\/rust-driver/g' \
  -e 's/REPLACE_ME_DEEPMSG_RUST_ARCHIVE/\/tmp\/rust-archive/g' \
  -e 's/REPLACE_ME_DEEPMSG_RUST_CLUSTER_NODE/\/tmp\/rust-cm/g' \
  -e 's/REPLACE_ME_DEEPMSG_RUST_CONTAINER/\/tmp\/rust-container/g' \
  -e 's/REPLACE_ME_CNC_DUMP/\/tmp\/cnc-dump/g' \
  "${ROOT}/../../../environments/c6.env.example" >"${filled}"
"${ROOT}/common/preflight-env.sh" "${filled}" >/dev/null || fail "preflight rejected a filled env"
pass "preflight"

# ---- lifecycle ------------------------------------------------------------
echo "== lifecycle (stubs)"
# The stubs have no named agent threads; keep the pin wait short so the test
# checks the verbs rather than spending ten seconds per absent thread.
export PIN_ATTEMPTS=10
# The launchers drop the page cache before a cell, the way the Java arm is
# started. A stub cell is not a measurement, and dropping the developer's page
# cache on every selftest run is rude, so this run turns it off.
export DEEPMSG_CACHE_DROP=0
mkdir -p "${tmp}/cpp-cell/aeron"
: >"${tmp}/cpp-cell/aeron/cnc.dat"
"${ROOT}/cpp/launch.sh" start "${tmp}/cpp-cell" >/dev/null
"${ROOT}/cpp/launch.sh" check "${tmp}/cpp-cell" || fail "cpp check after start"
"${ROOT}/cpp/launch.sh" stop "${tmp}/cpp-cell" >/dev/null
[[ -s "${tmp}/cpp-cell/counters.txt" ]] || fail "cpp counters not written"
if "${ROOT}/cpp/launch.sh" check "${tmp}/cpp-cell" >/dev/null 2>&1
then
  fail "cpp check still green after stop"
fi
pass "cpp start/check/stop"

"${ROOT}/rust/launch.sh" start "${tmp}/rust-cell" >/dev/null
"${ROOT}/rust/launch.sh" check "${tmp}/rust-cell" || fail "rust check after start"
"${ROOT}/rust/launch.sh" stop "${tmp}/rust-cell" >/dev/null
[[ -s "${tmp}/rust-cell/counters.txt" ]] || fail "rust counters not written"
if "${ROOT}/rust/launch.sh" check "${tmp}/rust-cell" >/dev/null 2>&1
then
  fail "rust check still green after stop"
fi
pass "rust start/check/stop"

# ---- handshake ------------------------------------------------------------
echo "== handshake"
mkdir -p "${tmp}/fake-java/bin" "${tmp}/benchmarks-all/build/libs"
: >"${tmp}/benchmarks-all/build/libs/benchmarks.jar"
cat >"${tmp}/fake-java/bin/javap" <<'EOF'
#!/usr/bin/env bash
cat <<'CONST'
  public static final java.lang.String VERSION = "1.54.2";
  public static final java.lang.String GIT_SHA = "selftest";
CONST
EOF
chmod +x "${tmp}/fake-java/bin/javap"
SERVER_IMPL=java CLIENT_BENCHMARKS_PATH="${tmp}" CLIENT_JAVA_HOME="${tmp}/fake-java" \
  EXPECT_JAVA_VERSION=1.54.2 "${ROOT}/common/version-handshake.sh" >/dev/null || \
  fail "handshake failed for the Java arm"
if SERVER_IMPL=java CLIENT_BENCHMARKS_PATH="${tmp}" CLIENT_JAVA_HOME="${tmp}/fake-java" \
  EXPECT_JAVA_VERSION=9.9.9 "${ROOT}/common/version-handshake.sh" >/dev/null 2>&1
then
  fail "handshake accepted a version mismatch"
fi
pass "handshake (accept + mismatch)"

echo "selftest: ok"
