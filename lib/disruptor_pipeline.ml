(* disruptor_pipeline.ml — Disruptor pipeline API
   Provides Int_spsc, Int_mpsc, Event_spsc — high-level wrappers around
   the ring buffer, sequencers, and sequence barriers. *)


(* ── SPSC integer Disruptor ──────────────────────────────────────────────── *)

module Int_spsc = struct
  type t = {
    ring         : Ring_buffer.Int_rb.t;
    sequencer    : Disruptor_sequencer_spsc.t;
    barrier      : Sequence_barrier.t;
    consumer_seq : Sequence.t;
    wait         : Wait_strategy.t;
    running      : bool Atomic.t;
  }

  let make ~size ~wait =
    let consumer_seq = Sequence.make Sequence.initial in
    let sequencer    = Disruptor_sequencer_spsc.make size consumer_seq in
    let ring         = Ring_buffer.Int_rb.make size in
    let barrier      = Sequence_barrier.make_spsc
                         ~producer_cursor:(Disruptor_sequencer_spsc.cursor sequencer)
                         ~dependent_seqs:[]
                         ~wait_strategy:wait in
    { ring; sequencer; barrier; consumer_seq;
      wait; running = Atomic.make true }

  let claim d = Disruptor_sequencer_spsc.next d.sequencer

  let publish d seq value =
    Ring_buffer.Int_rb.publish d.ring seq value;
    Disruptor_sequencer_spsc.publish d.sequencer seq;
    Wait_strategy.signal d.wait

  let run_consumer d ~handler state =
    let next_seq = ref (Sequence.get d.consumer_seq + 1) in
    (try
      while true do
        let available =
          Sequence_barrier.wait_for d.barrier !next_seq d.running
        in
        while !next_seq <= available do
          let value = Ring_buffer.Int_rb.read d.ring !next_seq in
          handler state !next_seq value;
          incr next_seq
        done;
        Sequence.set d.consumer_seq available
      done
    with Sequence_barrier.Shutdown -> ());
    let final = Sequence.get (Sequence_barrier.producer_cursor d.barrier) in
    while !next_seq <= final do
      let value = Ring_buffer.Int_rb.read d.ring !next_seq in
      handler state !next_seq value;
      incr next_seq
    done;
    Sequence.set d.consumer_seq final

  let stop d =
    Atomic.set d.running false;
    Wait_strategy.signal d.wait
end


(* ── Multi-producer single-consumer integer Disruptor ───────────────────── *)

module Int_mpsc = struct
  (* In the MPSC case:
     - Multiple producer domains each call [claim] and [publish] concurrently.
     - A single consumer domain calls [run_consumer].
     - The sequencer uses fetch_and_add to claim slots atomically.
     - The barrier scans available_buffer to handle out-of-order publication. *)

  type t = {
    ring         : Ring_buffer.Int_rb.t;
    sequencer    : Disruptor_sequencer_mpsc.t;
    barrier      : Sequence_barrier.t;
    consumer_seq : Sequence.t;
    wait         : Wait_strategy.t;
    running      : bool Atomic.t;
  }

  let make ~size ~wait =
    let sequencer    = Disruptor_sequencer_mpsc.make size in
    let consumer_seq = Sequence.make Sequence.initial in
    (* Register the consumer as a gating sequence so the producer
       does not lap it when the buffer is full. *)
    Disruptor_sequencer_mpsc.add_gating_sequence sequencer consumer_seq;
    let ring         = Ring_buffer.Int_rb.make size in
    let barrier      = Sequence_barrier.make_mp
                         ~sequencer
                         ~dependent_seqs:[]
                         ~wait_strategy:wait in
    { ring; sequencer; barrier; consumer_seq;
      wait; running = Atomic.make true }

  (* Each producer domain calls [claim] to get its unique sequence,
     writes its value, then calls [publish] to make it visible. *)
  let claim d =
    let (lo, _hi) = Disruptor_sequencer_mpsc.next d.sequencer 1 in
    lo

  let publish d seq value =
    Ring_buffer.Int_rb.publish d.ring seq value;
    Disruptor_sequencer_mpsc.publish d.sequencer seq;
    Wait_strategy.signal d.wait

  let run_consumer d ~handler state =
    let next_seq = ref (Sequence.get d.consumer_seq + 1) in
    (try
      while true do
        let available =
          Sequence_barrier.wait_for d.barrier !next_seq d.running
        in
        while !next_seq <= available do
          let value = Ring_buffer.Int_rb.read d.ring !next_seq in
          handler state !next_seq value;
          incr next_seq
        done;
        Sequence.set d.consumer_seq available
      done
    with Sequence_barrier.Shutdown -> ());
    (* Drain: read everything published before stop was called *)
    let final = Sequence.get (Sequence_barrier.producer_cursor d.barrier) in
    while !next_seq <= final do
      let value = Ring_buffer.Int_rb.read d.ring !next_seq in
      handler state !next_seq value;
      incr next_seq
    done;
    Sequence.set d.consumer_seq final

  let stop d =
    Atomic.set d.running false;
    Wait_strategy.signal d.wait
end


(* ── SPSC generic event Disruptor ───────────────────────────────────────── *)

module Event_spsc = struct
  type 'a t = {
    ring         : 'a Ring_buffer.Event_rb.t;
    sequencer    : Disruptor_sequencer_spsc.t;
    barrier      : Sequence_barrier.t;
    consumer_seq : Sequence.t;
    wait         : Wait_strategy.t;
    running      : bool Atomic.t;
  }

  let make ~size ~init ~wait =
    let consumer_seq = Sequence.make Sequence.initial in
    let sequencer    = Disruptor_sequencer_spsc.make size consumer_seq in
    let ring         = Ring_buffer.Event_rb.make size init in
    let barrier      = Sequence_barrier.make_spsc
                         ~producer_cursor:(Disruptor_sequencer_spsc.cursor sequencer)
                         ~dependent_seqs:[]
                         ~wait_strategy:wait in
    { ring; sequencer; barrier; consumer_seq;
      wait; running = Atomic.make true }

  let claim_and_get d =
    let seq = Disruptor_sequencer_spsc.next d.sequencer in
    let event = Ring_buffer.Event_rb.get d.ring seq in
    (seq, event)

  let publish d seq =
    Disruptor_sequencer_spsc.publish d.sequencer seq;
    Wait_strategy.signal d.wait

  let run_consumer d ~handler state =
    let next_seq = ref (Sequence.get d.consumer_seq + 1) in
    (try
      while true do
        let available =
          Sequence_barrier.wait_for d.barrier !next_seq d.running
        in
        while !next_seq <= available do
          let event = Ring_buffer.Event_rb.get d.ring !next_seq in
          handler state !next_seq event;
          incr next_seq
        done;
        Sequence.set d.consumer_seq available
      done
    with Sequence_barrier.Shutdown -> ());
    let final = Sequence.get (Sequence_barrier.producer_cursor d.barrier) in
    while !next_seq <= final do
      let event = Ring_buffer.Event_rb.get d.ring !next_seq in
      handler state !next_seq event;
      incr next_seq
    done;
    Sequence.set d.consumer_seq final

  let stop d =
    Atomic.set d.running false;
    Wait_strategy.signal d.wait
end
