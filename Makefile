OPAM_EXEC = opam exec --
DUNE = $(OPAM_EXEC) dune

UPSTREAM = vendor/lz4
UPSTREAM_LIB = $(UPSTREAM)/lib

.PHONY: deps build test test-js test-melange bench bench-js fmt fmt-check \
	reference-test corpus-generate corpus-check consumer-test release-test ci clean

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

# The test corpus is checked in (test/corpus). Regenerating it, and the upstream fuzzer/frametest,
# need the vendor/lz4 submodule: git submodule update --init vendor/lz4

$(UPSTREAM_LIB)/lz4.c:
	@echo "vendor/lz4 is not initialized: git submodule update --init vendor/lz4" >&2
	@exit 1

# Bounded upstream self-tests: they validate the reference build, not this library.
reference-test: $(UPSTREAM_LIB)/lz4.c corpus-check
	UNLZ4_REFERENCE=true $(DUNE) build @reference-test

REF_EXE = _build/default/test/reference/unlz4_ref.exe

corpus-generate: $(UPSTREAM_LIB)/lz4.c
	UNLZ4_REFERENCE=true $(DUNE) build $(REF_EXE:_build/default/%=%)
	rm -rf test/corpus && mkdir test/corpus && $(REF_EXE) test/corpus

# Fails if the checked-in corpus differs from what the reference build generates.
corpus-check: $(UPSTREAM_LIB)/lz4.c
	UNLZ4_REFERENCE=true $(DUNE) build $(REF_EXE:_build/default/%=%)
	rm -rf _build/_corpus && mkdir _build/_corpus && $(REF_EXE) _build/_corpus && diff -r _build/_corpus test/corpus; r=$$?; rm -rf _build/_corpus; exit $$r

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

# Builds and tests the committed tree exactly as a release archive holds it: no submodule, so the
# tests must run from the checked-in corpus alone.
release-test:
	rm -rf _release && mkdir -p _release
	git archive HEAD | tar -x -C _release
	cd _release && $(DUNE) build --root . -p unlz4 @install @runtest
	rm -rf _release

ci: fmt-check build test

clean:
	$(DUNE) clean
	rm -rf _consumer _release
