(* wait_strategy.ml
   Controls HOW a consumer waits when no events are available.

   This is one of the Disruptor's most important configurability points.
   The right strategy depends entirely on your workload:

   ┌─────────────┬──────────────┬──────────────┬───────────────┐
   │ Strategy    │ Latency      │ CPU usage    │ Best for      │
   ├─────────────┼──────────────┼──────────────┼───────────────┤
   │ Busy spin   │ Lowest       │ 100% always  │ ultra-low lat │
   │ Yielding    │ Low          │ High but <100│ low-lat batch │
   │ Blocking    │ Higher       │ Near zero    │ general use   │
   └─────────────┴──────────────┴──────────────┴───────────────┘

   WHY THIS MATTERS FOR THE RESEARCH QUESTION:
   In the Java Disruptor, BusySpin uses Thread.onSpinWait() which maps to
   the x86 PAUSE instruction. In OCaml 5 we use Domain.cpu_relax() which
   does the same thing. We benchmark all three to quantify the tradeoff. *)

type t =
  | BusySpin
    (* Pure spin. The consumer domain loops continuously checking the barrier.
       Lowest possible latency: the consumer sees a new event within
       nanoseconds of it being published. Cost: one full CPU core is
       consumed even when the queue is empty. *)

  | Yielding of { mutable spin_count : int }
    (* Spin for [max_spins] iterations, then yield the CPU. Yielding calls
       Domain.cpu_relax() in a tight loop to signal the CPU this is a spin
       wait (reduces power and memory pressure), then eventually yields
       to allow other OCaml domains to run. Balances latency and CPU use. *)

  | Blocking of {
      mutex     : Mutex.t;
      condition : Condition.t;
      mutable waiting : bool;
    }
    (* Block the consumer domain via a condition variable when no events
       are available. The producer signals the condition after publishing.
       Lowest CPU usage, but latency is bounded by OS scheduler wake-up
       time (~10–50µs), not hardware speed. *)

(* Construct a fresh wait strategy of the given type. *)
let make_busy_spin () = BusySpin

let make_yielding ?(max_spins = 100) () =
  Yielding { spin_count = max_spins }

let make_blocking () =
  Blocking {
    mutex     = Mutex.create ();
    condition = Condition.create ();
    waiting   = false;
  }

(* [wait t] is called by the sequence barrier when events are not yet
   available. It should pause briefly before the barrier retries. *)
let wait = function
  | BusySpin ->
    (* Hardware spin-wait hint. On x86 this emits PAUSE, which:
       - Reduces power consumption during the spin
       - Avoids the memory order violation penalty that a tight loop
         would otherwise cause on Intel CPUs *)
    Domain.cpu_relax ()

  | Yielding s ->
    if s.spin_count > 0 then begin
      s.spin_count <- s.spin_count - 1;
      Domain.cpu_relax ()
    end else begin
      (* Exhausted spins — reset the counter and keep relaxing.
         Domain.cpu_relax () emits the PAUSE instruction on x86, which
         signals to the CPU that this is a spin-wait loop. This reduces
         power consumption and avoids memory order speculation penalties.
         We do not use Thread.yield () here because that requires linking
         the separate 'threads' library; Domain.cpu_relax () is sufficient
         for our purposes and is always available in OCaml 5. *)
      s.spin_count <- 100;
      Domain.cpu_relax ()
    end

  | Blocking b ->
    Mutex.lock b.mutex;
    b.waiting <- true;
    (* Condition.wait atomically releases the lock and suspends the domain.
       It will be woken by [signal] below. *)
    Condition.wait b.condition b.mutex;
    b.waiting <- false;
    Mutex.unlock b.mutex

(* [signal t] is called by the producer after publishing, to wake any
   consumer that is blocked in the Blocking strategy.
   No-op for BusySpin and Yielding (consumer is already running). *)
let signal = function
  | Blocking b ->
    Mutex.lock b.mutex;
    if b.waiting then
      Condition.signal b.condition;
    Mutex.unlock b.mutex
  | BusySpin | Yielding _ -> ()