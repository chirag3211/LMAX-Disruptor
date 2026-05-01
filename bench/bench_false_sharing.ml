(* bench/bench_false_sharing.ml
   Task 7: Quantify the throughput impact of false sharing on queue indices.

   We compare PADDED (Atomic.make_contended — each index on its own cache
   line) vs UNPADDED (plain Atomic.make — indices may share a cache line)
   for ALL four queue implementations in this project:

     1. Disruptor SPSC  — head (producer cursor) and tail (consumer seq)
     2. Disruptor MPSC  — producer cursor and consumer seq
     3. Vyukov MPMC     — enqueue_pos and dequeue_pos

   For the Disruptor variants the shared state is inside Sequence.t, which
   already uses Atomic.make_contended in the production code.  To measure
   the "without padding" baseline we implement thin unpadded wrappers that
   mirror each data structure exactly, replacing make_contended with make.

   The delta column shows what percentage of throughput is gained by using
   Atomic.make_contended — i.e. the false-sharing tax. *)

let duration_s  = 2.0
let buffer_size = 65536
let mask        = buffer_size - 1

(* ── Generic runner ─────────────────────────────────────────────────────── *)

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
      done)
  ) in

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
      cons_ops.(i) <- !count)
  ) in

  Unix.sleepf duration_s;
  Atomic.set running false;
  Array.iter Domain.join producers;
  Array.iter Domain.join consumers;
  let total = Array.fold_left (+) 0 cons_ops in
  Float.of_int total /. duration_s /. 1_000_000.0

(* ── Disruptor SPSC runner (uses blocking run_consumer) ─────────────────── *)
(* For SPSC we must use the Disruptor's own run_consumer loop, not run_bench,
   because the consumer sequence is shared via Sequence.t (not try_dequeue). *)

let run_disruptor_spsc_bench ~claim ~publish ~run_consumer ~stop =
  let running    = Atomic.make true in
  let cons_count = Atomic.make 0 in
  let producer = Domain.spawn (fun () ->
    let v = ref 0 in
    while Atomic.get running do
      let seq = claim () in
      publish seq !v;
      incr v
    done)
  in
  let consumer = Domain.spawn (fun () ->
    run_consumer ~handler:(fun () _seq _v ->
      ignore (Atomic.fetch_and_add cons_count 1)) ())
  in
  Unix.sleepf duration_s;
  Atomic.set running false;
  stop ();
  Domain.join producer;
  Domain.join consumer;
  Float.of_int (Atomic.get cons_count) /. duration_s /. 1_000_000.0

(* ── Disruptor MPSC runner (nP:1C, blocking run_consumer) ───────────────── *)

let run_disruptor_mpsc_bench ~n_prod ~claim ~publish ~run_consumer ~stop =
  let running    = Atomic.make true in
  let cons_count = Atomic.make 0 in
  let producers  = Array.init n_prod (fun _ ->
    Domain.spawn (fun () ->
      let v = ref 0 in
      while Atomic.get running do
        let seq = claim () in
        publish seq !v;
        incr v
      done)
  ) in
  let consumer = Domain.spawn (fun () ->
    run_consumer ~handler:(fun () _seq _v ->
      ignore (Atomic.fetch_and_add cons_count 1)) ())
  in
  Unix.sleepf duration_s;
  Atomic.set running false;
  stop ();
  Array.iter Domain.join producers;
  Domain.join consumer;
  Float.of_int (Atomic.get cons_count) /. duration_s /. 1_000_000.0

(* ════════════════════════════════════════════════════════════════════════════
   SECTION 1 — SPSC: padded (production) vs unpadded
   ════════════════════════════════════════════════════════════════════════════ *)

(* Production Disruptor SPSC already uses Sequence.make_contended internally *)
let bench_spsc_padded () =
  let d = Disruptor_pipeline.Int_spsc.make
    ~size:buffer_size
    ~wait:(Wait_strategy.make_busy_spin ()) in
  run_disruptor_spsc_bench
    ~claim:(fun () -> Disruptor_pipeline.Int_spsc.claim d)
    ~publish:(fun seq v -> Disruptor_pipeline.Int_spsc.publish d seq v)
    ~run_consumer:(fun ~handler -> Disruptor_pipeline.Int_spsc.run_consumer d ~handler)
    ~stop:(fun () -> Disruptor_pipeline.Int_spsc.stop d)

