(* test/test_mpsc_stress.ml — concurrent stress test for Queue_mpsc.
   Multiple producer domains, one consumer domain.
   Checks that every item produced is consumed exactly once. *)

let n_prod   = 4
let per_prod = 250_000     (* total items = n_prod * per_prod = 1M *)
let cap      = 1024

let () =
  let q = Queue_mpsc.make cap in
  let received = Atomic.make 0 in
  let sum_got  = Atomic.make 0 in

  (* Each producer sends [per_prod] distinct values in its own range *)
  let producers = Array.init n_prod (fun id ->
    Domain.spawn (fun () ->
      let base = id * per_prod in
      for i = 0 to per_prod - 1 do
        let v = base + i in
        while not (Queue_mpsc.try_enqueue q v) do
          Domain.cpu_relax ()
        done
      done))
  in

  let total = n_prod * per_prod in

  let consumer = Domain.spawn (fun () ->
    let count = ref 0 in
    while !count < total do
      match Queue_mpsc.try_dequeue q with
      | Some v ->
        ignore (Atomic.fetch_and_add sum_got v);
        incr count
      | None ->
        Domain.cpu_relax ()
    done;
    Atomic.set received !count)
  in

  Array.iter Domain.join producers;
  Domain.join consumer;

  let expected_sum = total * (total - 1) / 2 in
  let got_sum      = Atomic.get sum_got in
  let got_count    = Atomic.get received in

  if got_count <> total || got_sum <> expected_sum then begin
    Printf.eprintf "FAIL: count=%d (expected %d), sum=%d (expected %d)\n%!"
      got_count total got_sum expected_sum;
    exit 1
  end;
  Printf.printf "mpsc_queue stress (%d producers × %d items): OK\n%!" n_prod per_prod
