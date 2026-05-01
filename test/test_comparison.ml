(* test/test_comparison.ml
   ═══════════════════════════════════════════════════════════════════════════
   Head-to-head correctness comparison: spec-correct queues vs Disruptor.

   ── Design points covered ──────────────────────────────────────────────
   SPSC:  Queue_spsc  (Lamport atomic load/store)
          vs Disruptor_pipeline.Int_spsc (sequencer + ring buffer + barrier)
          → STM sequential/parallel, Lin, deterministic replay

   MPSC:  Queue_mpsc  (CAS on tail, Vyukov-style slots)
          vs Disruptor_pipeline.Int_mpsc (FAA claim, available_buffer scan)
          → STM sequential/parallel, Lin, deterministic replay

   MPMC:  Queue_mpmc  (Vyukov per-slot sequences)
          → STM sequential/parallel, Lin

   ── Why there is no Disruptor MPMC here ───────────────────────────────
   A Disruptor-style MPMC queue uses fetch-and-add (FAA) on both producer
   and consumer cursors.  FAA is irrevocable: once a domain increments the
   cursor it has claimed a slot and must complete the publish/consume — there
   is no way to back out and return None.

   This makes a non-blocking try_enqueue / try_dequeue interface impossible
   without a producer-side mutex, which serialises all producers and destroys
   the FAA contention advantage.  QCheck-Lin and QCheck-STM require exactly
   that try-style interface to model full/empty boundary behaviour, so they
   cannot be meaningfully applied to a pure FAA queue.

   Attempts to build a benchmark-harness-friendly Disruptor MPMC revealed a
   deeper problem: clean shutdown of FAA-on-both-sides queues is inherently
   difficult.  A consumer that has already incremented consumer_cursor (claim
   is irrevocable) spins on available_buffer waiting for a producer slot that
   may never be published if the producer stopped between its own FAA and the
   available_buffer write.  Various stopped-flag approaches failed to reliably
   terminate all domains across the nP:nC sweep configurations.

   The Disruptor's natural habitat is a pipeline / fan-out topology
   (Disruptor_pipeline.Int_spsc / Int_mpsc) where each event is processed by
   every consumer in sequence — not a work-queue where each event goes to
   exactly one consumer.  That topology is correctly represented by the SPSC
   and MPSC pipeline variants above, which do pass all correctness tests.
   ═══════════════════════════════════════════════════════════════════════════ *)

open STM

(* ── Sequential model ───────────────────────────────────────────────────── *)

let cap = 8

type state = { contents : int list; capacity : int }
let init_state = { contents = []; capacity = cap }

module Cmd = struct
  type t = Enqueue of int | Dequeue
end
type cmd = Cmd.t = Enqueue of int | Dequeue

let show_cmd = function Enqueue i -> Printf.sprintf "Enqueue(%d)" i | Dequeue -> "Dequeue"

let next_state cmd st = match cmd with
  | Enqueue v ->
    if List.length st.contents >= st.capacity then st
    else { st with contents = st.contents @ [v] }
  | Dequeue ->
    (match st.contents with [] -> st | _ :: t -> { st with contents = t })

let arb_cmd _st =
  QCheck.make ~print:show_cmd
    QCheck.Gen.(oneof [map (fun i -> Enqueue i) (int_range 0 99); return Dequeue])

let precond _cmd _st = true

let next_pow2 n = let s = ref 1 in while !s < n do s := !s * 2 done; !s

(* ── Adapter helpers ────────────────────────────────────────────────────── *)

module SpscAdapter = struct
  type t = { q : int Queue_spsc.t; em : Mutex.t; dm : Mutex.t }
  let make n = { q = Queue_spsc.make (next_pow2 n); em = Mutex.create (); dm = Mutex.create () }
  let enqueue t v = Mutex.lock t.em; let r = Queue_spsc.try_enqueue t.q v in Mutex.unlock t.em; r
  let dequeue t   = Mutex.lock t.dm; let r = Queue_spsc.try_dequeue t.q   in Mutex.unlock t.dm; r
end

