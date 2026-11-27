# Rust cluster arm

**Four processes per member**: `deepmsg-driver`, `deepmsg-archive`,
`deepmsg-cluster-node` (the consensus module) and
`deepmsg-clustered-service-container`.

The split is a **threading-model requirement**, not a performance claim. The
combined `deepmsg-archiving-media-driver` runs the driver and archive on one
thread and accepts only `SHARED`/`INVOKER` (measured, 2026-11-04:
`analysis/deepbook/readings-2026-11-04-s1.md:63`). The Java reference runs
`DEDICATED` with three pinned driver agents. Splitting the processes lets the
Rust arm run the same threading model; whether the split is also faster was
never established (the 2026-11-08 split T1 and its paired SHARED control were
not run).

## Binaries

| key | environment variable | binary |
|---|---|---|
| `rust_driver` | `DEEPMSG_RUST_DRIVER` | `deepmsg-driver` |
| `rust_archive` | `DEEPMSG_RUST_ARCHIVE` | `deepmsg-archive` |
| `rust_cluster_node` | `DEEPMSG_RUST_CLUSTER_NODE` | `deepmsg-cluster-node` (CM) |
| `rust_container` | `DEEPMSG_RUST_CONTAINER` | `deepmsg-clustered-service-container` |
| `cnc_dump` | `DEEPMSG_CNC_DUMP` | `cnc-dump` |

★ `deepmsg-cluster-node` is the **consensus module** here. The C++ binary of
the same name is the archive+CM aggregate. Do not point one arm at the other's
binary; the launcher compares the `impl` key with its own directory and refuses
a mismatch.

## Threads and pins

- Driver: three agents pinned by `aeron.{conductor,sender,receiver}.cpu.affinity`
  in `driver.properties`.
- Archive: this build has no `aeron.archive.*.cpu.affinity`; the launcher pins
  the process with `taskset` over the three archive cores (or `archive_cpuset`
  when the env sets one). Owner: `archive_cpuset` > the three cores.
- CM and container: one agent each; pinned with `taskset`.

## Driver properties

`launch.sh` builds `cell_dir/driver.properties` by concatenating the harness's
per-cell `scripts/aeron/benchmark.properties` with the launcher's
`translate.sh driver` output. The file is then the driver's single argument.
The harness writes `benchmark.properties` for every arm, including this one, so
the two arms get the same `mtu`, buffers and affinity values.

## Config notes

- `aeron.cluster.file.sync.level` comes from `sync_cluster` (default **0**, the
  reference's `ConsensusModule.FILE_SYNC_LEVEL_DEFAULT`). The harness's
  `--file-sync-level` sets the **archive** level (`sync_archive`). Do not copy
  one into the other.
- Archive readiness is `aeron_dir/archive-mark.dat` larger than its 8192-byte
  header; a live process is not enough.

## Known traps

- Do not run the combined archiving driver for this arm: `DEDICATED` makes it
  fail at startup by design.
- `deepmsg-driver`'s stderr is a contract (empty on the happy path); the
  launcher redirects it to `driver.log`, never to a terminal.
- The four-process count differs from the Java reference's two; that is
  recorded in the fingerprint and is part of what the full-stack ratio contains.
