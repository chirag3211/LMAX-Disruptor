# Bounded Lock-Free Queues in OCaml 5

**CS6868 Research Mini-Project · 2026**

Ring-buffer queues in OCaml 5 — from Lamport SPSC to LMAX Disruptor MPSC — with correctness verification via QCheck-STM/Lin and throughput benchmarking across 1–8 threads.

---

## Table of Contents

- [Overview](#overview)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Building](#building)
- [Running Tests](#running-tests)
- [Running Benchmarks](#running-benchmarks)
- [TSAN (Data-Race Detection)](#tsan-data-race-detection)
- [Implementation Summary](#implementation-summary)
- [Key Results](#key-results)
- [References](#references)

---

## Overview

The Michael-Scott queue allocates a fresh heap node on every enqueue. In
high-throughput settings this imposes GC pressure and cold-cache misses that
a pre-allocated ring buffer eliminates entirely. This project implements and
evaluates five bounded ring-buffer queue variants:

| Queue | Producers | Consumers | Claim primitive |
|---|---|---|---|
| `Queue_spsc` | 1 | 1 | Atomic load/store only (no CAS) |
| `Queue_mpmc` | N | N | CAS on both ends (Vyukov 2010) |
| `Queue_mpsc` | N | 1 | CAS on producer, plain store on consumer |
| `Disruptor_pipeline.Int_spsc` | 1 | 1 | FAA sequencer, SPSC barrier |
| `Disruptor_pipeline.Int_mpsc` | N | 1 | FAA sequencer, available-buffer barrier |

Two baselines are included for comparison: the Michael-Scott lock-free queue
(`Lockfree_queue`) and a mutex + condvar bounded queue (`Bounded_queue`).

All implementations pass QCheck-STM sequential and parallel model-checking,
QCheck-Lin linearisability testing, stress tests, and are free of data races
under TSAN.

---

## Repository Structure

```
.
├── lib/                        # All implementations (the library)
│   ├── queue_spsc.ml           # Task 1 – Lamport SPSC (no CAS)
│   ├── queue_mpmc.ml           # Task 2 – Vyukov MPMC (per-slot sequences)
│   ├── queue_mpsc.ml           # Task 3 – Hybrid MPSC (CAS producer, plain consumer)
│   │
│   ├── sequence.ml             # Cache-line-padded atomic counter
│   ├── ring_buffer.ml          # Pre-allocated circular array (Int_rb, Event_rb)
│   ├── wait_strategy.ml        # BusySpin / Yielding / Blocking consumer wait modes
│   ├── sequence_barrier.ml     # Consumer wait/poll logic (SPSC and MP variants)
│   ├── event_processor.ml      # Generic event-handler lifecycle
│   ├── disruptor_sequencer_spsc.ml  # Single-producer FAA sequencer
│   ├── disruptor_sequencer_mpsc.ml  # Multi-producer FAA sequencer + available_buffer
│   ├── disruptor_pipeline.ml   # Top-level API: Int_spsc, Int_mpsc, Event_spsc
│   │
│   ├── lockfree_queue.ml       # Baseline: Michael-Scott unbounded queue
│   ├── bounded_queue.ml        # Baseline: mutex + condvar bounded queue
│   └── dune
│
├── test/
│   ├── test_spsc_smoke.ml      # Basic SPSC sanity check
│   ├── test_spsc_stress.ml     # 1P × 1C × 1M items, order verified
│   ├── test_mpsc_stress.ml     # 4P × 1C × 1M items, multiset verified
│   ├── test_mpmc_stress.ml     # 4P × 4C × 1M items, multiset verified
│   ├── test_stm.ml             # QCheck-STM + QCheck-Lin (9 tests)
│   ├── test_comparison.ml      # Spec vs Disruptor comparison suite (11 tests)
│   └── dune
│
├── bench/
│   ├── bench_sweep.ml          # Thread sweep: 1–8 threads, 4 P/C configs
│   ├── bench_batch.ml          # Batch-size sweep: k ∈ {1,4,16,64,256}
│   ├── bench_false_sharing.ml  # Padded vs unpadded index comparison
│   └── dune
│
├── test.sh                     # Main entry point (see Usage below)
├── test2.sh                    # Stress-loop: runs test_comparison 100×
├── setup.sh                    # Disables ASLR for reproducible benchmarks
└── dune-project
```

---

## Prerequisites

- **OCaml 5.x** (tested on 5.2+; 5.4.0+tsan for data-race detection)
- **opam** package manager
- **dune** ≥ 3.0

Install OCaml dependencies:

```bash
opam install dune qcheck-stm qcheck-lin
```

> **Note:** `qcheck-stm` and `qcheck-lin` are from the
> [multicoretests](https://github.com/ocaml-multicore/multicoretests) project.
> If they are not yet in your opam repository, pin them:
> ```bash
> opam pin add qcheck-stm https://github.com/ocaml-multicore/multicoretests.git
> opam pin add qcheck-lin https://github.com/ocaml-multicore/multicoretests.git
> ```

For reproducible benchmark numbers, disable address-space randomisation once
per boot (requires root):

```bash
./setup.sh          # runs: sudo sysctl -w kernel.randomize_va_space=0
```

---

## Building

```bash
dune build
```

This compiles the `disruptor` library and all test/bench executables. Build
artifacts go to `_build/` and are not committed.

---

## Running Tests

```bash
./test.sh tests
```

This runs all four correctness suites in order:

| Step | Suite | What it checks |
|---|---|---|
| 1 | Smoke test | Basic SPSC enqueue/dequeue sanity |
| 2 | Stress tests | No loss or duplication under concurrent load (SPSC / MPSC / MPMC) |
| 3 | QCheck-STM + QCheck-Lin | Sequential model conformance + linearisability (9 tests) |
| 4 | Comparison suite | Spec-correct queues vs Disruptor pipeline variants (11 tests) |

Expected output ends with:

```
✓  All correctness tests passed.
...
success (ran 11 tests)
```

### Running individual test executables

```bash
dune exec test/test_spsc_smoke.exe
dune exec test/test_spsc_stress.exe
dune exec test/test_mpsc_stress.exe
dune exec test/test_mpmc_stress.exe
dune exec test/test_stm.exe
dune exec test/test_comparison.exe
```

### Stress-looping the comparison suite (100 iterations)

```bash
./test2.sh
```

Useful for catching rare concurrency bugs that appear infrequently.

---

## Running Benchmarks

```bash
./test.sh bench
```

This runs three benchmark programs back-to-back. Each run takes approximately
2 seconds per configuration; the full benchmark suite takes around 5–10 minutes.

### Benchmark 1 — Thread sweep (`bench_sweep`)

Sweeps producers and consumers from 1 to 8 across four configurations:

| Config | Description |
|---|---|
| (a) 1P:1C | Single producer, single consumer — baseline throughput |
| (b) nP:1C | Multiple producers, one consumer — MPSC scaling |
| (c) 1P:nC | One producer, multiple consumers — fan-out scaling |
| (d) nP:nC | Symmetric — equal producers and consumers |

All seven implementations run side-by-side. Throughput reported in **M ops/sec**.

### Benchmark 2 — Batch-size sweep (`bench_batch`)

Sweeps batch size `k ∈ {1, 4, 16, 64, 256}` at 1P:1C, 4P:1C, and 4P:4C.

For Disruptor SPSC/MPSC, `k` is the producer burst size before re-checking
the running flag; the consumer drains all available events per barrier pass
(implicit natural batching). For Vyukov/MS/Bounded, `k` is the number of items
per loop turn for both producer and consumer domains.

### Benchmark 3 — False-sharing investigation (`bench_false_sharing`)

Compares padded (`Atomic.make_contended`) vs unpadded (`Atomic.make`) indices
for the producer cursor and head/tail positions. Reports `Delta%`:

```
Delta = (padded - unpadded) / unpadded × 100%
```

A positive delta means padding improves throughput by eliminating
false-sharing coherence traffic.

### Running individual benchmarks

```bash
dune exec bench/bench_sweep.exe
dune exec bench/bench_batch.exe
dune exec bench/bench_false_sharing.exe
```

---

## TSAN (Data-Race Detection)

To run the test suite under ThreadSanitizer, switch to the TSAN-instrumented
OCaml compiler:

```bash
./test.sh tsan_tests    # switch to 5.4.0+tsan, build, run correctness tests
./test.sh tsan_bench    # switch to 5.4.0+tsan, build, run benchmarks
./test.sh tsan_all      # both
```

The `5.4.0+tsan` opam switch must be installed first:

```bash
opam switch create 5.4.0+tsan \
  --packages ocaml-variants.5.4.0+options,ocaml-option-tsan
```

All implementations are TSAN-clean. One historical data race (`cached_gating_min`
in `Disruptor_sequencer_mpsc` was a plain `mutable int`; corrected to
`int Atomic.t`) was caught and fixed using TSAN.

---

## Implementation Summary

### `Queue_spsc` — Lamport SPSC (Task 1)

Two monotonically increasing atomic indices (`head`, `tail`) on separate
cache lines. The producer writes only `tail`; the consumer writes only `head`.
No CAS needed — a release store on `tail` and an acquire load on `tail` form
the sole synchronisation pair. Power-of-2 capacity enables `land mask` instead
of integer division for slot indexing.

### `Queue_mpmc` — Vyukov MPMC (Task 2)

Each ring-buffer slot carries an atomic sequence number encoding occupancy and
generation. Producers CAS `enqueue_pos`; consumers CAS `dequeue_pos`. The
sequence number discriminates three states via `diff = seq - pos`:
`diff = 0` (slot ready), `diff < 0` (spin or report full/empty),
`diff > 0` (retry with fresh position). ABA is impossible because each
ring-cycle increments the generation encoded in the sequence.

### `Queue_mpsc` — Hybrid MPSC (Task 3)

Producers use the Vyukov CAS protocol on `enqueue_pos`. The single consumer
replaces its CAS with a plain `Atomic.set` on `dequeue_pos` — safe because no
other domain races on that index. Reduces consumer-side work from
O(contention) to O(1) per dequeue. An in-flight spin handles the window
between a producer's successful CAS (logical commit) and its
`slot.sequence` publication.

### Disruptor Infrastructure

| Module | Role |
|---|---|
| `Sequence` | `Atomic.make_contended` counter; initial value −1 |
| `Ring_buffer` | `Int_rb` (atomic int slots) and `Event_rb` (mutable record slots) |
| `Wait_strategy` | `BusySpin` / `Yielding` / `Blocking` (Mutex + Condition) |
| `Sequence_barrier` | Polls SPSC cursor or scans MPSC `available_buffer` |
| `Disruptor_sequencer_spsc` | `next` with cached-consumer backpressure; `publish` advances cursor |
| `Disruptor_sequencer_mpsc` | FAA claim; `available_buffer` records cycle numbers per slot |
| `Disruptor_pipeline` | Assembles above into `Int_spsc`, `Int_mpsc`, `Event_spsc` |

---

## Key Results

All numbers from a 2-second run on department Linux machines (OCaml 5,
buffer size = 65 536 slots).

### 1P:1C baseline

| Implementation | Mops/s |
|---|---:|
| MPSC queue | 24.62 |
| Vyukov MPMC | 10.03 |
| Disruptor SPSC | 8.56 |
| SPSC queue | 6.83 |
| Michael-Scott | 6.72 |
| Disruptor MPSC | 6.30 |
| Bounded (mutex) | 4.66 |

### nP:1C scaling

| Producers | MPSC queue | Disruptor MPSC | Vyukov MPMC |
|---:|---:|---:|---:|
| 1 | 25.83 | 7.10 | 7.83 |
| 2 | 5.23 | 7.40 | 3.57 |
| 4 | 2.38 | 10.21 | 2.35 |
| 8 | 2.00 | **12.54** | 1.22 |

Disruptor MPSC is the only implementation that **grows** with producers
(FAA never retries). CAS-based MPSC collapses 13× from 1→8 producers.

### False sharing

| Configuration | Padded | Unpadded | Delta |
|---|---:|---:|---:|
| Disruptor MPSC 4P:1C | 8.37 M | 1.81 M | **+362.7%** |
| Vyukov MPMC 2P:1C | 3.83 M | 2.73 M | +40.1% |
| Vyukov MPMC 1P:1C | 5.80 M | 7.54 M | −23.1% |

`Atomic.make_contended` is mandatory at ≥ 2 writers. At 1P:1C it slightly
hurts throughput due to cache pollution.

---

## References

- Lamport (1983). *Specifying Concurrent Program Modules*. ACM TOPLAS.
- Vyukov (2010). *Bounded MPMC Queue*. 1024cores.net.
- Thompson et al. (2011). *Disruptor: High performance alternative to bounded queues*. LMAX Exchange.
- Michael & Scott (1996). *Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms*. PODC.
- Dongol et al. (2023). *QCheck-STM / QCheck-Lin*. github.com/ocaml-multicore/multicoretests.
