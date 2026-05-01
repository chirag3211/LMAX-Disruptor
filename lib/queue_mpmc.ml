(* queue_mpmc.ml — Dmitry Vyukov's bounded MPMC queue.
   Source: https://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue

   Each slot carries its own sequence number.
   Producers claim via fetch_and_add on enqueue_pos.
   Consumers claim via fetch_and_add on dequeue_pos.

   SLOT LIFECYCLE:
   Initially slot i has sequence = i.
   After producer writes slot at position p: sequence = p + 1
   After consumer reads slot at position p: sequence = p + mask + 1
     (= p + size, advancing to the next cycle) *)

type 'a slot = {
  sequence : int Atomic.t;
  mutable value : 'a option;
}

type 'a t = {
  mask        : int;
  buffer      : 'a slot array;
  enqueue_pos : int Atomic.t;
  dequeue_pos : int Atomic.t;
}

let make size =
  if size <= 0 || size land (size - 1) <> 0 then
    invalid_arg "Vyukov_mpmc.make: size must be a power of 2";
  let buffer = Array.init size (fun i ->
    { sequence = Atomic.make i; value = None })
  in
  { mask        = size - 1;
    buffer;
    enqueue_pos = Atomic.make 0;
    dequeue_pos = Atomic.make 0 }

(* [try_enqueue t v] — returns true on success, false if full.
   diff < 0 means seq < pos: the slot's consumer-reset sequence hasn't been
   written yet.  Two cases:
   - Buffer genuinely full: dequeue_pos <= pos - size — no consumer has claimed
     the slot for this cycle yet.  Return false.
   - Consumer in-flight: dequeue_pos > pos - size — a consumer claimed the slot
     via CAS on dequeue_pos but hasn't yet advanced slot.sequence.  Spinning
     is required; returning false here would violate linearizability because
     the dequeue already committed (the slot is being freed). *)
let try_enqueue t v =
  let size = t.mask + 1 in
  let rec loop () =
    let pos  = Atomic.get t.enqueue_pos in
    let slot = t.buffer.(pos land t.mask) in
    let seq  = Atomic.get slot.sequence in
    let diff = seq - pos in
    if diff = 0 then begin
      (* Slot is ready — try to claim pos *)
      if Atomic.compare_and_set t.enqueue_pos pos (pos + 1) then begin
        (* We own this slot — write value and signal consumers *)
        slot.value <- Some v;
        Atomic.set slot.sequence (pos + 1);
        true
      end else
        loop ()  (* lost the race — retry *)
    end else if diff < 0 then begin
      if Atomic.get t.dequeue_pos > pos - size then begin
        Domain.cpu_relax ();
        loop ()  (* consumer claimed slot but not yet published — spin *)
      end else
        false    (* buffer genuinely full *)
    end else
      loop ()  (* another producer is ahead — retry *)
  in
  loop ()

(* [try_dequeue t] — returns Some v on success, None if empty.
   diff < 0 means slot.sequence < pos+1: the slot has not yet been written for
   this dequeue position.  Two cases require different handling:
   - Truly empty: enqueue_pos = pos — no producer has claimed slot pos yet.
     Return None immediately.
   - Producer in-flight: enqueue_pos > pos — a producer claimed slot pos via
     CAS but has not yet written slot.value and advanced slot.sequence.
     Spin until the producer publishes; returning None here would violate
     linearizability because the enqueue already committed (returned true). *)
let try_dequeue t =
  let rec loop () =
    let pos  = Atomic.get t.dequeue_pos in
    let slot = t.buffer.(pos land t.mask) in
    let seq  = Atomic.get slot.sequence in
    let diff = seq - (pos + 1) in
    if diff = 0 then begin
      (* Slot is ready — try to claim pos *)
      if Atomic.compare_and_set t.dequeue_pos pos (pos + 1) then begin
        let v = slot.value in
        slot.value <- None;
        (* Signal producers: this slot is free for the next cycle *)
        Atomic.set slot.sequence (pos + t.mask + 1);
        v
      end else
        loop ()  (* lost the race — retry *)
    end else if diff < 0 then begin
      if Atomic.get t.enqueue_pos > pos then begin
        Domain.cpu_relax ();
        loop ()  (* producer claimed pos but not yet published — spin *)
      end else
        None     (* truly empty — no producer has claimed this slot *)
    end else
      loop ()  (* another consumer is ahead — retry *)
  in
  loop ()