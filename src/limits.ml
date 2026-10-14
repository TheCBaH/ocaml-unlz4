[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

type t = {
  max_block_size : int;
  max_input : int64;
  max_output : int64;
  max_frames : int64;
  max_skipped : int64;
}

let mib4 = 4 * 1024 * 1024

let default =
  {
    max_block_size = mib4;
    max_input = Int64.max_int;
    max_output = Int64.max_int;
    max_frames = Int64.max_int;
    max_skipped = Int64.max_int;
  }

let make ?(max_block_size = mib4) ?(max_input = Int64.max_int) ?(max_output = Int64.max_int)
    ?(max_frames = Int64.max_int) ?(max_skipped = Int64.max_int) () =
  if max_block_size < 65536 then invalid_arg "Unlz4.Limits.make: max_block_size < 64 KiB";
  let nonneg name v = if Int64.compare v 0L < 0 then invalid_arg ("Unlz4.Limits.make: " ^ name) in
  nonneg "max_input" max_input;
  nonneg "max_output" max_output;
  nonneg "max_frames" max_frames;
  nonneg "max_skipped" max_skipped;
  { max_block_size; max_input; max_output; max_frames; max_skipped }

let with_max_output t max_output =
  if Int64.compare max_output 0L < 0 then invalid_arg "Unlz4.Limits.with_max_output";
  { t with max_output }
