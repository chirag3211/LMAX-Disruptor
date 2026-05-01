(* test/test_spsc_smoke.ml — basic sanity checks for Spsc_queue *)

let () =
  let q = Queue_spsc.make 4 in

  (* empty queue *)
  assert (Queue_spsc.is_empty q);
  assert (Queue_spsc.try_dequeue q = None);

  (* fill it *)
  assert (Queue_spsc.try_enqueue q 10);
  assert (Queue_spsc.try_enqueue q 20);
  assert (Queue_spsc.try_enqueue q 30);
  assert (Queue_spsc.try_enqueue q 40);
  assert (Queue_spsc.is_full q);

  (* one more should fail *)
  assert (not (Queue_spsc.try_enqueue q 99));

  (* drain in order *)
  assert (Queue_spsc.try_dequeue q = Some 10);
  assert (Queue_spsc.try_dequeue q = Some 20);
  assert (Queue_spsc.try_dequeue q = Some 30);
  assert (Queue_spsc.try_dequeue q = Some 40);
  assert (Queue_spsc.try_dequeue q = None);
  assert (Queue_spsc.is_empty q);

  (* can reuse after draining *)
  assert (Queue_spsc.try_enqueue q 1);
  assert (Queue_spsc.try_dequeue q = Some 1);

  Printf.printf "spsc_queue smoke: OK\n%!"
