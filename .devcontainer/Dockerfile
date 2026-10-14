ARG VARIANT=13
FROM debian:${VARIANT}
# gcc builds the upstream reference tools (make reference-build); python3 is needed to build
# melange-bigarray. Node runs the js_of_ocaml and Melange suites and is installed for the 64-bit
# hosts only: the 32-bit CI legs run the native suite, which is what proves 31-bit int safety.
RUN set -eux;\
    apt-get update;\
    case "$(dpkg --print-architecture)" in\
      amd64|arm64) extra='nodejs' ;;\
      *) extra='' ;;\
    esac;\
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends\
  ca-certificates\
  curl\
  gcc\
  git\
  libc6-dev\
  make\
  python3\
  $extra\
;\
    apt-get autoremove -y; apt-get clean -y; rm -rf /var/lib/apt/lists/*;\
    echo DONE
