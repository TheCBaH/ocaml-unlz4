OPAM_EXEC = opam exec --
DUNE = $(OPAM_EXEC) dune
CC ?= cc

UPSTREAM = vendor/lz4
UPSTREAM_LIB = $(UPSTREAM)/lib
REF_BIN = test/reference/bin
REF_CFLAGS = -O2 -Wall -Wextra -I $(UPSTREAM_LIB)
CORPUS = test/corpus

.PHONY: deps build test test-js test-melange bench bench-js fmt fmt-check corpus-check \
	reference-build reference-test corpus-generate consumer-test release-test ci clean

# bytesrw is not a dependency of unlz4: it only enables the examples/bytesrw adapter and its tests.
deps:
	opam install . --deps-only --with-test -y
	opam install -y bytesrw

build:
	$(DUNE) build @all

test:
	$(DUNE) build @runtest

# The shared suites under js_of_ocaml and Node.
test-js:
	$(DUNE) build @runtest-jsoo

# The shared suites under Melange and Node, through the melange/ mirror (see melange/dune).
test-melange:
	UNLZ4_MELANGE=true $(DUNE) build @melange @runtest-melange

bench:
	$(DUNE) exec bench/bench.exe

bench-js:
	$(DUNE) build bench/bench.bc.js
	node _build/default/bench/bench.bc.js

fmt:
	$(DUNE) build @fmt --auto-promote

fmt-check:
	$(DUNE) build @fmt

# The checked-in corpus matches its digests; the embedding step also checks the manifest sizes.
corpus-check:
	cd $(CORPUS) && sha256sum --quiet -c SHA256SUMS
	$(DUNE) build test/support/corpus_data.ml

# Development targets below need the vendor/lz4 submodule and a C compiler:
#   git submodule update --init vendor/lz4

$(UPSTREAM_LIB)/lz4.c:
	@echo "vendor/lz4 is not initialized: git submodule update --init vendor/lz4" >&2
	@exit 1

reference-build: $(UPSTREAM_LIB)/lz4.c
	mkdir -p $(REF_BIN)
	$(CC) $(REF_CFLAGS) -o $(REF_BIN)/unlz4_ref test/reference/unlz4_ref.c \
	  $(UPSTREAM_LIB)/lz4.c $(UPSTREAM_LIB)/lz4hc.c $(UPSTREAM_LIB)/lz4frame.c $(UPSTREAM_LIB)/xxhash.c
	$(CC) $(REF_CFLAGS) -I $(UPSTREAM)/programs -o $(REF_BIN)/fuzzer $(UPSTREAM)/tests/fuzzer.c \
	  $(UPSTREAM)/programs/util.c $(UPSTREAM_LIB)/lz4.c $(UPSTREAM_LIB)/lz4hc.c $(UPSTREAM_LIB)/xxhash.c
	$(CC) $(REF_CFLAGS) -I $(UPSTREAM)/programs -o $(REF_BIN)/frametest $(UPSTREAM)/tests/frametest.c \
	  $(UPSTREAM)/programs/util.c $(UPSTREAM_LIB)/lz4.c $(UPSTREAM_LIB)/lz4hc.c \
	  $(UPSTREAM_LIB)/lz4frame.c $(UPSTREAM_LIB)/xxhash.c

# Bounded upstream self-tests: they validate the reference build, not this library.
reference-test: reference-build
	$(REF_BIN)/fuzzer -s1 -i100
	$(REF_BIN)/frametest -s1 -i100

# Regenerates the corpus from the pinned upstream. The result must match the checked-in corpus
# unless the generator or the pin changed; review `git diff test/corpus` after running it.
corpus-generate: reference-build
	rm -f $(CORPUS)/*
	$(REF_BIN)/unlz4_ref $(CORPUS) $$(git -C $(UPSTREAM) rev-parse HEAD)
	cd $(CORPUS) && export LC_ALL=C && sha256sum *.lz4 manifest.txt > SHA256SUMS

# Installs the package into a temporary prefix and builds a project that only knows it by its
# public name.
consumer-test:
	rm -rf _consumer && mkdir -p _consumer/prefix _consumer/project
	$(DUNE) build -p unlz4 @install
	$(DUNE) install --prefix=$(CURDIR)/_consumer/prefix unlz4
	cp test/consumer/dune-project test/consumer/dune test/consumer/consumer.ml _consumer/project/
	cd _consumer/project && OCAMLPATH=$(CURDIR)/_consumer/prefix/lib:$$OCAMLPATH \
	  $(DUNE) build --root . ./consumer.exe && ./_build/default/consumer.exe
	rm -rf _consumer

# Builds and tests a copy of the tracked (and new, unignored) files without vendor/: what a release
# archive contains.
release-test:
	rm -rf _release && mkdir -p _release
	git ls-files -z --cached --others --exclude-standard | grep -z -v '^vendor/' | \
	  xargs -0 cp --parents -t _release
	cd _release && test ! -e vendor/lz4/lib && $(DUNE) build -p unlz4 @install @runtest
	rm -rf _release

ci: fmt-check build test corpus-check

clean:
	$(DUNE) clean
	rm -rf $(REF_BIN) _consumer _release
