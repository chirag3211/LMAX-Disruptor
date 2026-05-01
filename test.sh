#!/usr/bin/env bash
# test.sh — build, test, and benchmark the bounded lock-free queue project.
#
# Usage:
#   ./test.sh              # run everything (tests + benchmarks)
#   ./test.sh tests        # correctness tests only (fast, good for dev loop)
#   ./test.sh bench        # benchmarks only
set -euo pipefail

MODE="${1:-all}"

run_tests() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║                    CORRECTNESS TESTS                     ║"
  echo "╚══════════════════════════════════════════════════════════╝"

  echo ""
  echo "── 1. Smoke test (Queue_spsc basic sanity) ─────────────────"
  dune exec test/test_spsc_smoke.exe

  echo ""
  echo "── 2. Stress tests (concurrent, checks no loss/duplication) ─"
  dune exec test/test_spsc_stress.exe
  dune exec test/test_mpsc_stress.exe
  dune exec test/test_mpmc_stress.exe

  echo ""
  echo "── 3. QCheck-STM + QCheck-Lin (spec-correct queues) ─────────"
  echo "      Queue_spsc / Queue_mpsc / Queue_mpmc"
  echo "      Tests: STM sequential, STM parallel, Lin linearisability"
  dune exec test/test_stm.exe

  echo ""
  echo "── 4. Comparison suite ───────────────────────────────────────"
  echo "      Spec-correct vs Disruptor at each design point:"
  echo "      Queue_spsc  vs Disruptor_pipeline.Int_spsc"
  echo "      Queue_mpsc  vs Disruptor_pipeline.Int_mpsc"
  echo "      Queue_mpmc  (Vyukov) — correctness only"
  echo "      (Disruptor MPMC removed — see test_comparison.ml for rationale)"
  echo "      Tests: STM sequential/parallel, Lin, deterministic replay"
  dune exec test/test_comparison.exe

  echo ""
  echo "✓  All correctness tests passed."
}

run_benchmarks() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║                       BENCHMARKS                         ║"
  echo "╚══════════════════════════════════════════════════════════╝"

  echo ""
  echo "── 5. Thread sweep (Task 6) ──────────────────────────────────"
  echo "      Sweeps 1–8 threads across four producer/consumer configs:"
  echo "      (a) 1P:1C  (b) nP:1C  (c) 1P:nC  (d) nP:nC"
  echo "      All implementations side-by-side:"
  echo "        Queue_spsc / Queue_mpsc / Queue_mpmc (Vyukov)"
  echo "        Disruptor Int_spsc / Int_mpsc"
  echo "        Michael-Scott lock-free / Bounded (mutex)"
  dune exec bench/bench_sweep.exe

  echo ""
  echo "── 6. Batch-size sweep (Task 6) ──────────────────────────────"
  echo "      Sweeps batch sizes k=1,4,16,64,256 for 1P:1C, 4P:1C,"
  echo "      and 4P:4C configurations."
  echo "      Shows where Disruptor FAA batching beats per-item CAS."
  dune exec bench/bench_batch.exe

  echo ""
  echo "── 7. False-sharing impact (Task 7) ──────────────────────────"
  echo "      Padded (Atomic.make_contended) vs unpadded indices."
  echo "      Quantifies the cache false-sharing tax per implementation."
  dune exec bench/bench_false_sharing.exe
}

echo "=== Building ==="
dune build

run_with_tsan() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║                         TSAN                             ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  opam switch 5.4.0+tsan
  eval $(opam env)
  opam switch
  dune build
}

case "$MODE" in
  tests)      run_tests ;;
  bench)      run_benchmarks ;;
  tsan_tests) run_with_tsan ; run_tests ;;
  tsan_bench) run_with_tsan ; run_benchmarks ;;
  all)        run_tests; run_benchmarks ;;
  tsan_all)   run_with_tsan ; run_tests ; run_benchmarks ;;
  *)
    echo "Unknown mode: $MODE.  Usage: $0 [all|tests|bench]"
    exit 1
    ;;
esac
