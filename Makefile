OPAM_EXEC = opam exec --
DUNE = $(OPAM_EXEC) dune

UPSTREAM = vendor/lz4
UPSTREAM_LIB = $(UPSTREAM)/lib

.PHONY: deps build test test-js test-melange bench bench-js fmt fmt-check \
	reference-test consumer-test release-test ci clean

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

# The test corpus and the upstream fuzzer/frametest are built by dune (test/reference/dune) from
# the vendor/lz4 submodule, so the tests need it initialized: git submodule update --init vendor/lz4

$(UPSTREAM_LIB)/lz4.c:
	@echo "vendor/lz4 is not initialized: git submodule update --init vendor/lz4" >&2
	@exit 1

# Bounded upstream self-tests: they validate the reference build, not this library.
reference-test: $(UPSTREAM_LIB)/lz4.c
	$(DUNE) build @reference-test

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

# Builds and tests a copy of the tracked (and new, unignored) files plus the vendor/lz4 submodule's:
# what a release archive must contain for its tests to run.
release-test: $(UPSTREAM_LIB)/lz4.c
	rm -rf _release && mkdir -p _release
	{ git ls-files -z --cached --others --exclude-standard | grep -z -v -x '$(UPSTREAM)'; \
	  git -C $(UPSTREAM) ls-files -z | sed -z 's|^|$(UPSTREAM)/|'; } | \
	  xargs -0 cp --parents -t _release
	cd _release && $(DUNE) build -p unlz4 @install @runtest
	rm -rf _release

ci: fmt-check build test

clean:
	$(DUNE) clean
	rm -rf _consumer _release
