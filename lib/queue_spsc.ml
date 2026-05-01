(* queue_spsc.ml — Bounded Single-Producer / Single-Consumer ring-buffer queue.

   Task 1 from the project spec.

   DESIGN:
   Two cache-line-isolated atomic indices — [head] (consumer) and [tail]
   (producer) — index into a fixed-size pre-allocated array.  No CAS is
   ever needed: the producer is the sole writer of [tail] and the consumer
   is the sole writer of [head], so plain atomic loads and stores suffice.

   This is Lamport's (1983) classic SPSC queue, brought into OCaml 5 using
   Atomic.make_contended to prevent false sharing between the two indices.

   INVARIANT:
     tail - head  = number of items currently in the queue  (0 .. capacity)
     tail = head  => empty
     tail - head = capacity => full

   Indices are never wrapped — we let them grow monotonically and mask into
   the array with (idx land mask).  This avoids an ABA-style ambiguity
   between full and empty. *)

type 'a t = {
  capacity : int;
  mask     : int;                  (* capacity - 1, for cheap modulo *)
  buf      : 'a Option.t array;    (* pre-allocated ring buffer      *)
  head     : int Atomic.t;         (* consumer reads here; producer reads for back-pressure *)
  tail     : int Atomic.t;         (* producer writes here; consumer reads for availability *)
}

let make capacity =
  if capacity <= 0 || capacity land (capacity - 1) <> 0 then
    invalid_arg "Spsc_queue.make: capacity must be a positive power of 2";
  { capacity;
    mask = capacity - 1;
    buf  = Array.make capacity None;
    head = Atomic.make_contended 0;
    tail = Atomic.make_contended 0 }

(** [try_enqueue t v] — producer side.
    Returns [true] and enqueues [v] if space is available, [false] if full.
    Must be called from exactly ONE producer domain. *)
let try_enqueue t v =
  let tl = Atomic.get t.tail in
  let hd = Atomic.get t.head in    (* read consumer progress for back-pressure *)
  if tl - hd >= t.capacity then
    false                           (* full *)
  else begin
    t.buf.(tl land t.mask) <- Some v;
    (* Release store: the value write above must be visible to the consumer
       before the tail increment is. Atomic.set provides this ordering. *)
    Atomic.set t.tail (tl + 1);
    true
  end

(** [try_dequeue t] — consumer side.
    Returns [Some v] and dequeues if an item is available, [None] if empty.
    Must be called from exactly ONE consumer domain. *)
let try_dequeue t =
  let hd = Atomic.get t.head in
  let tl = Atomic.get t.tail in    (* read producer progress for availability *)
  if hd >= tl then
    None                            (* empty *)
  else begin
    let v = t.buf.(hd land t.mask) in
    t.buf.(hd land t.mask) <- None; (* release slot for GC *)
    (* Release store: the slot clear above must happen before the head
       increment is visible to the producer. *)
    Atomic.set t.head (hd + 1);
    v
  end

let size t =
  let tl = Atomic.get t.tail in
  let hd = Atomic.get t.head in
  tl - hd

let is_empty t = size t = 0
let is_full  t = size t >= t.capacity
