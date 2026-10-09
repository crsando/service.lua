# service.lua
#
#   make                  build $(BUILD)/service_c.so
#   make test             run the default test suite
#   make test-tsan        run C tests under ThreadSanitizer
#   make install          install to $(DESTDIR)$(PREFIX)
#   make clean            remove $(BUILD)

PREFIX  ?= /usr/local
DESTDIR ?=
BUILD   ?= build

CFLAGS  ?= -O2 -g -Wall
LUAINC  ?= $(shell pkg-config --cflags luajit 2>/dev/null || echo -I/usr/local/include/luajit-2.1)
LIBS    := -lluajit-5.1 -luv -lpthread -ldl

TEST_CFLAGS := -std=c11 -Wall -Wextra -Wpedantic
TSAN_CFLAGS := $(TEST_CFLAGS) -O1 -g -fsanitize=thread -fno-pie -no-pie
LUA_ENV     := env LUA_PATH='./lua/?.lua;;' LUA_CPATH='./$(BUILD)/?.so;;'
RUN         := timeout 10s $(LUA_ENV) luajit

MODULE := $(BUILD)/service_c.so
SRCS   := src/lservice.c src/service.c src/loadluv.c src/mailbox.c \
          src/message.c src/lua-seri.c src/log.c
HDRS   := $(wildcard src/*.h)

MAILBOX_SRCS := tests/c/mailbox_test.c src/mailbox.c src/message.c
SERVICE_SRCS := tests/c/service_lifecycle_test.c src/service.c src/loadluv.c \
                src/mailbox.c src/message.c src/log.c
SERVICE_DEFS := -D_POSIX_C_SOURCE=200809L -DLUV_LOADER_TESTING

LUA_SPECS := serializer_spec serializer_shared_ref_spec lifecycle_spec \
             mailbox_spec rpc_spec rpc_cross_service_spec dispatch_batch_spec \
             table_source_spec bootstrap_spec scheduler_spec scheduler_daily_spec

.PHONY: all test test-contract test-mailbox test-service test-lua \
        test-scheduler test-examples test-regression test-tsan install clean

all: $(MODULE)

$(BUILD):
	mkdir -p $@

$(MODULE): $(SRCS) $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) -shared -fPIC $(LUAINC) -Isrc -o $@ $(SRCS) $(LIBS)

# Standalone serializer module used by the contract test.
$(BUILD)/seri.so: src/lua-seri.c src/lua-seri.h | $(BUILD)
	$(CC) $(CFLAGS) -DTEST_SERI -shared -fPIC $(LUAINC) -Isrc -o $@ $< -lluajit-5.1

$(BUILD)/message_abi_test: tests/contract/message_abi_test.c src/message.h | $(BUILD)
	$(CC) $(TEST_CFLAGS) -Isrc -o $@ $<

$(BUILD)/mailbox_test: $(MAILBOX_SRCS) $(HDRS) | $(BUILD)
	$(CC) $(TEST_CFLAGS) -Isrc -o $@ $(MAILBOX_SRCS) -lpthread

$(BUILD)/service_lifecycle_test: $(SERVICE_SRCS) $(HDRS) | $(BUILD)
	$(CC) $(TEST_CFLAGS) $(SERVICE_DEFS) $(LUAINC) -Isrc -o $@ $(SERVICE_SRCS) $(LIBS)

$(BUILD)/mailbox_test_tsan: $(MAILBOX_SRCS) $(HDRS) | $(BUILD)
	$(CC) $(TSAN_CFLAGS) -Isrc -o $@ $(MAILBOX_SRCS) -lpthread

$(BUILD)/service_lifecycle_test_tsan: $(SERVICE_SRCS) $(HDRS) | $(BUILD)
	$(CC) $(TSAN_CFLAGS) $(SERVICE_DEFS) $(LUAINC) -Isrc -o $@ $(SERVICE_SRCS) $(LIBS)

test: test-contract test-mailbox test-service test-lua test-examples

test-contract: $(MODULE) $(BUILD)/seri.so $(BUILD)/message_abi_test
	$(LUA_ENV) luajit tests/contract/api_surface_spec.lua
	$(LUA_ENV) luajit tests/contract/serializer_module_spec.lua
	$(BUILD)/message_abi_test

test-mailbox: $(BUILD)/mailbox_test
	$<

test-service: $(MODULE) $(BUILD)/service_lifecycle_test
	$(LUA_ENV) $(BUILD)/service_lifecycle_test

test-lua: $(MODULE)
	@set -e; for spec in $(LUA_SPECS); do \
		echo "$(RUN) tests/lua/$$spec.lua"; \
		$(RUN) tests/lua/$$spec.lua; \
	done

test-scheduler: $(MODULE)
	$(RUN) tests/lua/scheduler_spec.lua
	$(RUN) tests/lua/scheduler_daily_spec.lua

# Each example must exit on its own and print its final line.
test-examples: $(MODULE)
	$(RUN) examples/demo.lua > $(BUILD)/demo.out
	grep -qx 'root: done' $(BUILD)/demo.out
	$(RUN) examples/scheduler.lua > $(BUILD)/scheduler.out
	grep -q '^at(UTC): fired' $(BUILD)/scheduler.out

test-regression: $(MODULE)
	$(RUN) tests/lua/serializer_shared_ref_spec.lua

# libuv's io_uring setup (fd + mmap in uninstrumented code) makes TSAN report
# false races between concurrent uv_loop_init calls, so disable it here.
TSAN_ENV := env TSAN_OPTIONS=halt_on_error=1 UV_USE_IO_URING=0

test-tsan: $(MODULE) $(BUILD)/mailbox_test_tsan $(BUILD)/service_lifecycle_test_tsan
	setarch $$(uname -m) -R $(TSAN_ENV) $(BUILD)/mailbox_test_tsan
	$(LUA_ENV) setarch $$(uname -m) -R $(TSAN_ENV) $(BUILD)/service_lifecycle_test_tsan

install: $(MODULE)
	install -d $(DESTDIR)$(PREFIX)/lib/lua/5.1 $(DESTDIR)$(PREFIX)/share/lua/5.1/service
	install -m 755 $(MODULE) $(DESTDIR)$(PREFIX)/lib/lua/5.1/
	install -m 644 lua/service.lua $(DESTDIR)$(PREFIX)/share/lua/5.1/
	install -m 644 lua/service/scheduler.lua $(DESTDIR)$(PREFIX)/share/lua/5.1/service/

clean:
	rm -rf $(BUILD)
