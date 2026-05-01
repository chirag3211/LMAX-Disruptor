(* bench/bench_batch.ml
   Throughput benchmark: impact of BATCH SIZE on throughput.

   Task 6 asks to "measure the impact of batch size (enqueue/dequeue k items
   per operation) on throughput."

   We sweep batch sizes k = 1, 4, 16, 64, 256 for representative configs:
     - 1P:1C  (SPSC-style contention pattern)
     - 4P:1C  (MPSC regime)
     - 4P:4C  (high contention, MPMC)

   "Batch size k" means:
     - Producers: claim+publish k slots in a tight inner loop before
       checking the running flag.  For Disruptor SPSC/MPSC, this uses
       k sequential claim+publish calls; for the others it's k iterations
       of the per-item fast path.
     - Consumers: drain up to k items per turn (Disruptor MPSC naturally
       processes all available slots in a single run_consumer pass, so
       it batches implicitly; for others we loop k times).

   Implementations compared:
     1. Disruptor SPSC      (1P:1C only — by design)
     2. Disruptor MPSC      (nP:1C)
     3. Disruptor MPMC      (nP:nC)
     4. Vyukov MPMC         (nP:nC)
     5. Michael-Scott LF    (nP:nC, unbounded)
     6. Bounded (mutex)     (nP:nC) *)

let duration_s  = 2.0
let buffer_size = 65536

let batch_sizes = [1; 4; 16; 64; 256]

(* ── Generic batch runner (for try_enqueue/try_dequeue-style queues) ────── *)

let run_batch ~n_prod ~n_cons ~batch ~enqueue ~dequeue =
  let running  = Atomic.make true in
  let cons_ops = Array.make n_cons 0 in

  let producers = Array.init n_prod (fun _ ->
    Domain.spawn (fun () ->
      let v = ref 0 in
      while Atomic.get running do
        for _ = 1 to batch do
          while not (enqueue !v) && Atomic.get running do
            Domain.cpu_relax ()
          done;
          incr v
        done
      done)
  ) in

  let consumers = Array.init n_cons (fun i ->
    Domain.spawn (fun () ->
      let count = ref 0 in
      while Atomic.get running do
        for _ = 1 to batch do
          (match dequeue () with
           | Some _ -> incr count
           | None   -> Domain.cpu_relax ())
        done
      done;
      let rec drain () =
        match dequeue () with
        | Some _ -> incr count; drain ()
        | None   -> ()
      in
      drain ();
      cons_ops.(i) <- !count)
  ) in

  Unix.sleepf duration_s;
  Atomic.set running false;
  Array.iter Domain.join producers;
  Array.iter Domain.join consumers;
  let total = Array.fold_left (+) 0 cons_ops in
  Float.of_int total /. duration_s /. 1_000_000.0

(* ── Disruptor SPSC batch runner ─────────────────────────────────────────── *)
(* The Disruptor SPSC producer claims ONE sequence at a time (no batch API).
   "Batch size" here means the producer claims+publishes k slots before
   re-checking the running flag.  The consumer always processes all available
   slots in a single run_consumer pass, so it naturally batches. *)

let bench_disruptor_spsc ~batch =
  let d = Disruptor_pipeline.Int_spsc.make
    ~size:buffer_size
    ~wait:(Wait_strategy.make_busy_spin ()) in
  let running    = Atomic.make true in
  let cons_count = Atomic.make 0 in

  let producer = Domain.spawn (fun () ->
    let v = ref 0 in
    while Atomic.get running do
      for _ = 1 to batch do
        let seq = Disruptor_pipeline.Int_spsc.claim d in
        Disruptor_pipeline.Int_spsc.publish d seq !v;
        incr v
      done
    done)
  in
  let consumer = Domain.spawn (fun () ->
    Disruptor_pipeline.Int_spsc.run_consumer d
      ~handler:(fun () _seq _v ->
        ignore (Atomic.fetch_and_add cons_count 1))
      ())
  in

  Unix.sleepf duration_s;
  Atomic.set running false;
  Disruptor_pipeline.Int_spsc.stop d;
  Domain.join producer;
  Domain.join consumer;
  Float.of_int (Atomic.get cons_count) /. duration_s /. 1_000_000.0

(* ── Disruptor MPSC batch runner ─────────────────────────────────────────── *)

let bench_disruptor_mpsc ~n_prod ~batch =
  let d = Disruptor_pipeline.Int_mpsc.make
    ~size:buffer_size
    ~wait:(Wait_strategy.make_busy_spin ()) in
  let running    = Atomic.make true in
  let cons_count = Atomic.make 0 in

  let producers = Array.init n_prod (fun _ ->
    Domain.spawn (fun () ->
      let v = ref 0 in
      while Atomic.get running do
        for _ = 1 to batch do
          let seq = Disruptor_pipeline.Int_mpsc.claim d in
          Disruptor_pipeline.Int_mpsc.publish d seq !v;
          incr v
        done
      done)
  ) in
  let consumer = Domain.spawn (fun () ->
    Disruptor_pipeline.Int_mpsc.run_consumer d
      ~handler:(fun () _seq _v ->
        ignore (Atomic.fetch_and_add cons_count 1))
      ())
  in

  Unix.sleepf duration_s;
  Atomic.set running false;
  Disruptor_pipeline.Int_mpsc.stop d;
  Array.iter Domain.join producers;
  Domain.join consumer;
  Float.of_int (Atomic.get cons_count) /. duration_s /. 1_000_000.0

