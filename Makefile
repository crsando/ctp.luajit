# ctp.luajit build / install
#
# Common usage:
#   make                              build with the default CTP version
#   make CTP_VER=ctp-6.7.11           build against another SDK under lib/
#                                     (default: ctp-6.7.10 on Linux,
#                                      ctp-6.7.13-macos on macOS)
#   make DEBUG=1                      -O0, no fortify (for gdb)
#   make WERROR=1                     treat warnings as errors (CI)
#   make install                      install to $(PREFIX) (default: prefix
#                                     of the luajit in PATH; sudo if needed)
#   make install DESTDIR=/tmp/stage   staged install (packaging)
#   make test                         run the C, generator and Lua tests
#   make check-log                    verify src/log.{c,h} match service.lua
#   make sync-log                     copy src/log.{c,h} from service.lua
#   make help                         list targets and variables

# ---------------------------------------------------------------------------
# Configuration (override on the command line)
# ---------------------------------------------------------------------------
UNAME_S   := $(shell uname -s)
LUAJIT    ?= luajit

# Install next to the luajit that will load the module: /opt/homebrew with
# Homebrew on Apple Silicon, /usr/local for a source build on Linux.
LUAJIT_BIN    := $(shell command -v $(LUAJIT) 2>/dev/null)
LUAJIT_PREFIX := $(patsubst %/bin/,%,$(dir $(LUAJIT_BIN)))
ifeq ($(strip $(LUAJIT_PREFIX)),)
LUAJIT_PREFIX := /usr/local
endif
PREFIX    ?= $(LUAJIT_PREFIX)
DESTDIR   ?=
# Each platform needs its own SDK build (.so vs .framework).
ifeq ($(UNAME_S),Darwin)
CTP_VER   ?= ctp-6.7.13-macos
else
CTP_VER   ?= ctp-6.7.10
endif
BUILD_DIR ?= build/$(CTP_VER)
# Defined here, not under Layout: the platform block below expands them with :=.
CTP_DIR   := lib/$(CTP_VER)
TEST_DIR  := $(BUILD_DIR)/test
DEBUG     ?= 0
WERROR    ?= 0
# Upstream of src/log.{c,h}; see docs/logging.md.
SERVICE_LUA ?= $(firstword $(wildcard $(HOME)/src/service.lua $(HOME)/Develop/service.lua) $(HOME)/src/service.lua)

