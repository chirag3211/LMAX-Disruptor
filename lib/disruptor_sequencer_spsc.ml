(* disruptor_sequencer_spsc.ml
   Single-Producer sequencer for the Disruptor pipeline.

   In the SPSC case only ONE domain ever calls [next] and [publish].
   This means:
   - No CAS is needed to claim a sequence — a plain atomic write suffices.
   - No availableBuffer is needed — slots are always published in order.
   - The only coordination needed is: the producer must not lap the consumer.

   HOW BACK-PRESSURE WORKS:
   The ring buffer has [size] slots. If the producer has published up to
   sequence P and the consumer has consumed up to sequence C, then
   (P - C) events are in flight. When P - C = size, the buffer is full —
   the producer must wait for the consumer to advance before claiming more.

   We track the consumer's progress via a [Sequence.t] that the consumer
   updates after each batch. The producer holds a CACHED copy of the
   consumer's last known sequence to avoid reading the contended atomic
   on every iteration. It only re-reads when it discovers the buffer is full. *)

type t = {
  buffer_size   : int;
  (* The producer's own sequence: "I have published up to this number". *)
  cursor        : Sequence.t;
  (* The consumer's sequence, read by the producer for back-pressure.
     This is a reference to the SAME Sequence.t that the consumer updates,
     so any consumer advance is visible here via Atomic.get. *)
  consumer_seq  : Sequence.t;
  (* Cached copy of the consumer's sequence. We update this only when
     we detect the buffer is full, avoiding unnecessary cross-domain
     atomic reads on the hot path. *)
  mutable cached_consumer : int;
}

(* [make size consumer_seq] creates a sequencer for a buffer of [size] slots.
   [consumer_seq] is the Sequence.t owned by the consumer — the producer
   reads it to check how much space is available. *)
let make buffer_size consumer_seq =
  { buffer_size;
    cursor          = Sequence.make Sequence.initial;
    consumer_seq;
    cached_consumer = Sequence.initial; }

(* [next t] claims the next sequence number for the producer to write into.
   Returns the claimed sequence, or blocks (spins) if the buffer is full.

   PROGRESS INVARIANT: after [next] returns N, the slot at (N land mask)
   is exclusively owned by the producer until [publish t N] is called. *)
let next t =
  (* The next sequence we want to claim. *)
  let next_seq = Sequence.get t.cursor + 1 in
  (* The sequence that would be OVERWRITTEN if we proceed.
     If the consumer hasn't consumed it yet, we must wait. *)
  let wrap_point = next_seq - t.buffer_size in
  (* Fast path: check against cached consumer value first.
     If wrap_point <= cached_consumer, there is definitely space. *)
  if wrap_point > t.cached_consumer then begin
    (* Slow path: refresh the cached consumer sequence and spin until space. *)
    let rec spin () =
      let consumer_now = Sequence.get t.consumer_seq in
      t.cached_consumer <- consumer_now;
      if wrap_point > consumer_now then begin
        (* Buffer still full — yield to allow other domains to progress,
           then retry. Domain.cpu_relax() is a hardware hint (PAUSE on x86)
           that reduces power and avoids memory order speculation penalties
           during a spin loop. *)
        Domain.cpu_relax ();
        spin ()
      end
    in
    spin ()
  end;
  next_seq

(* [publish t sequence] makes [sequence] visible to the consumer.
   In SPSC this is just advancing the cursor — no availableBuffer needed
   because the single producer always publishes in order. *)
let publish t sequence =
  Sequence.set t.cursor sequence

(* [cursor t] returns the producer's current published sequence.
   The sequence barrier reads this to determine what's available. *)
let cursor t = t.cursor