# Java arm — the harness's own path, deliberately not a launcher

The Java arm is the control (`ref`). It must stay **the code that was measured**
on 2026-11-26 (P3a, `analysis/integrate-test/p3a-2026-11-26/`), so A′ keeps it
inline in `remote-cluster-benchmarks`:

- `start_cluster_node()` with `impl=java` emits exactly the command it emitted
  before the seam existed: `run-java io.aeron.benchmarks.aeron.ClusterNode`,
  `JVM_OPTS`, `PROCESS_FILE_NAME`, `numactl`, and the four Java thread pins.
- `stop_cluster_node_command()` with `impl=java` emits exactly the old
  `kill_java_process`/`stop_java_process` + `stop_media_driver` chain.
- `--server-impl java` is the default; `scripts/aeron/cluster-node` and
  `scripts/aeron/media-driver` are untouched.

There is intentionally **no `java/launch.sh`**. A launcher here would have to
reproduce the JVM_OPTS and the Java thread-name pins, which is a second copy of
the control arm and exactly the drift the A/A gate exists to catch. If the Java
path is ever moved behind the four verbs, do it as a separate change with:

1. a one-line wrapper at the old path,
2. the A/A cell in the same session (old path vs `--server-impl java`),
3. the A/A result in the RUN-INFO before any C++/Rust reading is accepted.

Until then: `--server-impl java` is the reference, and any difference between
it and the pre-seam script invalidates the batch (plan §2.6 A′-7).