# ---------------------------------------------------------------------------
# Platform (Linux ELF/gcc vs macOS Mach-O/clang)
#
# The two differ in the shared library extension, the linker options ($ORIGIN
# vs @loader_path, RELRO vs __DATA_CONST), the way the CTP SDK is linked (a
# plain .so vs a .framework) and in the toolchain: Homebrew's LLVM is not
# needed, Apple clang is fine, but it knows no -fstack-clash-protection.
# See docs/platform-portability.md.
# ---------------------------------------------------------------------------
ifeq ($(UNAME_S),Darwin)
PLATFORM       := macos
SHLIB_EXT      := dylib
SHLIB_LDFLAGS  := -dynamiclib -Wl,-rpath,@loader_path -Wl,-dead_strip
# The SDK ships as frameworks. -framework must reach ld on its own, so no
# -Wl, prefix here; the search path is $(BUILD_DIR), where the build copies
# the frameworks (BUILD_CTP_LIBS) and where libctpc is linked.
CTP_FRAMEWORK  := thostmduserapi_se thosttraderapi_se
# -F is a linker (ld) option, not a clang driver option: it has to reach ld
# as such, so it cannot be written -Wl,-F<dir>.
CTP_LDFLAGS    := $(addprefix -F,$(BUILD_DIR)) $(addprefix -framework ,$(CTP_FRAMEWORK))
BREW_PREFIX    ?= $(shell brew --prefix 2>/dev/null)
PLATFORM_CPPFLAGS := $(if $(BREW_PREFIX),-I$(BREW_PREFIX)/include)
PLATFORM_LDLIBS   := $(if $(BREW_PREFIX),-L$(BREW_PREFIX)/lib) -luv
# Homebrew's libuv.dylib carries an absolute install_name
# (/opt/homebrew/opt/libuv/lib/libuv.1.dylib), which would be baked into
# libctpc.dylib and break the build directory the moment libuv moves or the
# tree is copied to another Mac. -headerpad_max_install_names leaves room to
# rewrite it to @rpath/..., and -rpath gives @rpath somewhere to look.
PLATFORM_LDFLAGS  := -Wl,-headerpad_max_install_names -Wl,-rpath,$(BREW_PREFIX)/lib
# Empty builds for the host architecture only. Set ARCHS="arm64 x86_64" for a
# universal libctpc.dylib, which the SDK frameworks already are; libuv has to
# be universal too (Homebrew's is).
ARCHS          ?=
ARCH_FLAGS     := $(addprefix -arch ,$(ARCHS))
# Homebrew records the versioned opt path, not $(PREFIX)/lib.
UV_ABS_PATH    := $(BREW_PREFIX)/opt/libuv/lib/libuv.1.dylib
UV_RPATH_PATH  := @rpath/libuv.1.dylib
# -fstack-protector-strong and -fPIC are fine; -fstack-clash-protection, the
# RELRO/noexecstack linker flags and FORTIFY_SOURCE=2 are glibc/ELF only.
HARDEN_FLAGS   := -fstack-protector-strong
HARDEN_LDFLAGS :=
HARDEN_CPPFLAGS :=
else
PLATFORM       := linux
SHLIB_EXT      := so
# $ORIGIN: find the CTP libs next to libctpc.so wherever it is installed,
# instead of baking an absolute path into the binary.
SHLIB_LDFLAGS  := -shared -Wl,--as-needed -Wl,-rpath,'$$ORIGIN'
CTP_LDFLAGS    := -L$(CTP_DIR) -lthostmduserapi_se -lthosttraderapi_se
PLATFORM_CPPFLAGS :=
PLATFORM_LDLIBS   := -luv -lpthread
PLATFORM_LDFLAGS  :=
UV_ABS_PATH    :=
UV_RPATH_PATH  :=
ARCHS          ?=
ARCH_FLAGS     :=
HARDEN_FLAGS   := -fstack-protector-strong -fstack-clash-protection
HARDEN_LDFLAGS := -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack
HARDEN_CPPFLAGS := -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2
endif

ifeq ($(PLATFORM),macos)
# make has built-in defaults for CC/CXX, so `?=` would never apply here;
# only replace them when they come from make itself, not the env/cmdline.
# /usr/bin/gcc and g++ are Apple clang in disguise.
ifeq ($(origin CC),default)
CC := cc
endif
ifeq ($(origin CXX),default)
CXX := c++
endif
else
ifeq ($(origin CC),default)
CC := gcc
endif
ifeq ($(origin CXX),default)
CXX := g++
endif
endif

# User-overridable flags; mandatory flags are added separately below so that
# overriding CFLAGS on the command line cannot drop -fPIC or hardening.
CFLAGS   ?= -O2 -g
CXXFLAGS ?= -O2 -g
LDFLAGS  ?=

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
SRC_DIR := src
GEN_DIR := $(BUILD_DIR)/gen
TARGET  := $(BUILD_DIR)/libctpc.$(SHLIB_EXT)

# Generated by tools/gen.lua from the SDK headers and src/ctpc.h. cdefs.lua
# sits next to libctpc.so, here and once installed, so the two always come
# from the same build.
GEN_H   := $(GEN_DIR)/ctpc_req.h
GEN_CPP := $(GEN_DIR)/ctpc_req.cpp
CDEFS   := $(BUILD_DIR)/cdefs.lua

