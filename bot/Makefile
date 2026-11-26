# bot/Makefile -- the bot engine: the link, the core, botd, the tests
#
#   make            build/libbotcore.a, build/libbotlink.so, and build/bin/botd
#                   once core/engine.c exists (botd links the engine)
#   make test       build and run every tests/*_test.c
#   make tools      build/bin/<name> for every tools/<name>.c (bttree: look
#                   at a behaviour tree, check it, tune it: TREES.md)
#   make doc        write VOCAB.md, the vocabulary as a page, from the words
#                   as the core has them now (test fails when it is stale)
#
# Nothing here is listed by hand: every core/*.c is the core, every
# link/*.c the link, every botd/*.c the host, every tests/*_test.c a
# test with its own main(). Adding a file is adding a file.
CC ?= cc
CFLAGS ?= -O2 -g
STRICT = -std=c11 -Wall -Wextra -Werror -pedantic
INC = -Icore -Ilink -I../lsd/src
# The core holds the server's physics (../lsd/src/demoncore.c, below). A
# fused multiply-add would make a trajectory
# differ in its last bit from one compiler or machine to the next, and the
# core's tests pin trajectories exactly: no contraction anywhere in it.
CORE_FP = -ffp-contract=off
# A file of ../lsd/src is upstream's: it is compiled as upstream compiles
# it, in a unit of its own, under lsd/Makefile's warnings -- never under
# STRICT (its warnings differ from one compiler to the next, and they are
# upstream's to weigh). What it needs from the server's state.h is given
# by the header named for it (core/lsd_state.h for demoncore.c).
UPSTREAM_WARN = -Wall -Wextra -Wno-type-limits
UPSTREAM = $(B)/lsd/demoncore.o
B = build

CORE = $(wildcard core/*.c)
LINK = $(wildcard link/*.c)
BOTD = $(wildcard botd/*.c)
BOTD_LIB = $(patsubst botd/%.c,$(B)/botd/%.o,$(filter-out botd/main.c,$(BOTD)))
LINK_OBJ = $(patsubst link/%.c,$(B)/link/%.o,$(LINK))
TESTS = $(patsubst tests/%.c,$(B)/tests/%,$(wildcard tests/*_test.c))
TOOLS = $(patsubst tools/%.c,$(B)/bin/%,$(wildcard tools/*.c))

all: $(B)/libbotcore.a $(B)/libbotlink.so $(if $(and $(BOTD),$(wildcard core/engine.c)),$(B)/bin/botd)

$(B)/core/%.o: core/%.c $(wildcard core/*.h)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(STRICT) $(CORE_FP) $(INC) -c $< -o $@

$(B)/link/%.o: link/%.c $(wildcard link/*.h)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(STRICT) $(INC) -fPIC -D_POSIX_C_SOURCE=200809L -c $< -o $@

$(B)/botd/%.o: botd/%.c $(wildcard botd/*.h core/*.h link/*.h)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(STRICT) $(INC) -D_POSIX_C_SOURCE=200809L -c $< -o $@

$(B)/lsd/demoncore.o: ../lsd/src/demoncore.c $(wildcard ../lsd/src/*.h) core/lsd_state.h core/map.h
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(UPSTREAM_WARN) $(CORE_FP) $(INC) -include core/lsd_state.h -c $< -o $@

$(B)/libbotcore.a: $(patsubst core/%.c,$(B)/core/%.o,$(CORE)) $(UPSTREAM)
	@mkdir -p $(@D)
	rm -f $@ && ar rcs $@ $^

$(B)/libbotlink.so: $(patsubst link/%.c,$(B)/link/%.o,$(LINK))
	$(CC) $(CFLAGS) $(LDFLAGS) -shared -o $@ $^

$(B)/bin/botd: $(patsubst botd/%.c,$(B)/botd/%.o,$(BOTD)) $(LINK_OBJ) $(B)/libbotcore.a
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ -lm -lpthread

# a tool is one file with its own main(), over the core
$(B)/bin/%: tools/%.c $(B)/libbotcore.a
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(LDFLAGS) $(STRICT) $(INC) -D_POSIX_C_SOURCE=200809L $< $(B)/libbotcore.a -lm -o $@

tools: $(TOOLS)

# botd's test is the host with a fake engine of its own behind it: botd's
# files but main.c, the link, and no libbotcore.a
$(B)/tests/botd_test: tests/botd_test.c $(BOTD_LIB) $(LINK_OBJ) $(wildcard tests/*.h)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(LDFLAGS) $(STRICT) $(INC) -Ibotd -D_POSIX_C_SOURCE=200809L $< $(BOTD_LIB) $(LINK_OBJ) -lm -lpthread -o $@

# (and botd's pool: the bench and parallel_test run the planner's units on
# threads as botd does)
$(B)/tests/%: tests/%.c $(B)/libbotcore.a $(patsubst link/%.c,$(B)/link/%.o,$(LINK)) $(B)/botd/pool.o $(wildcard tests/*.h)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(LDFLAGS) $(STRICT) $(INC) -D_POSIX_C_SOURCE=200809L $< $(patsubst link/%.c,$(B)/link/%.o,$(LINK)) $(B)/botd/pool.o $(B)/libbotcore.a -lm -lpthread -o $@

# VOCAB.md is written by the tool from the words the core has
doc: $(B)/bin/bttree
	$(B)/bin/bttree --words --md > VOCAB.md

# the trees that ship must compile, with the vocabulary as it is now, and
# come back whole from the editor's JSON; the trees TREES.md and the
# tutorial (trees/README.md) show must compile too; and VOCAB.md must be
# the vocabulary of today
test: $(TESTS) $(B)/bin/bttree
	@fail=0; for t in $(TESTS); do echo "== $$t"; $$t || fail=1; done; \
	echo "== trees"; $(B)/bin/bttree --check trees/*.bt || fail=1; \
	echo "== trees, to JSON and back"; $(B)/bin/bttree --roundtrip trees/*.bt || fail=1; \
	echo "== the trees in TREES.md and in the tutorial"; $(B)/bin/bttree --doc TREES.md trees/README.md || fail=1; \
	echo "== VOCAB.md"; if $(B)/bin/bttree --words --md | cmp -s - VOCAB.md; then echo "ok: up to date"; \
	else echo "VOCAB.md is not the vocabulary of today: make -C bot doc"; fail=1; fi; exit $$fail

clean:
	rm -rf $(B)

.PHONY: all test tools doc clean
