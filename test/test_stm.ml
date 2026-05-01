(* test/test_stm.ml
   QCheck-STM and QCheck-Lin correctness tests for all three bounded queues:
     - Queue_spsc   — standalone SPSC (Task 1: Lamport, atomic load/store only)
     - Queue_mpsc   — standalone MPSC (Task 3: CAS on tail)
     - Queue_mpmc   — Vyukov MPMC     (Task 2: per-slot sequence numbers)

   Each SUT is tested against the same sequential model (bounded queue with
   try_enqueue/try_dequeue returning bool/option) via:
     - STM sequential:  agree_test     — single-domain spec compliance
     - STM parallel:    agree_test_par — linearisability under concurrency
     - Lin:             lin_test       — linearisability (complementary checker) *)

open STM

(* ── Sequential model ───────────────────────────────────────────────────── *)

let cap = 8

type state = { contents : int list; capacity : int }

let init_state = { contents = []; capacity = cap }

type cmd = Enqueue of int | Dequeue

let show_cmd = function
  | Enqueue i -> Printf.sprintf "Enqueue(%d)" i
  | Dequeue   -> "Dequeue"

let next_state cmd st =
  match cmd with
  | Enqueue v ->
    if List.length st.contents >= st.capacity then st
    else { st with contents = st.contents @ [v] }
  | Dequeue ->
    (match st.contents with
     | []     -> st
     | _ :: t -> { st with contents = t })

let arb_cmd _st =
  let open QCheck.Gen in
  QCheck.make ~print:show_cmd
    (oneof [
      map (fun i -> Enqueue i) (int_range 0 99);
      return Dequeue;
    ])

let precond _cmd _st = true

let next_pow2 n =
  let s = ref 1 in while !s < n do s := !s * 2 done; !s

(* ════════════════════════════════════════════════════════════════════════════
   ADAPTER: Queue_spsc
   SPSC is single-producer/single-consumer.  The STM/Lin harnesses spawn
   two concurrent domains for each side, so we add a mutex per side purely
   for the testing harness — the underlying queue code is unchanged.
   ════════════════════════════════════════════════════════════════════════════ *)

module SpscAdapter = struct
  type t = {
    q         : int Queue_spsc.t;
    enq_mutex : Mutex.t;
    deq_mutex : Mutex.t;
  }

  let make n =
    { q = Queue_spsc.make (next_pow2 n);
      enq_mutex = Mutex.create ();
      deq_mutex = Mutex.create () }

  let enqueue t v =
    Mutex.lock t.enq_mutex;
    let r = Queue_spsc.try_enqueue t.q v in
    Mutex.unlock t.enq_mutex; r

  let dequeue t =
    Mutex.lock t.deq_mutex;
    let r = Queue_spsc.try_dequeue t.q in
    Mutex.unlock t.deq_mutex; r
end

(* ════════════════════════════════════════════════════════════════════════════
   ADAPTER: Queue_mpsc
   Multiple producers call try_enqueue concurrently (no mutex needed there).
   Single consumer: dequeue mutex is for harness only.
   ════════════════════════════════════════════════════════════════════════════ *)

module MpscAdapter = struct
  type t = {
    q         : int Queue_mpsc.t;
    deq_mutex : Mutex.t;
  }

  let make n =
    { q = Queue_mpsc.make (next_pow2 n);
      deq_mutex = Mutex.create () }

  let enqueue t v = Queue_mpsc.try_enqueue t.q v

  let dequeue t =
    Mutex.lock t.deq_mutex;
    let r = Queue_mpsc.try_dequeue t.q in
    Mutex.unlock t.deq_mutex; r
end

(* ════════════════════════════════════════════════════════════════════════════
   STM SPECS (shared postcond, per-SUT run)
   ════════════════════════════════════════════════════════════════════════════ *)

let run_cmd enqueue dequeue cmd sut =
  match cmd with
  | Enqueue v -> Res (bool, enqueue sut v)
  | Dequeue   -> Res (option int, dequeue sut)

let postcond_cmd cmd (st : state) (res : STM.res) =
  match cmd, res with
  | Enqueue _, Res ((Bool, _), got) ->
    got = (List.length st.contents < st.capacity)
  | Dequeue, Res ((Option Int, _), got) ->
    got = (match st.contents with [] -> None | v :: _ -> Some v)
  | _ -> false

module SpscSTM : STM.Spec = struct
  type nonrec cmd = cmd  type nonrec state = state
  type sut = SpscAdapter.t
  let arb_cmd = arb_cmd  let show_cmd = show_cmd  let precond = precond
  let init_sut () = SpscAdapter.make cap  let cleanup _ = ()
  let init_state = init_state  let next_state = next_state
  let run cmd sut = run_cmd SpscAdapter.enqueue SpscAdapter.dequeue cmd sut
  let postcond = postcond_cmd
end

