(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2

let tests = "typing" >::: [Type_hint_test.tests]

let _handle =
  let one_gig = 1024 * 1024 * 1024 in
  SharedMem.(init ~num_workers:0 { heap_size = 5 * one_gig; hash_table_pow = 19; log_level = 0 })

let () = run_test_tt_main tests
