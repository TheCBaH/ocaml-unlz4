let () =
  exit
    (Unlz4_test_support.Harness.run ~backend:"native"
       ~info:[ ("corpus", Unlz4_test_support.Corpus.summary ()) ]
       Unlz4_tests.cases)
