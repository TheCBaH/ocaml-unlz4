let () =
  exit
    (Unlz4_test_support.Harness.run ~backend:"melange (bytesrw)"
       Unlz4_bytesrw_tests.Test_bytesrw.cases)
