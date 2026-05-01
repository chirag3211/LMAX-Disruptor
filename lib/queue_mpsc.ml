(* queue_mpsc.ml — Bounded Multi-Producer / Single-Consumer ring-buffer queue.

   Task 3 from the project spec.

   DESIGN:
   Dmitry Vyukov's sequence-number technique, adapted for the MPSC case:
   each slot carries an atomic sequence number that tracks its lifecycle.
   Multiple producers race to claim the tail index via CAS (not FAA, as
   required by the spec).  The single consumer advances the head without
   any CAS — it is the sole reader of [head].

   WHY CAS AND NOT FETCH_AND_ADD FOR THE PRODUCER?
   The project spec explicitly requires CAS on the tail for MPSC producers.
   fetch_and_add blindly claims a slot without checking whether it is free,
   which can stall the producer at the back-pressure spin inside [next] for
   an unbounded time if many producers race at the wrap point.  CAS retries
   only when another producer wins the same slot, and only claims after
   confirming the slot is ready — making the back-pressure check and the
   claim atomic w.r.t. other producers.

   SLOT LIFECYCLE:
   Initially slot i carries sequence = i.
   After producer writes at position p:  sequence <- p + 1
   After consumer reads  at position p:  sequence <- p + mask + 1
     (= p + capacity, which is the sequence value the producer at that
      slot will see in the next cycle, signalling "ready to write again"). *)

type 'a slot = {
  sequence : int Atomic.t;
  mutable  value : 'a option;
}

type 'a t = {
  capacity    : int;
  mask        : int;
  buf         : 'a slot array;
  enqueue_pos : int Atomic.t;   (* claimed by producers via CAS   *)
  dequeue_pos : int Atomic.t;   (* advanced by the single consumer *)
}

let make capacity =
  if capacity <= 0 || capacity land (capacity - 1) <> 0 then
    invalid_arg "Mpsc_queue.make: capacity must be a positive power of 2";
  let buf = Array.init capacity (fun i ->
    { sequence = Atomic.make_contended i; value = None })
  in
  { capacity;
    mask        = capacity - 1;
    buf;
    enqueue_pos = Atomic.make_contended 0;
    dequeue_pos = Atomic.make_contended 0 }

(** [try_enqueue t v] — producer side (multiple producers allowed).
    Returns [true] on success, [false] if the queue is full.

    diff interpretation:
      diff = 0  → slot is free and ready; attempt to claim via CAS.
      diff < 0  → slot is either genuinely full (diff = seq - pos < 0 because
                  the consumer hasn't freed this slot for this cycle yet) or
                  a consumer is in-flight freeing it.  We distinguish by
                  checking dequeue_pos: if it is lagging by a full cycle then
                  the queue is actually full; otherwise spin briefly.
      diff > 0  → another producer advanced enqueue_pos past us; retry. *)
let try_enqueue t v =
  let rec loop () =
    let pos  = Atomic.get t.enqueue_pos in
    let slot = t.buf.(pos land t.mask) in
    let seq  = Atomic.get slot.sequence in
    let diff = seq - pos in
    if diff = 0 then begin
      (* Slot is ready — race to claim pos via CAS (not FAA, as spec requires) *)
      if Atomic.compare_and_set t.enqueue_pos pos (pos + 1) then begin
        slot.value <- Some v;
        (* Signal consumer: this slot now contains data for cycle pos *)
        Atomic.set slot.sequence (pos + 1);
        true
      end else
        loop ()   (* lost the CAS race — retry *)
    end else if diff < 0 then begin
      (* Check whether a consumer is mid-flight freeing this slot *)
      if Atomic.get t.dequeue_pos > pos - t.capacity then begin
        Domain.cpu_relax ();
        loop ()   (* consumer in-flight — spin *)
      end else
        false     (* genuinely full *)
    end else
      loop ()     (* another producer advanced past us — retry *)
  in
  loop ()

(** [try_dequeue t] — consumer side (single consumer only).
    Returns [Some v] on success, [None] if empty.
    No CAS needed: there is exactly one consumer so we advance [dequeue_pos]
    with a plain atomic store after confirming the slot is ready. *)
let try_dequeue t =
  let pos  = Atomic.get t.dequeue_pos in
  let slot = t.buf.(pos land t.mask) in
  let seq  = Atomic.get slot.sequence in
  let diff = seq - (pos + 1) in
  if diff = 0 then begin
    (* Slot has been written for this cycle *)
    let v = slot.value in
    slot.value <- None;
    (* Advance head — plain store is safe because we are the only consumer *)
    Atomic.set t.dequeue_pos (pos + 1);
    (* Signal producers: this slot is free for the next cycle *)
    Atomic.set slot.sequence (pos + t.mask + 1);
    v
  end else if diff < 0 then begin
    (* Check whether a producer is mid-flight writing this slot *)
    if Atomic.get t.enqueue_pos > pos then begin
      (* Producer claimed the slot via CAS but hasn't published yet — spin *)
      let rec spin () =
        Domain.cpu_relax ();
        let seq2 = Atomic.get slot.sequence in
        if seq2 - (pos + 1) = 0 then begin
          let v = slot.value in
          slot.value <- None;
          Atomic.set t.dequeue_pos (pos + 1);
          Atomic.set slot.sequence (pos + t.mask + 1);
          v
        end else spin ()
      in
      spin ()
    end else
      None   (* truly empty *)
  end else
    None     (* should not happen in well-formed usage *)

let size t =
  let ep = Atomic.get t.enqueue_pos in
  let dp = Atomic.get t.dequeue_pos in
  max 0 (ep - dp)

let is_empty t = size t = 0
let is_full  t = size t >= t.capacity
