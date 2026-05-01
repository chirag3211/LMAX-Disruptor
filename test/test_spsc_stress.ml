(* test/test_spsc_stress.ml — concurrent stress test for Queue_spsc.
   One producer domain, one consumer domain, N items exchanged.
   Checks all items arrive in order and none are lost or duplicated. *)

let n_items = 1_000_000
let cap     = 1024

let () =
  let q = Queue_spsc.make cap in
  let consumed = ref [] in

  let producer = Domain.spawn (fun () ->
    for i = 0 to n_items - 1 do
      while not (Queue_spsc.try_enqueue q i) do
        Domain.cpu_relax ()
      done
    done)
  in

  let consumer = Domain.spawn (fun () ->
    for _ = 0 to n_items - 1 do
      let v = ref None in
      while !v = None do
        v := Queue_spsc.try_dequeue q;
        if !v = None then Domain.cpu_relax ()
      done;
      consumed := Option.get !v :: !consumed
    done)
  in

  Domain.join producer;
  Domain.join consumer;

  let got = List.rev !consumed in
  let expected = List.init n_items Fun.id in
  if got <> expected then begin
    Printf.eprintf "FAIL: mismatch (first diff at idx %d)\n%!"
      (let rec find i = function
         | [], _ | _, [] -> i
         | x :: xs, y :: ys -> if x = y then find (i+1) (xs,ys) else i
       in find 0 (got, expected));
    exit 1
  end;
  Printf.printf "spsc_queue stress (%d items): OK\n%!" n_items
