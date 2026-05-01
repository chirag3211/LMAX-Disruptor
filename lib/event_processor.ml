(* event_processor.ml
   The event processor is the consumer side of the Disruptor.

   Each consumer runs [run] in its own OCaml 5 domain. The loop:
     1. Asks the barrier: what is the highest available sequence?
     2. Processes all events from [next_seq] to [available] in a batch.
     3. Advances its own sequence so upstream producers/consumers can proceed.
     4. Repeats until stopped.

   We provide two variants:
   - Int_processor  : for Int_rb ring buffers
   - Event_processor: for Event_rb ring buffers *)

(* ── Integer event processor ─────────────────────────────────────────────── *)

module Int_processor = struct
  type 'state t = {
    sequence : Sequence.t;
    barrier  : Sequence_barrier.t;
    ring     : Ring_buffer.Int_rb.t;
    handler  : 'state -> int -> int -> unit;
    running  : bool Atomic.t;
  }

  let make ~ring ~barrier ~handler =
    { sequence = Sequence.make Sequence.initial;
      barrier;
      ring;
      handler;
      running  = Atomic.make true; }

  let sequence t = t.sequence

  let run t state =
    let next_seq = ref (Sequence.get t.sequence + 1) in
    (try
      while true do
        (* Pass t.running so wait_for can raise Shutdown when stopped *)
        let available =
          Sequence_barrier.wait_for t.barrier !next_seq t.running
        in
        while !next_seq <= available do
          let value = Ring_buffer.Int_rb.read t.ring !next_seq in
          t.handler state !next_seq value;
          incr next_seq
        done;
        Sequence.set t.sequence available
      done
    with Sequence_barrier.Shutdown -> ());
    (* Drain any remaining published events *)
    let final = Sequence.get (Sequence_barrier.producer_cursor t.barrier) in
    while !next_seq <= final do
      let value = Ring_buffer.Int_rb.read t.ring !next_seq in
      t.handler state !next_seq value;
      incr next_seq
    done;
    Sequence.set t.sequence final

  let stop t = Atomic.set t.running false
end


(* ── Generic event processor ─────────────────────────────────────────────── *)

module Event_processor = struct
  type ('event, 'state) t = {
    sequence : Sequence.t;
    barrier  : Sequence_barrier.t;
    ring     : 'event Ring_buffer.Event_rb.t;
    handler  : 'state -> int -> 'event -> unit;
    running  : bool Atomic.t;
  }

  let make ~ring ~barrier ~handler =
    { sequence = Sequence.make Sequence.initial;
      barrier;
      ring;
      handler;
      running  = Atomic.make true; }

  let sequence t = t.sequence

  let run t state =
    let next_seq = ref (Sequence.get t.sequence + 1) in
    (try
      while true do
        let available =
          Sequence_barrier.wait_for t.barrier !next_seq t.running
        in
        while !next_seq <= available do
          let event = Ring_buffer.Event_rb.get t.ring !next_seq in
          t.handler state !next_seq event;
          incr next_seq
        done;
        Sequence.set t.sequence available
      done
    with Sequence_barrier.Shutdown -> ());
    let final = Sequence.get (Sequence_barrier.producer_cursor t.barrier) in
    while !next_seq <= final do
      let event = Ring_buffer.Event_rb.get t.ring !next_seq in
      t.handler state !next_seq event;
      incr next_seq
    done;
    Sequence.set t.sequence final

  let stop t = Atomic.set t.running false
end