CFLAGS?=-g -Wall
# CFLAGS+=-DDEBUGLOG
CONTRACT_CFLAGS?=-std=c11 -Wall -Wextra -Wpedantic
TSAN_CFLAGS?=-std=c11 -O1 -g -Wall -Wextra -Wpedantic -fsanitize=thread -fno-pie -no-pie

PREFIX?=/usr/local
BUILD_DIR?=build

LUAINC?=-I/usr/local/include/luajit-2.1
SHARED=--shared -fPIC
SO=so
LIBS=-lpthread -lluajit-5.1 -luv -ldl

LUA_ENV=env 'LUA_PATH=./lua/?.lua;;' 'LUA_CPATH=./?.so;;'
CONTRACT_ABI_TEST=$(BUILD_DIR)/message_abi_test
MAILBOX_TEST=$(BUILD_DIR)/mailbox_test
MAILBOX_TSAN_TEST=$(BUILD_DIR)/mailbox_test_tsan
SERVICE_TEST=$(BUILD_DIR)/service_lifecycle_test
SERVICE_TSAN_TEST=$(BUILD_DIR)/service_lifecycle_test_tsan
SERVICE_TEST_SRCS=tests/c/service_lifecycle_test.c src/service.c src/loadluv.c src/mailbox.c \
 src/message.c src/registry.c src/log.c

SRCS=\
 src/lservice.c \
 src/service.c \
 src/loadluv.c \
 src/mailbox.c \
 src/registry.c \
 src/message.c \
 src/lua-seri.c \
 src/log.c

.PHONY: all test test-contract test-mailbox test-service test-tsan test-regression install clean

all: lservice3_c.so

lservice3_c.so: $(SRCS)
	$(CC) $(CFLAGS) $(SHARED) $(LUAINC) -Isrc -o $@ $^ $(LIBS)

test: test-contract test-mailbox test-service
	$(LUA_ENV) luajit tests/lua/serializer_spec.lua
	timeout 10s $(LUA_ENV) luajit tests/lua/lifecycle_spec.lua
	timeout 10s $(LUA_ENV) luajit tests/lua/mailbox_spec.lua
	timeout 10s $(LUA_ENV) luajit tests/lua/rpc_spec.lua

$(CONTRACT_ABI_TEST): tests/contract/message_abi_test.c src/message.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CONTRACT_CFLAGS) -Isrc -o $@ $<

test-contract: lservice3_c.so $(CONTRACT_ABI_TEST)
	$(LUA_ENV) luajit tests/contract/api_surface_spec.lua
	$(CONTRACT_ABI_TEST)

$(MAILBOX_TEST): tests/c/mailbox_test.c src/mailbox.c src/mailbox.h src/message.c src/message.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CONTRACT_CFLAGS) -Isrc -o $@ tests/c/mailbox_test.c src/mailbox.c src/message.c -lpthread

test-mailbox: $(MAILBOX_TEST)
	$(MAILBOX_TEST)

$(SERVICE_TEST): $(SERVICE_TEST_SRCS) src/service.h src/loadluv.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CONTRACT_CFLAGS) -D_POSIX_C_SOURCE=200809L -DLUV_LOADER_TESTING \
		$(LUAINC) -Isrc \
		-o $@ $(SERVICE_TEST_SRCS) $(LIBS)

test-service: $(SERVICE_TEST)
	$(SERVICE_TEST)

$(MAILBOX_TSAN_TEST): tests/c/mailbox_test.c src/mailbox.c src/mailbox.h src/message.c src/message.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(TSAN_CFLAGS) -Isrc -o $@ tests/c/mailbox_test.c src/mailbox.c src/message.c -lpthread

$(SERVICE_TSAN_TEST): $(SERVICE_TEST_SRCS) src/service.h src/loadluv.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(TSAN_CFLAGS) -D_POSIX_C_SOURCE=200809L -DLUV_LOADER_TESTING \
		$(LUAINC) -Isrc \
		-o $@ $(SERVICE_TEST_SRCS) $(LIBS)

test-tsan: $(MAILBOX_TSAN_TEST) $(SERVICE_TSAN_TEST)
	setarch $(shell uname -m) -R env TSAN_OPTIONS=halt_on_error=1 $(MAILBOX_TSAN_TEST)
	setarch $(shell uname -m) -R env TSAN_OPTIONS=halt_on_error=1 $(SERVICE_TSAN_TEST)

test-regression: lservice3_c.so
	$(LUA_ENV) luajit tests/regression/serializer_shared_ref_spec.lua

install: lservice3_c.so
	cp lservice3_c.so $(PREFIX)/lib/lua/5.1/
	cp lua/lservice3.lua $(PREFIX)/share/lua/5.1/

clean:
	rm -f lservice3_c.$(SO) $(CONTRACT_ABI_TEST) $(MAILBOX_TEST) \
		$(MAILBOX_TSAN_TEST) $(SERVICE_TEST) $(SERVICE_TSAN_TEST)
	rmdir $(BUILD_DIR) 2>/dev/null || true