# Installed layout: each SDK version gets its own private library directory
# (libctpc.so finds the SDK libraries next to it through $ORIGIN); the Lua
# module is shared and its config.lua points at the last version installed.
PKG_LIB_DIR := $(PREFIX)/lib/ctp.luajit/$(CTP_VER)
INCLUDE_DIR := $(PREFIX)/include/ctp.luajit
LUA_DIR     := $(PREFIX)/share/lua/5.1/ctp

# Only the public API headers are installed; msgq/log/macros are internal.
PUBLIC_HEADERS := $(SRC_DIR)/ctpc.h $(GEN_H)
CTP_HEADERS    := $(CTP_DIR)/ThostFtdcUserApiDataType.h $(CTP_DIR)/ThostFtdcUserApiStruct.h

ifeq ($(PLATFORM),macos)
# The macOS SDK is two frameworks, each an ordinary directory tree; cp -R
# keeps the Versions/ layout (and the symlinks inside it) intact.
CTP_LIBS       := $(CTP_DIR)/thostmduserapi_se.framework $(CTP_DIR)/thosttraderapi_se.framework
BUILD_CTP_LIBS := $(addprefix $(BUILD_DIR)/,$(notdir $(CTP_LIBS)))
CTP_LIBS_RULE   = rm -rf $@ && cp -R $< $@
else
CTP_LIBS       := $(CTP_DIR)/libthostmduserapi_se.so $(CTP_DIR)/libthosttraderapi_se.so
BUILD_CTP_LIBS := $(addprefix $(BUILD_DIR)/,$(notdir $(CTP_LIBS)))
CTP_LIBS_RULE   = cp $< $@
endif