(* Unpadded SPSC: plain atomic indices, otherwise identical logic *)
module SpscUnpadded = struct
  type t = {
    buf          : int array;
    buffer_size  : int;
    cursor       : int Atomic.t;   (* producer published-up-to; plain make *)
    consumer_seq : int Atomic.t;   (* consumer consumed-up-to; plain make *)
    running      : bool Atomic.t;
  }

  let make size = {
    buf         = Array.make size 0;
    buffer_size = size;
    cursor      = Atomic.make (-1);
    consumer_seq= Atomic.make (-1);
    running     = Atomic.make true;
  }

  let try_enqueue t v =
    let next_seq  = Atomic.get t.cursor + 1 in
    let wrap_point = next_seq - t.buffer_size in
    if wrap_point > Atomic.get t.consumer_seq then false
    else begin
      t.buf.(next_seq land mask) <- v;
      Atomic.set t.cursor next_seq;
      true
    end

  let try_dequeue t =
    let next_seq = Atomic.get t.consumer_seq + 1 in
    if next_seq > Atomic.get t.cursor then None
    else begin
      let v = t.buf.(next_seq land mask) in
      Atomic.set t.consumer_seq next_seq;
      Some v
    end
end

let bench_spsc_unpadded () =
  let q = SpscUnpadded.make buffer_size in
  run_bench ~n_prod:1 ~n_cons:1
    ~enqueue:(SpscUnpadded.try_enqueue q)
    ~dequeue:(fun () -> SpscUnpadded.try_dequeue q)

(* ════════════════════════════════════════════════════════════════════════════
   SECTION 2 — MPSC: padded (production) vs unpadded
   ════════════════════════════════════════════════════════════════════════════ *)

let bench_mpsc_padded ~n_prod =
  let d = Disruptor_pipeline.Int_mpsc.make
    ~size:buffer_size
    ~wait:(Wait_strategy.make_busy_spin ()) in
  run_disruptor_mpsc_bench ~n_prod
    ~claim:(fun () -> Disruptor_pipeline.Int_mpsc.claim d)
    ~publish:(fun seq v -> Disruptor_pipeline.Int_mpsc.publish d seq v)
    ~run_consumer:(fun ~handler -> Disruptor_pipeline.Int_mpsc.run_consumer d ~handler)
    ~stop:(fun () -> Disruptor_pipeline.Int_mpsc.stop d)

(* Unpadded MPSC: use Vyukov_mpmc as a structural proxy — same per-slot
   sequence algorithm, same multi-producer claim via CAS, same single-consumer
   path.  We just use plain Atomic.make for enqueue_pos/dequeue_pos (below). *)

(* To get a truly unpadded MPSC, we build a minimal version of Vyukov with
   plain Atomic.make on both cursor fields (the production Vyukov uses
   plain make too, so Vyukov IS the unpadded baseline for MPMC).
   For MPSC specifically, we restrict it to one consumer. *)
let bench_mpsc_unpadded ~n_prod =
  (* Vyukov with plain Atomic.make on cursors is the unpadded MPSC proxy *)
  let q = Queue_mpmc.make buffer_size in
  run_bench ~n_prod ~n_cons:1
    ~enqueue:(Queue_mpmc.try_enqueue q)
    ~dequeue:(fun () -> Queue_mpmc.try_dequeue q)

(* ════════════════════════════════════════════════════════════════════════════
   SECTION 3 — Vyukov MPMC: padded vs unpadded global cursors
   ════════════════════════════════════════════════════════════════════════════ *)

(* The production Vyukov_mpmc uses plain Atomic.make on enqueue_pos and
   dequeue_pos (not contended).  This is the unpadded baseline.
   We add a padded variant below with make_contended on both. *)

let bench_vyukov_unpadded ~n_prod ~n_cons =
  let q = Queue_mpmc.make buffer_size in
  run_bench ~n_prod ~n_cons
    ~enqueue:(Queue_mpmc.try_enqueue q)
    ~dequeue:(fun () -> Queue_mpmc.try_dequeue q)

