# service.lua
#
#   make                  build $(BUILD)/service_c.so
#   make test             run the default test suite
#   make test-tsan        run C tests under ThreadSanitizer
#   make install          install to $(DESTDIR)$(PREFIX)
#   make clean            remove $(BUILD)
#   make config           show detected platform, paths and flags
#
# Works on Linux (incl. WSL) and macOS. Written for GNU Make 3.81, which is
# what macOS ships, so no newer make features are used.
#
# Everything below can be overridden on the command line, e.g.
#   make PREFIX=/opt/foo LUAJIT=/path/to/luajit

# ---------------------------------------------------------------- platform --

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
PLATFORM := macos
else
PLATFORM := linux
endif

LUAJIT     ?= luajit
PKG_CONFIG ?= pkg-config

# Install next to the luajit that will load the module: /opt/homebrew with
# Homebrew on Apple Silicon, /usr/local for a source build on Linux.
LUAJIT_BIN    := $(shell command -v $(LUAJIT) 2>/dev/null)
LUAJIT_PREFIX := $(patsubst %/bin/,%,$(dir $(LUAJIT_BIN)))
ifeq ($(strip $(LUAJIT_PREFIX)),)
LUAJIT_PREFIX := /usr/local
endif

PREFIX       ?= $(LUAJIT_PREFIX)
DESTDIR      ?=
LUA_LIBDIR   ?= $(PREFIX)/lib/lua/5.1
LUA_SHAREDIR ?= $(PREFIX)/share/lua/5.1
BUILD        ?= build

# ---------------------------------------------------------- dependencies --

# Ask pkg-config once; fall back to the usual prefix layout without it.
HAVE_PC_LUAJIT := $(shell $(PKG_CONFIG) --exists luajit 2>/dev/null && echo y)
HAVE_PC_LIBUV  := $(shell $(PKG_CONFIG) --exists libuv 2>/dev/null && echo y)

ifeq ($(HAVE_PC_LUAJIT),y)
LUAJIT_CFLAGS := $(shell $(PKG_CONFIG) --cflags luajit)
LUAJIT_LIBS   := $(shell $(PKG_CONFIG) --libs luajit)
else
LUAJIT_CFLAGS := -I$(LUAJIT_PREFIX)/include/luajit-2.1
LUAJIT_LIBS   := -L$(LUAJIT_PREFIX)/lib -lluajit-5.1
endif

ifeq ($(HAVE_PC_LIBUV),y)
LIBUV_CFLAGS := $(shell $(PKG_CONFIG) --cflags libuv)
LIBUV_LIBS   := $(shell $(PKG_CONFIG) --libs libuv)
else
LIBUV_CFLAGS := -I$(LUAJIT_PREFIX)/include
LIBUV_LIBS   := -L$(LUAJIT_PREFIX)/lib -luv -lpthread
endif

# ------------------------------------------------------------ build flags --

CFLAGS ?= -O2 -g -Wall
LUAINC ?= $(LUAJIT_CFLAGS) $(LIBUV_CFLAGS)

# Lua modules (service_c.so, seri.so) must NOT link libluajit: the host
# luajit process provides lua_* symbols at load time. Linking it pins the
# module to one particular libluajit and loads a second VM copy elsewhere.
# On Linux undefined symbols in a shared object are allowed by default; on
# macOS they have to be requested explicitly.
ifeq ($(PLATFORM),macos)
MODULE_LDFLAGS ?= -bundle -undefined dynamic_lookup
SYS_LIBS       :=
else
MODULE_LDFLAGS ?= -shared
# dlopen() lives in libdl and clock_gettime() in librt on glibc < 2.34.
SYS_LIBS       := -ldl -lrt
endif

# pkg-config for libuv may already list -ldl/-lrt; don't repeat them.
EXTRA_SYS_LIBS := $(filter-out $(LIBUV_LIBS),$(SYS_LIBS))

MODULE_LIBS ?= $(LIBUV_LIBS) $(EXTRA_SYS_LIBS)

# Standalone test executables embed their own VM, so they do link libluajit.
LIBS ?= $(LUAJIT_LIBS) $(LIBUV_LIBS) $(EXTRA_SYS_LIBS)