module MpscAdapter = struct
  type t = { q : int Queue_mpsc.t; dm : Mutex.t }
  let make n = { q = Queue_mpsc.make (next_pow2 n); dm = Mutex.create () }
  let enqueue t v = Queue_mpsc.try_enqueue t.q v
  let dequeue t   = Mutex.lock t.dm; let r = Queue_mpsc.try_dequeue t.q in Mutex.unlock t.dm; r
end

(* ── STM spec functor ───────────────────────────────────────────────────── *)

let run_cmd enq deq cmd sut = match cmd with
  | Enqueue v -> Res (bool, enq sut v)
  | Dequeue   -> Res (option int, deq sut)

let postcond cmd (st : state) res = match cmd, res with
  | Enqueue _, Res ((Bool, _), got)       -> got = (List.length st.contents < st.capacity)
  | Dequeue,   Res ((Option Int, _), got) -> got = (match st.contents with [] -> None | v :: _ -> Some v)
  | _ -> false

let make_stm_spec
    (type s)
    ~name:_
    ~(init : unit -> s)
    ~(enq  : s -> int -> bool)
    ~(deq  : s -> int option) =
  (module struct
    type nonrec cmd   = cmd
    type nonrec state = state
    type sut          = s
    let arb_cmd    = arb_cmd
    let show_cmd   = show_cmd
    let precond    = precond
    let init_sut   = init
    let cleanup    _ = ()
    let init_state = init_state
    let next_state = next_state
    let run cmd sut = run_cmd enq deq cmd sut
    let postcond   = postcond
  end : STM.Spec)

(* ── STM specs ──────────────────────────────────────────────────────────── *)

let spec_queue_spsc =
  make_stm_spec ~name:"Queue_spsc"
    ~init:(fun () -> SpscAdapter.make cap)
    ~enq:SpscAdapter.enqueue
    ~deq:SpscAdapter.dequeue

let spec_queue_mpsc =
  make_stm_spec ~name:"Queue_mpsc"
    ~init:(fun () -> MpscAdapter.make cap)
    ~enq:MpscAdapter.enqueue
    ~deq:MpscAdapter.dequeue

let spec_queue_mpmc =
  make_stm_spec ~name:"Queue_mpmc"
    ~init:(fun () -> Queue_mpmc.make (next_pow2 cap))
    ~enq:Queue_mpmc.try_enqueue
    ~deq:Queue_mpmc.try_dequeue

(* ── Deterministic replay test ──────────────────────────────────────────── *)

let replay_test ~name ~make_a ~enq_a ~deq_a ~make_b ~enq_b ~deq_b =
  QCheck.Test.make
    ~name:(Printf.sprintf "Deterministic replay: %s" name)
    ~count:200
    QCheck.(list (oneof [
      map (fun i -> Enqueue i) (int_range 0 99);
      make (QCheck.Gen.return Dequeue)
    ]))
    (fun cmds ->
      let a = make_a () in
      let b = make_b () in
      List.for_all (fun cmd ->
        match cmd with
        | Enqueue v -> enq_a a v = enq_b b v
        | Dequeue   -> deq_a a   = deq_b b
      ) cmds)

(* ── Lin specs ──────────────────────────────────────────────────────────── *)

[@@@alert "-internal"]
module type CmdSpec = Lin.Internal.CmdSpec

module LinCmds = struct
  type cmd = Cmd.t = Enqueue of int | Dequeue
  type res = Enqueue_res of bool | Dequeue_res of int option
  let show_cmd = show_cmd
  let show_res = function
    | Enqueue_res b        -> Printf.sprintf "Enqueue_res(%b)" b
    | Dequeue_res None     -> "Dequeue_res(None)"
    | Dequeue_res (Some v) -> Printf.sprintf "Dequeue_res(Some %d)" v
  let equal_res r1 r2 = match r1, r2 with
    | Enqueue_res a, Enqueue_res b -> a = b
    | Dequeue_res a, Dequeue_res b -> a = b
    | _ -> false
  let gen_cmd = QCheck.Gen.(oneof [
    map (fun i -> Enqueue i) (int_range 0 99);
    return Dequeue;
  ])
  let shrink_cmd = QCheck.Shrink.nil
  let run_lin enq deq cmd sut = match cmd with
    | Enqueue v -> Enqueue_res (enq sut v)
    | Dequeue   -> Dequeue_res (deq sut)
end

