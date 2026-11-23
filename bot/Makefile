# bot/Makefile -- the bot engine: the link, the core, botd, the tests
#
#   make            build/libbotcore.a, build/libbotlink.so, build/botd
#   make test       build and run every tests/*_test.c
#
# Nothing here is listed by hand: every core/*.c is the core, every
# link/*.c the link, every botd/*.c the host, every tests/*_test.c a
# test with its own main(). Adding a file is adding a file.
CC ?= cc
CFLAGS ?= -O2 -g
STRICT = -std=c11 -Wall -Wextra -Werror -pedantic
INC = -Icore -Ilink -I../lsd/src
B = build

CORE = $(wildcard core/*.c)
LINK = $(wildcard link/*.c)
BOTD = $(wildcard botd/*.c)
TESTS = $(patsubst tests/%.c,$(B)/tests/%,$(wildcard tests/*_test.c))

all: $(B)/libbotcore.a $(B)/libbotlink.so $(if $(BOTD),$(B)/botd)

$(B)/core/%.o: core/%.c $(wildcard core/*.h)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(STRICT) $(INC) -c $< -o $@

$(B)/link/%.o: link/%.c $(wildcard link/*.h)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(STRICT) $(INC) -fPIC -D_POSIX_C_SOURCE=200809L -c $< -o $@

$(B)/botd/%.o: botd/%.c $(wildcard botd/*.h core/*.h link/*.h)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(STRICT) $(INC) -D_POSIX_C_SOURCE=200809L -c $< -o $@

$(B)/libbotcore.a: $(patsubst core/%.c,$(B)/core/%.o,$(CORE))
	@mkdir -p $(@D)
	rm -f $@ && ar rcs $@ $^

$(B)/libbotlink.so: $(patsubst link/%.c,$(B)/link/%.o,$(LINK))
	$(CC) -shared -o $@ $^

$(B)/botd: $(patsubst botd/%.c,$(B)/botd/%.o,$(BOTD)) $(patsubst link/%.c,$(B)/link/%.o,$(LINK)) $(B)/libbotcore.a
	$(CC) -o $@ $^ -lm -lpthread

$(B)/tests/%: tests/%.c $(B)/libbotcore.a $(patsubst link/%.c,$(B)/link/%.o,$(LINK)) $(wildcard tests/*.h)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(STRICT) $(INC) -D_POSIX_C_SOURCE=200809L $< $(patsubst link/%.c,$(B)/link/%.o,$(LINK)) $(B)/libbotcore.a -lm -lpthread -o $@

test: $(TESTS)
	@fail=0; for t in $(TESTS); do echo "== $$t"; $$t || fail=1; done; exit $$fail

clean:
	rm -rf $(B)

.PHONY: all test clean
