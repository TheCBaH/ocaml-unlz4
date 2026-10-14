[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

let () =
  exit
    (Unlz4_test_support.Harness.run ~backend:"melange"
       ~info:[ ("corpus", Unlz4_test_support.Corpus.summary ()) ]
       Unlz4_tests.cases)
