(* bench/bench_sweep.ml
   Task 6 — Thread sweep benchmark: 1–8 threads across all four
   producer/consumer configurations.

   The four configurations swept are:
     (a) 1P:1C  — fixed baseline (SPSC regime)
     (b) nP:1C  — n producers, 1 consumer (MPSC regime), n = 1..8
     (c) 1P:nC  — 1 producer, n consumers (fan-out regime),  n = 1..8
     (d) nP:nC  — n producers, n consumers (MPMC regime),   n = 1..8


   Implementations compared at each data point:
     SPSC-capable  (1P:1C only): Disruptor SPSC
     MPSC-capable  (nP:1C):     Disruptor MPSC, Vyukov MPMC, MS LF, Bounded
     MPMC-capable  (all):       Vyukov MPMC, MS LF, Bounded

   Each run lasts [duration_s] seconds.
   Throughput = completed dequeue ops / elapsed time, in M ops/sec.
*)

let duration_s  = 2.0
let buffer_size = 65536

(* ── Generic benchmark runner ────────────────────────────────────────────── *)

let run_bench ~n_prod ~n_cons ~enqueue ~dequeue =
  let running  = Atomic.make true in
  let cons_ops = Array.make n_cons 0 in

  let producers = Array.init n_prod (fun _ ->
    Domain.spawn (fun () ->
      let v = ref 0 in
      while Atomic.get running do
        while not (enqueue !v) && Atomic.get running do
          Domain.cpu_relax ()
        done;
        incr v
      done))
  in

  let consumers = Array.init n_cons (fun i ->
    Domain.spawn (fun () ->
      let count = ref 0 in
      while Atomic.get running do
        (match dequeue () with
         | Some _ -> incr count
         | None   -> Domain.cpu_relax ())
      done;
      let rec drain () =
        match dequeue () with
        | Some _ -> incr count; drain ()
        | None   -> ()
      in
      drain ();
      cons_ops.(i) <- !count))
  in

  Unix.sleepf duration_s;
  Atomic.set running false;
  Array.iter Domain.join producers;
  Array.iter Domain.join consumers;
  let total = Array.fold_left (+) 0 cons_ops in
  Float.of_int total /. duration_s /. 1_000_000.0

(* ── Per-implementation bench wrappers ──────────────────────────────────── *)

let bench_vyukov ~n_prod ~n_cons =
  let q = Queue_mpmc.make buffer_size in
  run_bench ~n_prod ~n_cons
    ~enqueue:(Queue_mpmc.try_enqueue q)
    ~dequeue:(fun () -> Queue_mpmc.try_dequeue q)

let bench_ms ~n_prod ~n_cons =
  let q = Lockfree_queue.create () in
  run_bench ~n_prod ~n_cons
    ~enqueue:(fun v -> Lockfree_queue.enq q v; true)
    ~dequeue:(fun () -> Lockfree_queue.try_deq q)

let bench_bounded ~n_prod ~n_cons =
  let q = Bounded_queue.create buffer_size in
  run_bench ~n_prod ~n_cons
    ~enqueue:(fun v -> Bounded_queue.try_enq q v)
    ~dequeue:(fun () -> Bounded_queue.try_deq q)

(* Standalone SPSC — 1P:1C only by design *)
let bench_spsc () =
  let q = Queue_spsc.make buffer_size in
  run_bench ~n_prod:1 ~n_cons:1
    ~enqueue:(Queue_spsc.try_enqueue q)
    ~dequeue:(fun () -> Queue_spsc.try_dequeue q)

(* Standalone MPSC — multiple producers, single consumer *)
let bench_mpsc ~n_prod =
  let q = Queue_mpsc.make buffer_size in
  run_bench ~n_prod ~n_cons:1
    ~enqueue:(Queue_mpsc.try_enqueue q)
    ~dequeue:(fun () -> Queue_mpsc.try_dequeue q)

