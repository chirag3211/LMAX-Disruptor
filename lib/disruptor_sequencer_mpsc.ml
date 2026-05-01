(* disruptor_sequencer_mpsc.ml — Multi-Producer sequencer for the Disruptor pipeline. *)

let log2 n =
  let rec aux n acc = if n <= 1 then acc else aux (n lsr 1) (acc + 1) in
  aux n 0

type t = {
  buffer_size      : int;
  mask             : int;
  index_shift      : int;
  cursor           : Sequence.t;
  available_buffer : int Atomic.t array;
  gating_seqs      : Sequence.t list Atomic.t;
  (* FIX: was [mutable int], which caused a data race when multiple producer
     domains concurrently read and wrote this field without synchronisation.
     TSAN flagged: write by T6 / previous read by T4 at sequencer_mp.ml:123.

     Making it Atomic.t means all reads and writes go through the CPU's
     atomic load/store instructions, providing the necessary visibility
     guarantee across domains. The cached value is just an optimisation
     hint — it is always safe to read a slightly stale value here because
     we only use it to avoid an unnecessary scan of gating_seqs. If two
     domains race and both see a stale value, the worst outcome is that
     both do the more expensive min_gating_seq scan — correctness is
     preserved either way. *)
  cached_gating_min : int Atomic.t;
}

let make buffer_size =
  if not (buffer_size > 0 && buffer_size land (buffer_size - 1) = 0) then
    invalid_arg "Sequencer_mp.make: buffer_size must be a power of 2";
  { buffer_size;
    mask              = buffer_size - 1;
    index_shift       = log2 buffer_size;
    cursor            = Sequence.make Sequence.initial;
    available_buffer  = Array.init buffer_size (fun _ -> Atomic.make (-1));
    gating_seqs       = Atomic.make [];
    cached_gating_min = Atomic.make Sequence.initial; }

let add_gating_sequence t seq =
  let rec update () =
    let current = Atomic.get t.gating_seqs in
    let next = seq :: current in
    if not (Atomic.compare_and_set t.gating_seqs current next)
    then update ()
  in
  update ()

let min_gating_seq t =
  List.fold_left
    (fun acc s -> min acc (Sequence.get s))
    max_int
    (Atomic.get t.gating_seqs)

let next t n =
  let hi = Sequence.fetch_and_add t.cursor n + n in
  let lo = hi - n + 1 in
  let wrap_point = hi - t.buffer_size in
  (* Read cached value atomically — no race *)
  if wrap_point > Atomic.get t.cached_gating_min then begin
    let rec spin () =
      let gating_min = min_gating_seq t in
      (* Write cached value atomically — no race.
         Note: multiple producers may write this concurrently — that is
         fine because it is only a cache. The last writer wins, and all
         written values are valid observations of the gating minimum.
         We use plain set (not CAS) because we do not need to guard
         against overwriting a fresher value — any recent observation
         of min_gating_seq is acceptable as a cached hint. *)
      Atomic.set t.cached_gating_min gating_min;
      if wrap_point > gating_min then begin
        Domain.cpu_relax ();
        spin ()
      end
    in
    spin ()
  end;
  (lo, hi)

let publish t sequence =
  let i = sequence land t.mask in
  let cycle = sequence asr t.index_shift in
  Atomic.set t.available_buffer.(i) cycle

let publish_range t lo hi =
  for seq = lo to hi do
    publish t seq
  done

let highest_published_seq t next_seq available_seq =
  let rec scan seq =
    if seq > available_seq then available_seq
    else
      let i = seq land t.mask in
      let cycle = seq asr t.index_shift in
      if Atomic.get t.available_buffer.(i) = cycle then
        scan (seq + 1)
      else
        seq - 1
  in
  scan next_seq

let cursor t = t.cursor