ifeq ($(wildcard $(CTP_DIR)/ThostFtdcTraderApi.h),)
$(error CTP SDK not found: $(CTP_DIR). Available: $(notdir $(wildcard lib/*)))
endif
# A Linux .so SDK and a macOS .framework SDK are not interchangeable: each
# platform needs its own directory under lib/. Fail early and say which.
ifeq ($(PLATFORM),macos)
ifeq ($(wildcard $(CTP_DIR)/thosttraderapi_se.framework),)
$(error $(CTP_DIR) has no thosttraderapi_se.framework; a Linux .so SDK cannot \
be used on macOS. See docs/macos-sdk.md)
endif
else
ifeq ($(wildcard $(CTP_DIR)/libthosttraderapi_se.so),)
$(error $(CTP_DIR) has no libthosttraderapi_se.so; a macOS .framework SDK \
cannot be used on Linux. See docs/platform-portability.md)
endif
endif

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
WARN_FLAGS := -Wall -Wextra -Wformat=2 -Wno-unused-parameter
ifeq ($(WERROR),1)
WARN_FLAGS += -Werror
endif

# src/log.{c,h} are a verbatim copy of service.lua's logger and must not be
# edited here, so the warnings they trip on Apple clang are silenced for that
# one translation unit rather than in WARN_FLAGS, which applies everywhere.
#   -Wformat-nonliteral: log.c forwards a va_list to vsnprintf (formatted
#     logging), which is the intent, not a mistake.
#   -Wstrncat-size: glibc reads strncat's size as "room left in the buffer";
#     Apple clang's check assumes sizeof(dst) and warns on that idiom.
ifeq ($(PLATFORM),macos)
LOG_CFLAGS := -Wno-format-nonliteral -Wno-strncat-size
endif

# Hardening: stack protector, fortified libc calls, full RELRO, non-exec stack.
# HARDEN_* come from the platform block above: FORTIFY, stack-clash and the
# RELRO/noexecstack linker flags are glibc/ELF features and are empty on macOS.

ifeq ($(DEBUG),1)
CFLAGS          := -O0 -g3
CXXFLAGS        := -O0 -g3
HARDEN_CPPFLAGS :=
endif

ALL_CPPFLAGS := -I$(SRC_DIR) -I$(GEN_DIR) -I$(CTP_DIR) $(PLATFORM_CPPFLAGS) \
                $(HARDEN_CPPFLAGS) $(CPPFLAGS)
ALL_CFLAGS   := -std=gnu11 -fPIC -MMD -MP $(WARN_FLAGS) $(HARDEN_FLAGS) $(ARCH_FLAGS) $(CFLAGS)
ALL_CXXFLAGS := -std=gnu++17 -fPIC -MMD -MP $(WARN_FLAGS) $(HARDEN_FLAGS) $(ARCH_FLAGS) $(CXXFLAGS)
# The platform block supplies -shared/-dynamiclib, the rpath ($ORIGIN vs
# @loader_path) and the ELF hardening flags; both make libctpc find the CTP
# libraries next to it wherever it is installed.
ALL_LDFLAGS  := $(SHLIB_LDFLAGS) $(HARDEN_LDFLAGS) $(LDFLAGS)
LDLIBS       := $(CTP_LDFLAGS) $(PLATFORM_LDLIBS)

# src/log.c is a verbatim copy of service.lua's logger and cannot be edited
# here, so on macOS the tests link it with -Wno-strncat-size; the sanitizer
# flags stay the same (Apple clang has ASan/UBSan, just not LSan).
# src/ctp_stdio.c patches ELF relocation slots; on Mach-O it compiles to the
# "keep" stub, so its dedicated tests (and the ELF-only slot counting in
# test-c) only run on Linux.
ifeq ($(PLATFORM),linux)
STDIO_TESTS := $(TEST_DIR)/ctp_stdio_test $(TEST_DIR)/libfakectp_norelro.so $(TEST_DIR)/libfakectp_relro.so
else
STDIO_TESTS :=
endif

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------
C_SOURCES   := $(wildcard $(SRC_DIR)/*.c)
CXX_SOURCES := $(wildcard $(SRC_DIR)/*.cpp)
OBJECTS     := $(C_SOURCES:$(SRC_DIR)/%.c=$(BUILD_DIR)/%.o) \
               $(CXX_SOURCES:$(SRC_DIR)/%.cpp=$(BUILD_DIR)/%.o) \
               $(BUILD_DIR)/ctpc_req.o
DEPFILES    := $(OBJECTS:.o=.d)

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------
.PHONY: all clean distclean install uninstall help check-log sync-log test test-c test-gen test-lua
.DELETE_ON_ERROR:

all: $(TARGET) $(CDEFS) $(BUILD_CTP_LIBS)

# One generator run produces all three files. Grouped targets (&:) would say
# that directly but need GNU Make 4.3, and macOS ships 3.81, which reads &:
# as an ordinary rule and runs gen.lua once per file (racing under -j); a
# stamp file works on both.
GEN_STAMP := $(GEN_DIR)/.stamp

$(GEN_STAMP): tools/gen.lua $(SRC_DIR)/ctpc.h $(CTP_DIR)/ThostFtdcTraderApi.h \
		$(CTP_DIR)/ThostFtdcUserApiDataType.h $(CTP_DIR)/ThostFtdcUserApiStruct.h | $(GEN_DIR)
	$(LUAJIT) tools/gen.lua $(CTP_DIR) $(CTP_VER) $(SRC_DIR)/ctpc.h $(GEN_DIR) $(CDEFS)
	@touch $@

$(GEN_H) $(GEN_CPP) $(CDEFS): $(GEN_STAMP)
	@:

# Every source includes ctpc.h, which includes the generated ctpc_req.h.
$(OBJECTS): $(GEN_H)

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c | $(BUILD_DIR)
	$(CC) $(ALL_CPPFLAGS) $(ALL_CFLAGS) $(if $(filter log.c,$(notdir $<)),$(LOG_CFLAGS)) -c $< -o $@

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.cpp | $(BUILD_DIR)
	$(CXX) $(ALL_CPPFLAGS) $(ALL_CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/ctpc_req.o: $(GEN_CPP) | $(BUILD_DIR)
	$(CXX) $(ALL_CPPFLAGS) $(ALL_CXXFLAGS) -c $< -o $@

# On macOS the frameworks are linked from $(BUILD_DIR), so the target also
# depends on the copies made there ($(BUILD_CTP_LIBS)).
ifeq ($(PLATFORM),macos)
# A universal build needs a universal libuv. Homebrew's is single-architecture
# for the host, so say so up front instead of letting ld fail on the second
# architecture with "found architecture 'arm64', required architecture 'x86_64'".
ifneq ($(words $(ARCHS)),0)
ifneq ($(words $(ARCHS)),1)
ifneq ($(wildcard $(BREW_PREFIX)/lib/libuv*.dylib),)
ifneq ($(shell lipo -info $(BREW_PREFIX)/lib/libuv.dylib 2>/dev/null | grep -c 'arm64 x86_64'),1)
$(warning ARCHS="$(ARCHS)" needs a universal libuv; $(BREW_PREFIX)/lib/libuv.dylib is \
$(shell lipo -info $(BREW_PREFIX)/lib/libuv.dylib 2>/dev/null | sed 's/.*architecture[s]*://'), \
so the link will fail. Build libuv with -arch for both, or drop ARCHS.)
endif
endif
endif
endif
$(TARGET): $(OBJECTS) $(BUILD_CTP_LIBS)
	$(CXX) $(ALL_CXXFLAGS) $(ALL_LDFLAGS) $(PLATFORM_LDFLAGS) -o $@ $(OBJECTS) $(LDLIBS)
	@if [ -n "$(UV_ABS_PATH)" ] && otool -L $@ | grep -q '$(UV_ABS_PATH)'; then \
		install_name_tool -change '$(UV_ABS_PATH)' '$(UV_RPATH_PATH)' $@; \
		echo "libctpc: libuv -> $(UV_RPATH_PATH)"; \
	fi
else
$(TARGET): $(OBJECTS)
	$(CXX) $(ALL_CXXFLAGS) $(ALL_LDFLAGS) -o $@ $^ $(LDLIBS)
endif

# cp for the .so files, cp -R for the frameworks (CTP_LIBS_RULE).
$(BUILD_CTP_LIBS): $(BUILD_DIR)/%: $(CTP_DIR)/% | $(BUILD_DIR)
	$(CTP_LIBS_RULE)
	@if [ "$(PLATFORM)" = macos ]; then \
		for bin in $@/Versions/*/$$(basename $@ .framework); do \
			if codesign -v "$$bin" 2>/dev/null; then \
				echo "$$bin: signature ok, not replaced"; \
			else \
				echo "$$bin: ad-hoc signing"; \
				codesign --force --sign - "$$bin" || exit 1; \
			fi; \
		done; \
	fi

$(BUILD_DIR) $(GEN_DIR):
	@mkdir -p $@

clean:
	$(RM) -r $(BUILD_DIR)

distclean:
	$(RM) -r build

# config.lua is generated at install time so the Lua side finds the library
# directory of the version just installed.
install: all
	install -d -m 0755 $(DESTDIR)$(PKG_LIB_DIR) $(DESTDIR)$(INCLUDE_DIR) $(DESTDIR)$(LUA_DIR)/templates
	install -m 0755 $(TARGET) $(DESTDIR)$(PKG_LIB_DIR)/
ifeq ($(PLATFORM),macos)
	$(RM) -r $(addprefix $(DESTDIR)$(PKG_LIB_DIR)/,$(notdir $(CTP_LIBS)))
	cp -R $(CTP_LIBS) $(DESTDIR)$(PKG_LIB_DIR)/
else
	install -m 0755 $(CTP_LIBS) $(DESTDIR)$(PKG_LIB_DIR)/
endif
	install -m 0644 $(CDEFS) $(DESTDIR)$(PKG_LIB_DIR)/
	install -m 0644 $(PUBLIC_HEADERS) $(CTP_HEADERS) $(DESTDIR)$(INCLUDE_DIR)/
	install -m 0644 lua/ctp/*.lua $(DESTDIR)$(LUA_DIR)/
	install -m 0644 lua/ctp/templates/*.lua $(DESTDIR)$(LUA_DIR)/templates/
	printf 'return { libdir = "%s", ctp_version = "%s" }\n' '$(PKG_LIB_DIR)' '$(CTP_VER)' \
		> $(DESTDIR)$(LUA_DIR)/config.lua
	chmod 0644 $(DESTDIR)$(LUA_DIR)/config.lua

# Removes this CTP_VER's libraries, and the headers and Lua module shared by
# all versions.
uninstall:
	$(RM) -r $(DESTDIR)$(PKG_LIB_DIR)
	-rmdir $(DESTDIR)$(PREFIX)/lib/ctp.luajit 2>/dev/null
	$(RM) -r $(DESTDIR)$(INCLUDE_DIR)
	$(RM) -r $(DESTDIR)$(LUA_DIR)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
TEST_ENV := env -u SERVICE_LOG_LEVEL -u SERVICE_LOG_FORMAT -u JOURNAL_STREAM -u CTPC_OUTPUT
# libfakectp stands in for the SDK, once with partial RELRO and once without,
# matching the two layouts the bundled SDKs ship with.
FAKE_CFLAGS := -std=gnu11 -fPIC -shared -fno-builtin -O0 -Wl,-z,lazy
# Slots ctp_stdio should patch in an SDK library, counted independently by
# readelf: stderr/stdout and the hooked functions, imported without addend.
SDK_SLOTS = $$(readelf -rW $(1) | awk '$$3 ~ /GLOB_DAT|JUMP_SLOT|R_X86_64_64/ && $$4 !~ /[1-9a-f]/ {print $$5}' \
	| sed 's/@.*//' | grep -cxE 'stderr|stdout|printf|puts|perror|write|popen')

test: test-c test-gen test-lua

test-c: $(TEST_DIR)/ctp_rsp_test $(TEST_DIR)/msgq_test $(STDIO_TESTS)
	$(TEST_ENV) UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 $(TEST_DIR)/ctp_rsp_test
	$(TEST_ENV) UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 $(TEST_DIR)/msgq_test
ifeq ($(PLATFORM),linux)
	@set -e; for lib in norelro relro; do for bind in lazy now; do \
		$(TEST_ENV) $(TEST_DIR)/ctp_stdio_test $(TEST_DIR)/libfakectp_$$lib.so $$bind; \
	done; done
	@set -e; for lib in $(CTP_LIBS); do \
		$(TEST_ENV) $(TEST_DIR)/ctp_stdio_test --sdk $$lib $(call SDK_SLOTS,$$lib); \
	done
else
	@echo "test-c: ctp_stdio output redirection is ELF-only, skipped on $(PLATFORM)"
endif

# Every ReqXxx in the SDK header has an exported wrapper, counted
# independently of tools/gen.lua.
test-gen: $(TARGET)
	@want=$$(grep -ac 'virtual int Req' $(CTP_DIR)/ThostFtdcTraderApi.h); \
	got=$$(nm -g $(TARGET) | grep -cE ' T _?ctp_trader_Req'); \
	if [ "$$want" != "$$got" ]; then \
		echo "test-gen: $(CTP_DIR) has $$want requests, $(TARGET) exports $$got wrappers" >&2; exit 1; \
	fi; \
	echo "test-gen: $$got request wrappers ok"

# Offline: loads libctpc from $(BUILD_DIR) but never connects. The
# template test needs luv, inspect and iconv, as the template itself does.
test-lua: all
	$(TEST_ENV) CTPC_LIBDIR=$(BUILD_DIR) $(LUAJIT) tests/lua/ctp_test.lua
	$(TEST_ENV) CTPC_LIBDIR=$(BUILD_DIR) $(LUAJIT) tests/lua/trader_query_test.lua
	$(TEST_ENV) CTPC_LIBDIR=$(BUILD_DIR) $(LUAJIT) tests/lua/trader_start_test.lua
	$(TEST_ENV) CTPC_LIBDIR=$(BUILD_DIR) $(LUAJIT) tests/lua/collector_test.lua

# ASan/UBSan: overflows and leaked blocks fail the test too.
$(TEST_DIR)/ctp_rsp_test: tests/c/ctp_rsp_test.c $(SRC_DIR)/trader.c $(SRC_DIR)/msgq.c $(SRC_DIR)/log.c $(GEN_H) | $(TEST_DIR)
	$(CC) $(ALL_CPPFLAGS) -std=gnu11 $(WARN_FLAGS) $(LOG_CFLAGS) -O1 -g -fno-omit-frame-pointer \
		-fsanitize=address,undefined -o $@ $(filter %.c,$^) $(PLATFORM_LDLIBS)

$(TEST_DIR)/msgq_test: tests/c/msgq_test.c $(SRC_DIR)/msgq.c $(SRC_DIR)/md.c $(SRC_DIR)/trader.c $(SRC_DIR)/log.c $(GEN_H) | $(TEST_DIR)
	$(CC) $(ALL_CPPFLAGS) -std=gnu11 $(WARN_FLAGS) $(LOG_CFLAGS) -O1 -g -fno-omit-frame-pointer \
		-fsanitize=address,undefined -o $@ $(filter %.c,$^) $(PLATFORM_LDLIBS)

$(TEST_DIR)/ctp_stdio_test: tests/c/ctp_stdio_test.c $(SRC_DIR)/ctp_stdio.c $(SRC_DIR)/log.c | $(TEST_DIR)
	$(CC) $(ALL_CPPFLAGS) -std=gnu11 $(WARN_FLAGS) -g -o $@ $^ -ldl -lpthread

$(TEST_DIR)/libfakectp_norelro.so: tests/c/fakectp.c | $(TEST_DIR)
	$(CC) $(FAKE_CFLAGS) -Wl,-z,norelro -o $@ $<

$(TEST_DIR)/libfakectp_relro.so: tests/c/fakectp.c | $(TEST_DIR)
	$(CC) $(FAKE_CFLAGS) -Wl,-z,relro -o $@ $<

$(TEST_DIR):
	@mkdir -p $@

# src/log.{c,h} are verbatim copies of service.lua's logger; never edit them
# here. src/log.UPSTREAM records the service.lua commit they were taken from.
LOG_FILES := log.c log.h

check-log:
	@for f in $(LOG_FILES); do \
		diff -u $(SERVICE_LUA)/src/$$f $(SRC_DIR)/$$f || exit 1; \
	done
	@echo "src/log.{c,h} match $(SERVICE_LUA)"

sync-log:
	@if [ -n "$$(git -C $(SERVICE_LUA) status --porcelain -- src/log.c src/log.h)" ]; then \
		echo "$(SERVICE_LUA): src/log.{c,h} have uncommitted changes" >&2; exit 1; \
	fi
	cp $(addprefix $(SERVICE_LUA)/src/,$(LOG_FILES)) $(SRC_DIR)/
	git -C $(SERVICE_LUA) rev-parse HEAD > $(SRC_DIR)/log.UPSTREAM

help:
	@echo "Targets:   all (default) | clean | distclean | install | uninstall | help"
	@echo "           test (test-c test-gen test-lua) | check-log | sync-log"
	@echo "           PREFIX=$(PREFIX) DESTDIR=$(DESTDIR) CTP_VER=$(CTP_VER) PLATFORM=$(PLATFORM)"
	@echo "           BUILD_DIR=$(BUILD_DIR) DEBUG=$(DEBUG) WERROR=$(WERROR)"
	@echo "           LUAJIT=$(LUAJIT) SERVICE_LUA=$(SERVICE_LUA)"
	@echo "           ARCHS=$(ARCHS) (macOS only, e.g. \"arm64 x86_64\")"
	@echo "SDKs:      $(notdir $(wildcard lib/*))"

-include $(DEPFILES)
