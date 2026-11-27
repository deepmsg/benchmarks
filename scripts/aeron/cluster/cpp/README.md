# C++ cluster arm

Main arm: **two processes per member**, the same count as the Java reference
(external driver + JVM):

- `deepmsg-cluster-node --embedded-driver` — embedded media driver + archive +
  consensus module;
- `deepmsg-clustered-service-container` — the echo service.

`driver_mode=external` runs the aggregate node against a media driver the
harness started (P4b `c-j`); the launcher then waits for that driver's
`cnc.dat` and never starts or stops it. The four-process split (driver +
archive + CM + container) is P4c and is **not** implemented here: it is a
health check, not the main arm.

## Binaries

Read from `cell.properties`, written by the harness from the controller's
environment:

| key | environment variable | binary |
|---|---|---|
| `cpp_cluster_node` | `DEEPMSG_CPP_CLUSTER_NODE` | `deepmsg-cluster-node` |
| `cpp_container` | `DEEPMSG_CPP_CLUSTER_CONTAINER` | `deepmsg-clustered-service-container` |
| `cnc_dump` | `DEEPMSG_CNC_DUMP` | `cnc-dump` |

Binaries are deployed outside the repository. Every batch must pin the commit
they were built from: C++ `main`'s squash commit and the
`feat/aeron-1.54.2-baseline` HEAD are different hashes (plan §3.1).

## Threads and pins

Per member: driver 3 (embedded), archive 3, CM 1, container 1. The driver's
three agents are pinned by `aeron.{conductor,sender,receiver}.cpu.affinity`;
the archive's by `aeron.archive.{conductor,recorder,replayer}.cpu.affinity`.
The CM and the container are pinned by the launcher with `taskset` (the
cluster's `*.cpu.affinity` properties are accepted and ignored by this build).
The launcher also reads back the archive/CM thread affinities and warns when a
pin did not land: a silently failed pin is worse than no pin.

## Config notes

- `aeron.cluster.file.sync.level` comes from `sync_cluster`, whose default is
  **0** — the reference's `ConsensusModule.FILE_SYNC_LEVEL_DEFAULT`. The
  harness's `--file-sync-level` is the **archive's** level (`sync_archive`).
  Copying one into the other would make the arms differ.
- `aeron.cluster.idle.strategy` is `spin` (the Java arm spells it `noop`; both
  mean "never back off"). Write the string difference in the fingerprint.
- The translation table is `translate.sh`; the values come from
  `cell.properties` and the harness's `scripts/aeron/benchmark.properties`.
  `translate.sh` may choose spelling, never a value.

## Known traps

- External driver mode is the least-tested C++ shape (XC-2 runs are all
  embedded), and the Carbon review found the external path missing
  `load_environment` for `DEEPMSG_*`. Treat P4b as a diagnostic, not a main arm.
- The node's `-D` arguments and `--embedded-driver` are order-independent; the
  launcher puts `-D` first to match the media-driver wrapper.
- The launcher owns its PIDs; the harness does not use `pgrep -x` for this arm,
  so the 15-character comm limit only matters for manual `pgrep`/`top`.