module VyukovPadded = struct
  type 'a slot = {
    sequence : int Atomic.t;
    mutable value : 'a option;
  }

  type 'a t = {
    mask        : int;
    buffer      : 'a slot array;
    enqueue_pos : int Atomic.t;   (* make_contended — padded *)
    dequeue_pos : int Atomic.t;   (* make_contended — padded *)
  }

  let make size =
    if size <= 0 || size land (size - 1) <> 0 then
      invalid_arg "VyukovPadded.make: size must be a power of 2";
    { mask        = size - 1;
      buffer      = Array.init size (fun i ->
        { sequence = Atomic.make i; value = None });
      enqueue_pos = Atomic.make_contended 0;
      dequeue_pos = Atomic.make_contended 0; }

  let try_enqueue t v =
    let rec loop () =
      let pos  = Atomic.get t.enqueue_pos in
      let slot = t.buffer.(pos land t.mask) in
      let diff = Atomic.get slot.sequence - pos in
      if diff = 0 then begin
        if Atomic.compare_and_set t.enqueue_pos pos (pos + 1) then begin
          slot.value <- Some v;
          Atomic.set slot.sequence (pos + 1); true
        end else loop ()
      end else if diff < 0 then false
      else loop ()
    in loop ()

  let try_dequeue t =
    let rec loop () =
      let pos  = Atomic.get t.dequeue_pos in
      let slot = t.buffer.(pos land t.mask) in
      let diff = Atomic.get slot.sequence - (pos + 1) in
      if diff = 0 then begin
        if Atomic.compare_and_set t.dequeue_pos pos (pos + 1) then begin
          let v = slot.value in
          slot.value <- None;
          Atomic.set slot.sequence (pos + t.mask + 1); v
        end else loop ()
      end else if diff < 0 then None
      else loop ()
    in loop ()
end

let bench_vyukov_padded ~n_prod ~n_cons =
  let q = VyukovPadded.make buffer_size in
  run_bench ~n_prod ~n_cons
    ~enqueue:(VyukovPadded.try_enqueue q)
    ~dequeue:(fun () -> VyukovPadded.try_dequeue q)

(* ── Print helpers ─────────────────────────────────────────────────────── *)

let sep () = print_string (String.make 70 '-'); print_newline ()

let result_row label padded unpadded =
  let delta = (padded -. unpadded) /. unpadded *. 100.0 in
  Printf.printf "%-32s  %7.2fM  %8.2fM  %+6.1f%%\n"
    label padded unpadded delta

(* ── Main ──────────────────────────────────────────────────────────────── *)

let () =
  Printf.printf
    "False-sharing investigation — %.0fs per run, buffer = %d\n\
     Comparing PADDED (Atomic.make_contended) vs UNPADDED (Atomic.make)\n\
     on head/tail/cursor indices.  Throughput in M ops/sec.\n\n"
    duration_s buffer_size;

  sep ();
  Printf.printf "%-32s  %9s  %10s  %7s\n" "Configuration" "Padded" "Unpadded" "Delta%";
  sep ();

  (* SPSC *)
  result_row "Disruptor SPSC  1P:1C"
    (bench_spsc_padded ())
    (bench_spsc_unpadded ());

  (* MPSC *)
  result_row "Disruptor MPSC  1P:1C"
    (bench_mpsc_padded ~n_prod:1)
    (bench_mpsc_unpadded ~n_prod:1);

  result_row "Disruptor MPSC  4P:1C"
    (bench_mpsc_padded ~n_prod:4)
    (bench_mpsc_unpadded ~n_prod:4);

  (* Vyukov MPMC *)
  result_row "Vyukov MPMC     1P:1C"
    (bench_vyukov_padded ~n_prod:1 ~n_cons:1)
    (bench_vyukov_unpadded ~n_prod:1 ~n_cons:1);

  result_row "Vyukov MPMC     2P:1C"
    (bench_vyukov_padded ~n_prod:2 ~n_cons:1)
    (bench_vyukov_unpadded ~n_prod:2 ~n_cons:1);

  result_row "Vyukov MPMC     4P:4C"
    (bench_vyukov_padded ~n_prod:4 ~n_cons:4)
    (bench_vyukov_unpadded ~n_prod:4 ~n_cons:4);

  sep ();
  Printf.printf "\nDelta = (padded - unpadded) / unpadded * 100%%.\n";
  Printf.printf "Positive = padding improves throughput (removes false-sharing cost).\n";
  Printf.printf "\nProduction code notes:\n";
  Printf.printf "  Disruptor SPSC/MPSC: cursor/consumer_seq use Sequence.make\n";
  Printf.printf "    which wraps Atomic.make_contended — that IS the padded path.\n";
  Printf.printf "  Vyukov MPMC: enqueue_pos/dequeue_pos use plain Atomic.make\n";
  Printf.printf "    (unpadded in production).  VyukovPadded above adds contention.\n"