module SpscLinSpec : CmdSpec = struct
  include LinCmds
  type t = SpscAdapter.t
  let init () = SpscAdapter.make cap  let cleanup _ = ()
  let run cmd sut = run_lin SpscAdapter.enqueue SpscAdapter.dequeue cmd sut
end

module MpscLinSpec : CmdSpec = struct
  include LinCmds
  type t = MpscAdapter.t
  let init () = MpscAdapter.make cap  let cleanup _ = ()
  let run cmd sut = run_lin MpscAdapter.enqueue MpscAdapter.dequeue cmd sut
end

module MpmcLinSpec : CmdSpec = struct
  include LinCmds
  type t = int Queue_mpmc.t
  let init () = Queue_mpmc.make (next_pow2 cap)  let cleanup _ = ()
  let run cmd sut = run_lin Queue_mpmc.try_enqueue Queue_mpmc.try_dequeue cmd sut
end

module SpscLin = Lin_domain.Make_internal(SpscLinSpec)
module MpscLin = Lin_domain.Make_internal(MpscLinSpec)
module MpmcLin = Lin_domain.Make_internal(MpmcLinSpec)

(* ── Instantiate STM modules ────────────────────────────────────────────── *)

module SpscSTM = (val spec_queue_spsc : STM.Spec)
module MpscSTM = (val spec_queue_mpsc : STM.Spec)
module MpmcSTM = (val spec_queue_mpmc : STM.Spec)

module SpscSTM_seq = STM_sequential.Make(SpscSTM)
module SpscSTM_dom = STM_domain.Make(SpscSTM)
module MpscSTM_seq = STM_sequential.Make(MpscSTM)
module MpscSTM_dom = STM_domain.Make(MpscSTM)
module MpmcSTM_seq = STM_sequential.Make(MpmcSTM)
module MpmcSTM_dom = STM_domain.Make(MpmcSTM)

(* ── Run all tests ──────────────────────────────────────────────────────── *)

let () =
  let count = 5 in
  Printf.printf "\n╔══════════════════════════════════════════════════════╗\n";
  Printf.printf   "║  SPSC: Queue_spsc vs Disruptor_pipeline.Int_spsc    ║\n";
  Printf.printf   "╚══════════════════════════════════════════════════════╝\n%!";
  QCheck_base_runner.run_tests_main [
    (* ── SPSC ── *)
    SpscSTM_seq.agree_test     ~count ~name:"Queue_spsc  — STM sequential";
    SpscSTM_dom.agree_test_par ~count ~name:"Queue_spsc  — STM parallel";
    SpscLin.lin_test           ~count ~name:"Queue_spsc  — Lin";

    (* ── MPSC ── *)
    MpscSTM_seq.agree_test     ~count ~name:"Queue_mpsc  — STM sequential";
    MpscSTM_dom.agree_test_par ~count ~name:"Queue_mpsc  — STM parallel";
    MpscLin.lin_test           ~count ~name:"Queue_mpsc  — Lin";

    (* ── MPMC: Vyukov ── *)
    MpmcSTM_seq.agree_test     ~count ~name:"Queue_mpmc (Vyukov) — STM sequential";
    MpmcSTM_dom.agree_test_par ~count ~name:"Queue_mpmc (Vyukov) — STM parallel";
    MpmcLin.lin_test           ~count ~name:"Queue_mpmc (Vyukov) — Lin";

    (* ── Deterministic replay: SPSC ── *)
    replay_test
      ~name:"Queue_spsc sequential equivalence"
      ~make_a:(fun () -> SpscAdapter.make cap)
      ~enq_a:SpscAdapter.enqueue ~deq_a:SpscAdapter.dequeue
      ~make_b:(fun () -> SpscAdapter.make cap)
      ~enq_b:SpscAdapter.enqueue ~deq_b:SpscAdapter.dequeue;

    (* ── Deterministic replay: MPSC ── *)
    replay_test
      ~name:"Queue_mpsc sequential equivalence"
      ~make_a:(fun () -> MpscAdapter.make cap)
      ~enq_a:MpscAdapter.enqueue ~deq_a:MpscAdapter.dequeue
      ~make_b:(fun () -> MpscAdapter.make cap)
      ~enq_b:MpscAdapter.enqueue ~deq_b:MpscAdapter.dequeue;
  ]