module MpscSTM : STM.Spec = struct
  type nonrec cmd = cmd  type nonrec state = state
  type sut = MpscAdapter.t
  let arb_cmd = arb_cmd  let show_cmd = show_cmd  let precond = precond
  let init_sut () = MpscAdapter.make cap  let cleanup _ = ()
  let init_state = init_state  let next_state = next_state
  let run cmd sut = run_cmd MpscAdapter.enqueue MpscAdapter.dequeue cmd sut
  let postcond = postcond_cmd
end

module MpmcSTM : STM.Spec = struct
  type nonrec cmd = cmd  type nonrec state = state
  type sut = int Queue_mpmc.t
  let arb_cmd = arb_cmd  let show_cmd = show_cmd  let precond = precond
  let init_sut () = Queue_mpmc.make (next_pow2 cap)  let cleanup _ = ()
  let init_state = init_state  let next_state = next_state
  let run cmd sut = run_cmd Queue_mpmc.try_enqueue Queue_mpmc.try_dequeue cmd sut
  let postcond = postcond_cmd
end

(* ════════════════════════════════════════════════════════════════════════════
   LIN SPECS
   ════════════════════════════════════════════════════════════════════════════ *)

[@@@alert "-internal"]
module type CmdSpec = Lin.Internal.CmdSpec

module LinCmds = struct
  type cmd = Enqueue of int | Dequeue
  type res = Enqueue_res of bool | Dequeue_res of int option

  let show_cmd = function
    | Enqueue i -> Printf.sprintf "Enqueue(%d)" i
    | Dequeue   -> "Dequeue"

  let show_res = function
    | Enqueue_res b        -> Printf.sprintf "Enqueue_res(%b)" b
    | Dequeue_res None     -> "Dequeue_res(None)"
    | Dequeue_res (Some v) -> Printf.sprintf "Dequeue_res(Some %d)" v

  let equal_res r1 r2 = match r1, r2 with
    | Enqueue_res b1, Enqueue_res b2 -> b1 = b2
    | Dequeue_res v1, Dequeue_res v2 -> v1 = v2
    | _ -> false

  let gen_cmd = QCheck.Gen.(oneof [
    map (fun i -> Enqueue i) (int_range 0 99);
    return Dequeue;
  ])
  let shrink_cmd = QCheck.Shrink.nil
end

module SpscLinSpec : CmdSpec = struct
  include LinCmds
  type t = SpscAdapter.t
  let init ()   = SpscAdapter.make cap  let cleanup _ = ()
  let run cmd sut = match cmd with
    | Enqueue v -> Enqueue_res (SpscAdapter.enqueue sut v)
    | Dequeue   -> Dequeue_res (SpscAdapter.dequeue sut)
end

module MpscLinSpec : CmdSpec = struct
  include LinCmds
  type t = MpscAdapter.t
  let init ()   = MpscAdapter.make cap  let cleanup _ = ()
  let run cmd sut = match cmd with
    | Enqueue v -> Enqueue_res (MpscAdapter.enqueue sut v)
    | Dequeue   -> Dequeue_res (MpscAdapter.dequeue sut)
end

module MpmcLinSpec : CmdSpec = struct
  include LinCmds
  type t = int Queue_mpmc.t
  let init ()   = Queue_mpmc.make (next_pow2 cap)  let cleanup _ = ()
  let run cmd sut = match cmd with
    | Enqueue v -> Enqueue_res (Queue_mpmc.try_enqueue sut v)
    | Dequeue   -> Dequeue_res (Queue_mpmc.try_dequeue sut)
end

module SpscLin = Lin_domain.Make_internal(SpscLinSpec)
module MpscLin = Lin_domain.Make_internal(MpscLinSpec)
module MpmcLin = Lin_domain.Make_internal(MpmcLinSpec)

module SpscSTM_seq = STM_sequential.Make(SpscSTM)
module SpscSTM_dom = STM_domain.Make(SpscSTM)
module MpscSTM_seq = STM_sequential.Make(MpscSTM)
module MpscSTM_dom = STM_domain.Make(MpscSTM)
module MpmcSTM_seq = STM_sequential.Make(MpmcSTM)
module MpmcSTM_dom = STM_domain.Make(MpmcSTM)

let () =
  let count = 5 in
  QCheck_base_runner.run_tests_main [
    SpscSTM_seq.agree_test     ~count ~name:"Queue_spsc  — STM sequential";
    SpscSTM_dom.agree_test_par ~count ~name:"Queue_spsc  — STM parallel";
    SpscLin.lin_test           ~count ~name:"Queue_spsc  — Lin";

    MpscSTM_seq.agree_test     ~count ~name:"Queue_mpsc  — STM sequential";
    MpscSTM_dom.agree_test_par ~count ~name:"Queue_mpsc  — STM parallel";
    MpscLin.lin_test           ~count ~name:"Queue_mpsc  — Lin";

    MpmcSTM_seq.agree_test     ~count ~name:"Queue_mpmc  — STM sequential";
    MpmcSTM_dom.agree_test_par ~count ~name:"Queue_mpmc  — STM parallel";
    MpmcLin.lin_test           ~count ~name:"Queue_mpmc  — Lin";
  ]