(* ── Vyukov / MS / Bounded ───────────────────────────────────────────────── *)

let bench_vyukov ~n_prod ~n_cons ~batch =
  let q = Queue_mpmc.make buffer_size in
  run_batch ~n_prod ~n_cons ~batch
    ~enqueue:(Queue_mpmc.try_enqueue q)
    ~dequeue:(fun () -> Queue_mpmc.try_dequeue q)

let bench_ms ~n_prod ~n_cons ~batch =
  let q = Lockfree_queue.create () in
  run_batch ~n_prod ~n_cons ~batch
    ~enqueue:(fun v -> Lockfree_queue.enq q v; true)
    ~dequeue:(fun () -> Lockfree_queue.try_deq q)

let bench_bounded ~n_prod ~n_cons ~batch =
  let q = Bounded_queue.create buffer_size in
  run_batch ~n_prod ~n_cons ~batch
    ~enqueue:(fun v -> Bounded_queue.try_enq q v)
    ~dequeue:(fun () -> Bounded_queue.try_deq q)

(* ── Print helpers ─────────────────────────────────────────────────────── *)

let col_w = 8
let n_cols = List.length batch_sizes
let table_w = 20 + (col_w + 2) * n_cols

let sep () = print_string (String.make table_w '-'); print_newline ()

let header config =
  sep ();
  Printf.printf "%s\n" config;
  sep ();
  Printf.printf "%-20s" "Impl \\ batch k";
  List.iter (fun k -> Printf.printf "  %*d" col_w k) batch_sizes;
  print_newline ()

let bench_row label f =
  Printf.printf "%-20s" label;
  List.iter (fun k ->
    let v = f k in
    Printf.printf "  %*.2f" col_w v
  ) batch_sizes;
  print_newline ()

(* ── Main ──────────────────────────────────────────────────────────────── *)

let () =
  Printf.printf
    "Batch-size sweep — %.0fs per run, buffer = %d\n\
     Throughput in M ops/sec.  Higher is better.\n\n"
    duration_s buffer_size;

  header "1P:1C configuration";
  bench_row "Disruptor SPSC"
    (fun k -> bench_disruptor_spsc ~batch:k);
  bench_row "Disruptor MPSC"
    (fun k -> bench_disruptor_mpsc ~n_prod:1 ~batch:k);
  bench_row "Vyukov MPMC"
    (fun k -> bench_vyukov ~n_prod:1 ~n_cons:1 ~batch:k);
  bench_row "Michael-Scott"
    (fun k -> bench_ms ~n_prod:1 ~n_cons:1 ~batch:k);
  bench_row "Bounded(mutex)"
    (fun k -> bench_bounded ~n_prod:1 ~n_cons:1 ~batch:k);

  print_newline ();

  header "4P:1C configuration (MPSC regime)";
  bench_row "Disruptor MPSC"
    (fun k -> bench_disruptor_mpsc ~n_prod:4 ~batch:k);
  bench_row "Vyukov MPMC"
    (fun k -> bench_vyukov ~n_prod:4 ~n_cons:1 ~batch:k);
  bench_row "Michael-Scott"
    (fun k -> bench_ms ~n_prod:4 ~n_cons:1 ~batch:k);
  bench_row "Bounded(mutex)"
    (fun k -> bench_bounded ~n_prod:4 ~n_cons:1 ~batch:k);

  print_newline ();

  header "4P:4C configuration (MPMC regime)";
  bench_row "Vyukov MPMC"
    (fun k -> bench_vyukov ~n_prod:4 ~n_cons:4 ~batch:k);
  bench_row "Michael-Scott"
    (fun k -> bench_ms ~n_prod:4 ~n_cons:4 ~batch:k);
  bench_row "Bounded(mutex)"
    (fun k -> bench_bounded ~n_prod:4 ~n_cons:4 ~batch:k);

  print_newline ();
  sep ();
  Printf.printf "Notes:\n";
  Printf.printf "  Disruptor SPSC/MPSC: batch = producer burst size before\n";
  Printf.printf "    re-checking running flag; consumer drains all available\n";
  Printf.printf "    events per barrier pass (implicit natural batching).\n";
  Printf.printf "  Vyukov / MS / Bounded: batch = items per\n";
  Printf.printf "    loop turn for both producer and consumer domains.\n";
  sep ()