TEST_CFLAGS := -std=c11 -Wall -Wextra -Wpedantic

# ThreadSanitizer: Linux needs a non-PIE binary and ASLR off (setarch -R);
# macOS supports TSAN on PIE binaries and has no setarch.
ifeq ($(PLATFORM),macos)
TSAN_CFLAGS := $(TEST_CFLAGS) -O1 -g -fsanitize=thread
TSAN_RUN    :=
else
TSAN_CFLAGS := $(TEST_CFLAGS) -O1 -g -fsanitize=thread -fno-pie -no-pie
TSAN_RUN    := setarch $(shell uname -m) -R
endif

# ------------------------------------------------------------- test runner --

# GNU timeout is standard on Linux; on macOS it comes from coreutils as
# gtimeout (newer Homebrew also links it as timeout). Without either, tests
# still run, just without the per-spec time limit.
TIMEOUT_BIN := $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
ifeq ($(strip $(TIMEOUT_BIN)),)
TIMEOUT :=
else
TIMEOUT := $(TIMEOUT_BIN) 10s
endif

LUA_ENV := env LUA_PATH='./lua/?.lua;;' LUA_CPATH='./$(BUILD)/?.so;;'
RUN     := $(TIMEOUT) $(LUA_ENV) $(LUAJIT)

MODULE := $(BUILD)/service_c.so
SRCS   := src/lservice.c src/service.c src/loadluv.c src/mailbox.c \
          src/message.c src/lua-seri.c src/log.c
