
open OUnitTypes

(* Preliminary implementation of threaded version of the runner, see TODO in the
 * code for remaining pieces to fix.
 *)

let thread_pool_threshold =
  OUnitConf.make
    "thread_pool_threshold"
    (fun r -> Arg.Set_int r)
    ~printer:string_of_int
    10
    "Under this limit, create exactly one thread by test (threads-runner)."

let thread_pool_size =
  OUnitConf.make
    "thread_pool_size"
    (fun r -> Arg.Set_int r)
    ~printer:string_of_int
    15
    "Max number of concurrent threads (threads-runner)."

(* TODO: make logger thread safe.
 * 2 ways to do it:
 * - create a specific logger (fun_logger), that will accumulate data and
 *   merge the results at the end of the test in the main thread that
 *   holds the real logger
 * - put a big lock on the logger to prevent 2 threads to write at the
 *   same time.
 *)

(* Run all test, threaded version *)
let run_all_tests logger chooser test_cases =
  (* perform_test.run_test_case equivalent *)
  let thread_run test_fun =
    try
      test_fun ();
      RSuccess
    with e -> 
      (* No backtraces because I suspect them to not be thread-safe. *)
      match e with
        | Failure s -> RFailure (s, None)
        | Skip s -> RSkip s
        | Todo s -> RTodo s 
        | s -> RError (Printexc.to_string s, None)
  in

  (* Thread-wide synchronization. *)
  let thread_main (wait_chan, result_chan) =
    while true do
      let event = Event.receive wait_chan in
      let (test_path, test_fun) = Event.sync event in
      OUnitLogger.report logger (TestEvent (test_path, EStart));
      let test_res = thread_run test_fun in
        Event.sync (Event.send result_chan (test_path, test_res))
    done
  in

  (* Application-wide synchronization, end of perfom_test.runner equivalent *)
  let synchronizer_main (test_number, result_chan, suite_result_chan) =
    let i = ref test_number and l = ref [] in
    while !i > 0 do
      let (path, res) = Event.sync (Event.receive result_chan) in
        OUnitLogger.report logger (TestEvent (path, (EResult res)));
        OUnitLogger.report logger (TestEvent (path, EEnd));
        l := (path, res, None)::!l;
        decr i
    done;
    Event.sync (Event.send suite_result_chan !l)
  in

  (* Beginning of preform_test.runn equivalent, wait results from synchronizer. *)
  let rec schedule wait_chan suite_result_chan = function
    | [] -> Event.sync (Event.receive suite_result_chan)
    | test::tests_planned ->
        Event.sync (Event.send wait_chan test);
        schedule wait_chan suite_result_chan tests_planned
  in
  (* Init channels to pass values with easy synchronization. *)
  let len = List.length test_cases in
  
  (* Threads will get tests by there. *)
  let wait_chan = Event.new_channel () in
  (* Threads will send test result here. *)
  let result_chan = Event.new_channel () in

  (* Test results will be aggregated here. *)
  let suite_result_chan = Event.new_channel () in

  (* Init our threads: a pool, a scheduler that dispatches tests, *)
  (* and a synchronizer that aggregates result and call the logger. *)
  let pool_size = 
    if len < thread_pool_threshold () then
      len 
    else
      thread_pool_size ()
  in
  let _thrd = 
    Thread.create synchronizer_main (len, result_chan, suite_result_chan)
  in
    for i = 0 to pool_size do
      let _thrd = 
        Thread.create thread_main (wait_chan, result_chan)
      in
        ()
    done;
    schedule wait_chan suite_result_chan test_cases

