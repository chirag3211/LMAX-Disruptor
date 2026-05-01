(* sequence.ml
   A monotonically increasing atomic integer, isolated on its own cache line.

   WHY CACHE LINE PADDING?
   Modern CPUs transfer memory in 64-byte cache lines. If two domains hold
   Atomic values that share a cache line, every write by one domain invalidates
   the entire line for all others — even though they are writing to different
   variables. This is called false sharing and can reduce throughput by 10x.

   Atomic.make_contended tells the OCaml runtime to allocate this value
   padded so that no other value shares its cache line. We use this for:
     - The producer's published-up-to sequence
     - Each consumer's consumed-up-to sequence
   These are written by different domains, so they MUST be on separate lines. *)

(* The initial "empty" sequence. We start at -1 so that the first published
   sequence number is 0, matching the first ring buffer slot index. *)
let initial = -1

(* A sequence is just a padded atomic int.
   We wrap it in a record so the type is distinct and self-documenting. *)
type t = { value : int Atomic.t }

(* Allocate a new sequence, padded to its own cache line. *)
let make n = { value = Atomic.make_contended n }

(* Read the current value. Uses the default (sequentially consistent) memory
   order, which is what we need: a consumer reading the producer's sequence
   must observe the actual published value, not a stale cached one. *)
let get s = Atomic.get s.value

(* Write a new value. Used by:
   - The single producer in SPSC mode (no CAS needed — only one writer)
   - Each consumer updating its own progress sequence *)
let set s n = Atomic.set s.value n

(* Compare-and-set. Used by multiple producers racing to claim the next slot.
   Returns true if the swap succeeded (this domain claimed the slot),
   false if another domain got there first (caller must retry). *)
let cas s expected desired =
  Atomic.compare_and_set s.value expected desired

(* Convenience: atomically add n and return the OLD value.
   Used by the multi-producer sequencer to claim a batch of slots at once. *)
let fetch_and_add s n =
  Atomic.fetch_and_add s.value n
