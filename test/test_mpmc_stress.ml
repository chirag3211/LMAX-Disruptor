(* test/test_mpmc_stress.ml — concurrent stress test for Queue_mpmc.
   Multiple producers and multiple consumers. Checks all items arrive exactly once. *)

let n_prod   = 4
let n_cons   = 4
let per_prod = 250_000
let cap      = 1024

let () =
  let q = Queue_mpmc.make cap in
  let sum_got = Atomic.make 0 in
  let count   = Atomic.make 0 in
  let total   = n_prod * per_prod in

  let producers = Array.init n_prod (fun id ->
    Domain.spawn (fun () ->
      let base = id * per_prod in
      for i = 0 to per_prod - 1 do
        let v = base + i in
        while not (Queue_mpmc.try_enqueue q v) do
          Domain.cpu_relax ()
        done
      done))
  in

  let consumers = Array.init n_cons (fun _ ->
    Domain.spawn (fun () ->
      let local_sum   = ref 0 in
      let local_count = ref 0 in
      while Atomic.get count < total do
        match Queue_mpmc.try_dequeue q with
        | Some v ->
          local_sum   := !local_sum + v;
          local_count := !local_count + 1;
          ignore (Atomic.fetch_and_add count 1)
        | None ->
          Domain.cpu_relax ()
      done;
      ignore (Atomic.fetch_and_add sum_got !local_sum);
      ignore !local_count))
  in

  Array.iter Domain.join producers;
  Array.iter Domain.join consumers;

  let expected_sum = total * (total - 1) / 2 in
  let got_sum      = Atomic.get sum_got in

  if got_sum <> expected_sum then begin
    Printf.eprintf "FAIL: sum=%d (expected %d)\n%!" got_sum expected_sum;
    exit 1
  end;
  Printf.printf "mpmc_stress (%d prod × %d cons × %d items): OK\n%!" n_prod n_cons per_prod
