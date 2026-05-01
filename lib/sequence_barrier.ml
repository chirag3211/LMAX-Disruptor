(* sequence_barrier.ml
   The sequence barrier is what consumers use to wait for events.

   There are two kinds of barrier depending on the sequencer type:

   SPSC barrier:
     The producer publishes in order, so "available" = producer cursor.
     Simple atomic read suffices.

   Multi-producer barrier:
     Producers publish out of order, so we cannot just read the cursor.
     We must scan the available_buffer to find the highest CONTIGUOUSLY
     published sequence. The sequencer provides [highest_published_seq]
     for this purpose.

   We model this with a variant type so the consumer loop is identical
   regardless of which sequencer is in use. *)

type sequencer_kind =
  | Spsc of Sequence.t
    (* Just hold the producer cursor — available = cursor value *)
  | Multiproducer of Disruptor_sequencer_mpsc.t
    (* Must scan available_buffer for highest contiguous published seq *)

type t = {
  kind           : sequencer_kind;
  dependent_seqs : Sequence.t list;
  wait_strategy  : Wait_strategy.t;
}

let make_spsc ~producer_cursor ~dependent_seqs ~wait_strategy =
  { kind = Spsc producer_cursor; dependent_seqs; wait_strategy }

let make_mp ~sequencer ~dependent_seqs ~wait_strategy =
  { kind = Multiproducer sequencer; dependent_seqs; wait_strategy }

let producer_cursor t =
  match t.kind with
  | Spsc cursor       -> cursor
  | Multiproducer mp  -> Disruptor_sequencer_mpsc.cursor mp

let min_of_sequences seqs =
  List.fold_left
    (fun acc s -> min acc (Sequence.get s))
    max_int
    seqs

exception Shutdown

(* [wait_for t needed running] blocks until [needed] is available.
   Returns the highest contiguously available sequence >= needed.
   Raises Shutdown if [running] becomes false while waiting. *)
let wait_for t needed running =
  let rec spin () =
    if not (Atomic.get running) then raise Shutdown;
    (* Step 1: how far has the producer published (or cursor advanced)? *)
    let upper =
      match t.kind with
      | Spsc cursor ->
        Sequence.get cursor
      | Multiproducer mp ->
        (* Cursor tells us the highest CLAIMED sequence.
           highest_published_seq scans to find highest PUBLISHED. *)
        let claimed = Sequence.get (Disruptor_sequencer_mpsc.cursor mp) in
        Disruptor_sequencer_mpsc.highest_published_seq mp needed claimed
    in
    (* Step 2: also constrain by upstream consumers (pipeline deps) *)
    let available =
      if t.dependent_seqs = [] then upper
      else min upper (min_of_sequences t.dependent_seqs)
    in
    if available >= needed then
      available
    else begin
      Wait_strategy.wait t.wait_strategy;
      spin ()
    end
  in
  spin ()
