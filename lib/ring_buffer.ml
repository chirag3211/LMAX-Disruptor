(* ring_buffer.ml
   A fixed-size circular array that forms the backbone of the Disruptor.

   KEY DESIGN DECISIONS:
   1. Size must be a power of 2. This lets us replace the expensive modulo
      operation (sequence mod size) with a cheap bitmask (sequence land mask).
      e.g. for size=8: mask=7 (binary 0111), so any sequence ANDed with 7
      gives a value 0..7. This matters in the hot path.

   2. Array is pre-allocated at startup. No allocation happens during
      event publishing or consuming. This eliminates GC pressure entirely
      in the integer version, and minimises it in the generic version.

   3. We provide TWO implementations:
      - Int_rb  : slots hold plain ints. Simplest, fastest, easy to test.
      - Event_rb: slots hold pre-allocated mutable records. Closer to the
                  Java Disruptor. Producers mutate the record in place rather
                  than writing a new value. *)

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

(* Check that n is a power of 2. The Disruptor requires this for the bitmask
   trick. We enforce it at construction time rather than silently rounding up,
   because rounding would silently change the buffer capacity the caller asked
   for. *)
let is_power_of_two n = n > 0 && n land (n - 1) = 0

(* Compute the index into the backing array for a given sequence number.
   This is called on every publish and every consume, so it must be fast.
   land (bitwise AND) is a single CPU instruction. *)
let index_of sequence mask = sequence land mask


(* ══ Version 1: Integer ring buffer ═════════════════════════════════════════
   Each slot holds one int, written atomically by the producer and read
   atomically by consumers.

   WHY Atomic.t SLOTS?
   OCaml's memory model (like C11) does not guarantee that a plain array write
   by one domain is visible to another domain without a synchronisation
   operation. Using Atomic for each slot gives us the required visibility
   guarantee. In the SPSC case the overhead is minimal — the CPU's store buffer
   and the consumer's load are already ordered by the sequence number fence. *)

module Int_rb = struct
  type t = {
    mask  : int;              (* size - 1, used for index_of *)
    slots : int Atomic.t array;  (* the backing array *)
  }

  (* [make size] creates a ring buffer of [size] slots, all initialised to 0.
     Raises Invalid_argument if size is not a power of 2. *)
  let make size =
    if not (is_power_of_two size) then
      invalid_arg (Printf.sprintf
        "Ring_buffer.Int_rb.make: size must be a power of 2, got %d" size);
    { mask  = size - 1;
      slots = Array.init size (fun _ -> Atomic.make 0) }

  (* Number of slots in the buffer. *)
  let size rb = rb.mask + 1

  (* [publish rb sequence value] writes [value] into the slot for [sequence].
     The producer calls this AFTER it has claimed [sequence] from the
     sequencer. The write must be visible to consumers before the producer
     advances its published-sequence, which is handled in the sequencer. *)
  let publish rb sequence value =
    let i = index_of sequence rb.mask in
    Atomic.set rb.slots.(i) value

  (* [read rb sequence] reads the value in the slot for [sequence].
     The consumer calls this only after the sequence barrier has confirmed
     the slot is published, so no extra synchronisation is needed here. *)
  let read rb sequence =
    let i = index_of sequence rb.mask in
    Atomic.get rb.slots.(i)
end


(* ══ Version 2: Pre-allocated event ring buffer ══════════════════════════════
   Each slot holds a mutable record (the "event"). Producers write into the
   record's fields rather than replacing the record itself. This is how the
   Java Disruptor works — the array of objects is allocated once and the JVM
   never needs to GC old event objects.

   In OCaml the GC already handles memory, but pre-allocation still matters:
   - No allocation on the hot path means no minor GC interruptions
   - Events stay in cache because the array is traversed sequentially
   - The record's fields can be read without pointer-chasing through the heap

   We make the event type polymorphic so the buffer can hold any record type.
   The caller supplies an [init] function that creates a fresh event for each
   slot at construction time. *)

module Event_rb = struct
  (* Each slot wraps the user's event in an Atomic so the slot pointer itself
     is atomically readable. The event's FIELDS are mutable — producers update
     them in place. This is a deliberate design: the slot reference never
     changes after construction, only the fields inside the event do. *)
  type 'a t = {
    mask  : int;
    slots : 'a Atomic.t array;
  }

  (* [make size init] creates a ring buffer of [size] slots.
     [init i] is called once per slot to create the pre-allocated event.
     The index [i] is passed so callers can set identity fields if needed.

     Example:
       type my_event = { mutable value: int; mutable kind: string }
       let buf = Event_rb.make 1024 (fun _ -> { value = 0; kind = "" }) *)
  let make size init =
    if not (is_power_of_two size) then
      invalid_arg (Printf.sprintf
        "Ring_buffer.Event_rb.make: size must be a power of 2, got %d" size);
    { mask  = size - 1;
      slots = Array.init size (fun i -> Atomic.make (init i)) }

  let size rb = rb.mask + 1

  (* [get rb sequence] returns the event object at [sequence]'s slot.
     The producer then mutates this object's fields directly.
     The consumer reads those fields after the barrier confirms availability. *)
  let get rb sequence =
    let i = index_of sequence rb.mask in
    Atomic.get rb.slots.(i)
end