HDRS   := $(wildcard src/*.h)

MAILBOX_SRCS := tests/c/mailbox_test.c src/mailbox.c src/message.c
LOG_SRCS     := tests/c/log_test.c src/log.c
SERVICE_SRCS := tests/c/service_lifecycle_test.c src/service.c src/loadluv.c \
                src/mailbox.c src/message.c src/log.c
SERVICE_DEFS := -D_POSIX_C_SOURCE=200809L -DLUV_LOADER_TESTING

LUA_SPECS := serializer_spec serializer_shared_ref_spec lifecycle_spec \
             mailbox_spec rpc_spec rpc_cross_service_spec dispatch_batch_spec \
             table_source_spec bootstrap_spec root_spec idle_hook_spec log_spec stop_reply_spec \
             scheduler_spec scheduler_daily_spec

.PHONY: all test test-contract test-mailbox test-log test-service test-lua \
        test-scheduler test-examples test-regression test-tsan install clean config

all: $(MODULE)

$(BUILD):
	mkdir -p $@

$(MODULE): $(SRCS) $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) $(MODULE_LDFLAGS) -fPIC $(LUAINC) -Isrc -o $@ $(SRCS) $(MODULE_LIBS)

# Standalone serializer module used by the contract test.
$(BUILD)/seri.so: src/lua-seri.c src/lua-seri.h | $(BUILD)
	$(CC) $(CFLAGS) -DTEST_SERI $(MODULE_LDFLAGS) -fPIC $(LUAINC) -Isrc -o $@ $<

$(BUILD)/message_abi_test: tests/contract/message_abi_test.c src/message.h | $(BUILD)
	$(CC) $(TEST_CFLAGS) -Isrc -o $@ $<

$(BUILD)/mailbox_test: $(MAILBOX_SRCS) $(HDRS) | $(BUILD)
	$(CC) $(TEST_CFLAGS) -Isrc -o $@ $(MAILBOX_SRCS) -lpthread

$(BUILD)/log_test: $(LOG_SRCS) $(HDRS) | $(BUILD)
	$(CC) $(TEST_CFLAGS) -Isrc -o $@ $(LOG_SRCS) -lpthread

$(BUILD)/service_lifecycle_test: $(SERVICE_SRCS) $(HDRS) | $(BUILD)
	$(CC) $(TEST_CFLAGS) $(SERVICE_DEFS) $(LUAINC) -Isrc -o $@ $(SERVICE_SRCS) $(LIBS)

$(BUILD)/mailbox_test_tsan: $(MAILBOX_SRCS) $(HDRS) | $(BUILD)
	$(CC) $(TSAN_CFLAGS) -Isrc -o $@ $(MAILBOX_SRCS) -lpthread

$(BUILD)/log_test_tsan: $(LOG_SRCS) $(HDRS) | $(BUILD)
	$(CC) $(TSAN_CFLAGS) -Isrc -o $@ $(LOG_SRCS) -lpthread

$(BUILD)/service_lifecycle_test_tsan: $(SERVICE_SRCS) $(HDRS) | $(BUILD)
	$(CC) $(TSAN_CFLAGS) $(SERVICE_DEFS) $(LUAINC) -Isrc -o $@ $(SERVICE_SRCS) $(LIBS)

test: test-contract test-mailbox test-log test-service test-lua test-examples

test-contract: $(MODULE) $(BUILD)/seri.so $(BUILD)/message_abi_test
	$(LUA_ENV) $(LUAJIT) tests/contract/api_surface_spec.lua
	$(LUA_ENV) $(LUAJIT) tests/contract/serializer_module_spec.lua
	$(BUILD)/message_abi_test

test-mailbox: $(BUILD)/mailbox_test
	$<

# The logger reads its defaults from the environment.
LOG_TEST_ENV := env -u SERVICE_LOG_LEVEL -u SERVICE_LOG_FORMAT -u JOURNAL_STREAM

test-log: $(BUILD)/log_test
	$(LOG_TEST_ENV) $<

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
	$(RUN) service/root.lua hi > $(BUILD)/demo.out
	grep -qx 'root: booting, greeting = hi' $(BUILD)/demo.out
	grep -qx 'root: done' $(BUILD)/demo.out
	$(RUN) examples/scheduler.lua > $(BUILD)/scheduler.out
	grep -q '^at(UTC): fired' $(BUILD)/scheduler.out

test-regression: $(MODULE)
	$(RUN) tests/lua/serializer_shared_ref_spec.lua

# libuv's io_uring setup (fd + mmap in uninstrumented code) makes TSAN report
# false races between concurrent uv_loop_init calls, so disable it here.
TSAN_ENV := env TSAN_OPTIONS=halt_on_error=1 UV_USE_IO_URING=0

test-tsan: $(MODULE) $(BUILD)/mailbox_test_tsan $(BUILD)/log_test_tsan \
           $(BUILD)/service_lifecycle_test_tsan
	$(TSAN_RUN) $(TSAN_ENV) $(BUILD)/mailbox_test_tsan
	$(LOG_TEST_ENV) $(TSAN_RUN) $(TSAN_ENV) $(BUILD)/log_test_tsan
	$(LUA_ENV) $(TSAN_RUN) $(TSAN_ENV) $(BUILD)/service_lifecycle_test_tsan

install: $(MODULE)
	install -d $(DESTDIR)$(LUA_LIBDIR) $(DESTDIR)$(LUA_SHAREDIR)/service
	install -m 755 $(MODULE) $(DESTDIR)$(LUA_LIBDIR)/
	install -m 644 lua/service.lua $(DESTDIR)$(LUA_SHAREDIR)/
	install -m 644 lua/service/scheduler.lua lua/service/root.lua \
		$(DESTDIR)$(LUA_SHAREDIR)/service/

# Print what the platform detection resolved to.
config:
	@echo "PLATFORM       = $(PLATFORM)"
	@echo "LUAJIT         = $(LUAJIT_BIN)"
	@echo "PREFIX         = $(PREFIX)"
	@echo "LUA_LIBDIR     = $(LUA_LIBDIR)"
	@echo "LUA_SHAREDIR   = $(LUA_SHAREDIR)"
	@echo "LUAINC         = $(LUAINC)"
	@echo "MODULE_LDFLAGS = $(MODULE_LDFLAGS)"
	@echo "MODULE_LIBS    = $(MODULE_LIBS)"
	@echo "LIBS           = $(LIBS)"
	@echo "TSAN_RUN       = $(TSAN_RUN)"
	@echo "TIMEOUT        = $(TIMEOUT)"

clean:
	rm -rf $(BUILD)
