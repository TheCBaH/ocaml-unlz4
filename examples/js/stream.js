// node stream.js FILE: decompresses FILE to stdout, reading it asynchronously in chunks.
const { createDecoder } = require("./unlz4_js.bc.js");
const fs = require("fs");

async function main(path) {
  const decoder = createDecoder();
  const write = (outs) => outs.forEach((o) => process.stdout.write(o));
  for await (const chunk of fs.createReadStream(path, { highWaterMark: 4096 })) {
    write(decoder.push(chunk));
  }
  write(decoder.finish());
}

main(process.argv[2]).catch((e) => {
  console.error(e.message);
  process.exit(1);
});