(* Disruptor SPSC — 1P:1C only by design *)
let bench_disruptor_spsc () =
  let d = Disruptor_pipeline.Int_spsc.make
    ~size:buffer_size
    ~wait:(Wait_strategy.make_busy_spin ()) in
  let running    = Atomic.make true in
  let cons_count = Atomic.make 0 in
  let producer = Domain.spawn (fun () ->
    let v = ref 0 in
    while Atomic.get running do
      let seq = Disruptor_pipeline.Int_spsc.claim d in
      Disruptor_pipeline.Int_spsc.publish d seq !v;
      incr v
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

(* Disruptor MPSC — nP:1C *)
let bench_disruptor_mpsc ~n_prod =
  let d = Disruptor_pipeline.Int_mpsc.make
    ~size:buffer_size
    ~wait:(Wait_strategy.make_busy_spin ()) in
  let running    = Atomic.make true in
  let cons_count = Atomic.make 0 in
  let producers = Array.init n_prod (fun _ ->
    Domain.spawn (fun () ->
      let v = ref 0 in
      while Atomic.get running do
        let seq = Disruptor_pipeline.Int_mpsc.claim d in
        Disruptor_pipeline.Int_mpsc.publish d seq !v;
        incr v
      done))
  in
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


(* ── Formatting helpers ──────────────────────────────────────────────────── *)

let threads = [1; 2; 3; 4; 5; 6; 7; 8]
let mpmc_ns = [1; 2; 3; 4; 5; 6; 7; 8]

let col_w   = 8
let label_w = 20

let sep ncols =
  print_string (String.make (label_w + (col_w + 2) * ncols) '-');
  print_newline ()

let print_header title ns =
  sep (List.length ns);
  Printf.printf "%s\n" title;
  sep (List.length ns);
  Printf.printf "%-*s" label_w "Impl \\ n";
  List.iter (fun n -> Printf.printf "  %*d" col_w n) ns;
  print_newline ()

let print_row label ns f =
  Printf.printf "%-*s" label_w label;
  List.iter (fun n ->
    let v = f n in
    Printf.printf "  %*.2f" col_w v
  ) ns;
  print_newline ()

(* ── (a) 1P:1C baseline ─────────────────────────────────────────────────── *)

let run_section_a () =
  Printf.printf "\n(a) 1P:1C — Fixed baseline\n";
  Printf.printf "%s\n" (String.make (label_w + 12) '-');
  let fmt label v =
    Printf.printf "  %-20s %.2fM ops/sec\n" label v
  in
  fmt "SPSC queue"      (bench_spsc ());
  fmt "MPSC queue"      (bench_mpsc ~n_prod:1);
  fmt "Disruptor SPSC"  (bench_disruptor_spsc ());
  fmt "Disruptor MPSC"  (bench_disruptor_mpsc ~n_prod:1);
  fmt "Vyukov MPMC"     (bench_vyukov         ~n_prod:1 ~n_cons:1);
  fmt "Michael-Scott"   (bench_ms             ~n_prod:1 ~n_cons:1);
  fmt "Bounded(mutex)"  (bench_bounded        ~n_prod:1 ~n_cons:1)

(* ── (b) nP:1C sweep ────────────────────────────────────────────────────── *)

let run_section_b () =
  print_newline ();
  print_header "(b) nP:1C — n producers, 1 consumer  (M ops/sec)" threads;
  (* SPSC is 1P:1C only *)
  Printf.printf "%-*s" label_w "SPSC queue";
  List.iter (fun n ->
    if n = 1 then Printf.printf "  %*.2f" col_w (bench_spsc ())
    else Printf.printf "  %*s" col_w "N/A"
  ) threads;
  print_newline ();
  print_row "MPSC queue"      threads (fun n -> bench_mpsc ~n_prod:n);
  (* SPSC is 1P:1C only — show N/A for n > 1, actual for n = 1 *)
  Printf.printf "%-*s" label_w "Disruptor SPSC";
  List.iter (fun n ->
    if n = 1 then
      Printf.printf "  %*.2f" col_w (bench_disruptor_spsc ())
    else
      Printf.printf "  %*s" col_w "N/A"
  ) threads;
  print_newline ();
  print_row "Disruptor MPSC"  threads (fun n -> bench_disruptor_mpsc ~n_prod:n);
  print_row "Vyukov MPMC"     threads (fun n -> bench_vyukov         ~n_prod:n ~n_cons:1);
  print_row "Michael-Scott"   threads (fun n -> bench_ms             ~n_prod:n ~n_cons:1);
  print_row "Bounded(mutex)"  threads (fun n -> bench_bounded        ~n_prod:n ~n_cons:1)

(* ── (c) 1P:nC sweep ────────────────────────────────────────────────────── *)

(* Show a real measurement at n=1 (still 1P:1C), N/A for n>=2.
   Used for SPSC and MPSC which are single-consumer only. *)
let single_consumer_row label ns bench_one =
  Printf.printf "%-*s" label_w label;
  List.iter (fun n ->
    if n = 1 then Printf.printf "  %*.2f" col_w (bench_one ())
    else Printf.printf "  %*s" col_w "N/A"
  ) ns;
  print_newline ()

let run_section_c () =
  print_newline ();
  print_header "(c) 1P:nC — 1 producer, n consumers  (M ops/sec)" threads;
  single_consumer_row "SPSC queue"     threads (fun () -> bench_spsc ());
  single_consumer_row "MPSC queue"     threads (fun () -> bench_mpsc ~n_prod:1);
  single_consumer_row "Disruptor SPSC" threads (fun () -> bench_disruptor_spsc ());
  single_consumer_row "Disruptor MPSC" threads (fun () -> bench_disruptor_mpsc ~n_prod:1);
  print_row "Vyukov MPMC"     threads (fun n -> bench_vyukov         ~n_prod:1 ~n_cons:n);
  print_row "Michael-Scott"   threads (fun n -> bench_ms             ~n_prod:1 ~n_cons:n);
  print_row "Bounded(mutex)"  threads (fun n -> bench_bounded        ~n_prod:1 ~n_cons:n)

(* ── (d) nP:nC sweep ────────────────────────────────────────────────────── *)

let run_section_d () =
  print_newline ();
  print_header "(d) nP:nC — n producers, n consumers  (M ops/sec)" mpmc_ns;
  single_consumer_row "SPSC queue"     mpmc_ns (fun () -> bench_spsc ());
  single_consumer_row "MPSC queue"     mpmc_ns (fun () -> bench_mpsc ~n_prod:1);
  single_consumer_row "Disruptor SPSC" mpmc_ns (fun () -> bench_disruptor_spsc ());
  single_consumer_row "Disruptor MPSC" mpmc_ns (fun () -> bench_disruptor_mpsc ~n_prod:1);
  print_row "Vyukov MPMC"     mpmc_ns (fun n -> bench_vyukov         ~n_prod:n ~n_cons:n);
  print_row "Michael-Scott"   mpmc_ns (fun n -> bench_ms             ~n_prod:n ~n_cons:n);
  print_row "Bounded(mutex)"  mpmc_ns (fun n -> bench_bounded        ~n_prod:n ~n_cons:n)

(* ── Main ───────────────────────────────────────────────────────────────── *)

let () =
  Printf.printf
    "Thread sweep benchmark — %.0fs per run, buffer size = %d\n\
     Throughput in M ops/sec.  Higher is better.\n"
    duration_s buffer_size;
  run_section_a ();
  run_section_b ();
  run_section_c ();
  run_section_d ();
  Printf.printf "\n%s\n" (String.make 70 '=');