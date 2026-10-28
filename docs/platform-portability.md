# 把 ctp.luajit 做成 Linux / macOS 双向兼容

> 结论先说：**代码层面没有不可跨越的障碍，真正的瓶颈在 CTP SDK 的 macOS 产物和 Apple Silicon。**
> 下面按"能不能跑"→"哪里必须改"→"分几步落地"的顺序写。

## 0. macOS 支持的现状

| 层 | Linux | macOS |
| --- | --- | --- |
| CTP 官方 SDK（`libthost*api_se`） | 6.3.x 起一直有 `.so`（x86-64 / glibc） | 官方 **从 6.7.0 起提供 macOS 包**，发布形式是 `.framework`（x86_64 + arm64 universal），不是 `.so`/`.dylib`。openctp 另外提供 macOS 的 `.dylib` |
| 头文件 | 本项目 `lib/ctp-6.7.10/` | **6.7.13 之前，macOS 版 `ReqUserLogin` 多两个穿透式参数**；6.7.13 起与 Linux 完全一致。LuaJIT FFI 是"按头文件签名直接调用"，签名不一致会直接崩，所以只能用 6.7.13+，或给旧的 mac 版打补丁 |
| `libctpc`（本项目） | 已支持 | 当前**编译不过、也跑不起来**，原因见 §2 |
| LuaJIT / luv / libuv | 已支持 | 已支持（`brew install luajit`、`luarocks install luv`） |

所以"CTP 开发现在是否支持 macOS"的准确回答是：

- **能支持**，前提是用 **CTP ≥ 6.7.13 的 macOS 包**（6.7.13 起 Mac 与 Linux 的头文件签名统一，这也是最省事的分水岭）；
- 官方 Mac 包是 universal framework，**Intel 和 Apple 芯片都能跑**；
- 但 CTP 只出 x86-64 的 Linux `.so`，Apple Silicon 上跑 Linux 版本唯一的路是 Rosetta 2 + x86_64 容器/虚拟机 —— 不建议，成本高且和部署环境不一致。

## 1. 必须改的清单

按文件分组，每条都标了"为什么"和"怎么改"。

### 1.1 `Makefile` —— 平台分支（必改）

| 现状 | 问题 | 改法 |
| --- | --- | --- |
| `CC := gcc` / `CXX := g++` | macOS 上这两个只是 clang 的别名，能用但 `-fstack-clash-protection` macOS 不支持 | 按 `uname -s` 选 `cc`/`c++`，或保留 clang |
| `HARDEN_FLAGS := -fstack-protector-strong -fstack-clash-protection` | `-fstack-clash-protection` 在 Apple clang 上会报未知参数 | Darwin 分支去掉它，加 `-fstack-protector-strong` |
| `HARDEN_LDFLAGS := -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack` | `-z relro/now/noexecstack` 是 ELF 链接器选项，`ld64` 不认识 | Darwin 分支删掉；`-Wl,-dead_strip` 替代 `--as-needed` 的效果 |
| `-Wl,-rpath,'$$ORIGIN'` | Linux 的 `$ORIGIN`；macOS 对应 `@loader_path` | `-Wl,-rpath,@loader_path` |
| 目标名 `libctpc.so`、`CTP_LIBS := .../libthost*.so` | macOS 的库是 `libctpc.dylib`、SDK 是 `.framework` 或 `.dylib` | 引入 `DYLIB_EXT`、`CTP_MD_LIB`/`CTP_TRADER_LIB` 变量，按 `uname -s` 填 |
| `LDLIBS := -luv -lpthread` | macOS 上 pthread 在 libSystem 里，`-lpthread` 无害但不必；libuv 在 Homebrew 前缀下 | 用 `pkg-config --libs libuv` 或 `-L$(BREW_PREFIX)/lib` |
| `readelf -rW`（`SDK_SLOTS`） | macOS 没有 readelf | 这是 §1.3 测试分支的一部分 |
| SDK 存在性检查只看 `ThostFtdcTraderApi.h` | macOS 包里头文件和库可能分开放 | 检查项加一个"平台匹配"：ELF SDK 在 Darwin 上直接给出明确报错 |

建议的做法（不要满屏 `ifeq`）：

```make
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  SHLIB       := dylib
  SHLIB_LDFLAGS := -dynamiclib -Wl,-rpath,@loader_path -Wl,-dead_strip
  CTPLINK     := -Wl,-framework,thostmduserapi_se -Wl,-framework,thosttraderapi_se
  BREW        := $(shell brew --prefix 2>/dev/null)
  EXTRA_CPPFLAGS := -I$(BREW)/include
  EXTRA_LDLIBS   := -L$(BREW)/lib -luv
else
  SHLIB       := so
  SHLIB_LDFLAGS := -shared -Wl,--as-needed -Wl,-rpath,'$$ORIGIN' -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack
  CTPLINK     := -L$(CTP_DIR) -lthostmduserapi_se -lthosttraderapi_se
  EXTRA_LDLIBS := -luv -lpthread
endif
TARGET := $(BUILD_DIR)/libctpc.$(SHLIB)
```

同时 `install` 里的 `install -m 0755` 到 `$(PKG_LIB_DIR)` 逻辑不用改，但要复制对应的 macOS 产物。

### 1.2 源码 —— 见 §2/§3

### 1.3 测试 —— 按平台拆

- `test-c` 里 `ctp_stdio` 那一组（`libfakectp_*.so`、`--sdk`、`SDK_SLOTS`）在 Darwin 上跳过，理由见 §2.1：改道本来就只支持 ELF。
- `test-gen` 里的 `nm -D --defined-only` 换成 `nm -gU`（Darwin 语法不同），或者用 `nm -g $(TARGET) | grep ' T _ctp_trader_Req'` 加下划线前缀判断。
- `as SAN` 相关：Apple clang 支持 ASan/UBSan，macOS 上 `LSAN` 不可用（缺 leak sanitizer 完整支持），测试要按平台降级为 ASan+UBSan。

## 2. 源码里真正的"硬骨头"

### 2.1 `src/ctp_stdio.c` —— CTP SDK 输出改道（最大的一处）

现状：整段实现被 `#if defined(__GLIBC__) && defined(__x86_64__)` 关掉，其他平台**自动降为 `keep`**（README 里已经写了这点）。这部分在 macOS 上不是"坏了"，是"不生效"。

| 依赖 | 位置 | macOS 情况 | 改法 |
| --- | --- | --- | --- |
| `dl_iterate_phdr` + `PT_DYNAMIC`/`DT_RELA` 遍历 | 全文 | macOS 用的是 Mach-O：`_dyld_image_count` / `_dyld_get_image_header` / `_dyld_get_image_vmaddr_slide`，重定位在 `__LINKEDIT` 的 `LC_DYLD_CHAINED_FIXUPS`(arm64) 或 `LC_DYLD_INFO` 里 | 重写一遍 Mach-O 版本，见下 |
| `R_X86_64_GLOB_DAT` / `JUMP_SLOT` / `64` | `patch_relocs` | Mach-O 对应 `X86_64_REBASE` + `X86_64_BIND`（arm64 是 `ARM64_REBASE` + `ARM64_BIND`） | 两种架构各一套 |
| `fopencookie` | `open_sink` | glibc 专有，macOS 没有 | 用 `funopen(cookie, NULL, writefn, NULL, NULL)`，签名不同要包一层 |
| `strerror_r` 返回 `char *` | `hook_perror` | macOS 是 POSIX 版返回 `int` | `#ifdef __APPLE__` 包一下 |
| RELRO 段页对齐后 `mprotect` 可写 | `store_slot` | Mach-O 是 `__DATA_CONST` 段，加载后被 `PROT_READ`，处理方式类似但要找 `__DATA_CONST` 而不是 `PT_GNU_RELRO` | 用 `mach_vm_protect` 或同样 `mprotect` 页对齐即可 |

要支持就得写一份 `#elif defined(__APPLE__)` 分支；但写之前先想清楚**要不要支持**：

- 这一层的价值是"把 SDK 的 stdout/stderr 收进日志"。
- macOS 上 SDK 采集终端信息同样会 `popen("lshw")` —— 只是报错写法换成 `sh: lshw: not found`。
- **它和 `CTPC_OUTPUT=keep` 是等价的**，所以最省事的路线是：**macOS 上明确定义为只支持 `keep`**，在 `docs/logging.md` 里写清"macOS 不支持改道"，然后 `ctp_stdio_patch` 直接返回 -1，`ctp_stdio_init` 记一条 `info` 而不是 `warn`（避免每次启动都以为坏了）。
- 如果一定要支持，Mach-O 解析约 150~200 行 + 两个架构的 bind 解析，代价不小、收益只是一个日志整洁度。

推荐：**V1 先走 `keep`，把"不支持"变成文档里的已知项；V2 再按需补 Mach-O。**

### 2.2 `src/ctpc.cpp` —— flow 文件路径（必改）

```c
// CTP flow files (*.con) go to /dev/shm/<root>/<broker>/<user>/
#define _FLOW_BASE_ "/dev/shm"
```

macOS 没有 `/dev/shm`。改成一个可配置的根目录：

```c
#ifndef _FLOW_BASE_
#  if defined(__APPLE__)
#    define _FLOW_BASE_ "/tmp"      // 或 $TMPDIR（macOS 用 per-user 沙盒路径）
#  else
#    define _FLOW_BASE_ "/dev/shm"
#  endif
#endif
```

更稳妥的是**运行时**解析一次、并在注释里说明理由：

- `getenv("CTPC_FLOW_DIR")` > Darwin 用 `$TMPDIR`（macOS 保证它是 per-user 的 `/var/folders/...`，比 `/tmp` 安全）> Linux 用 `/dev/shm`。
- 顺带修一个小坑：`ctp_flow_mkdir` 里的 `st.st_uid != getuid()` 检查在 macOS 上也成立（`st_uid` 存在），但如果你把根目录设成 `$TMPDIR`，它是 per-user 的，检查通过没问题。

其余 `mkdir`/`lstat`/`S_ISDIR` 都是 POSIX，macOS 都有。

### 2.3 `src/ctpc.cpp` —— `#include "malloc.h"`（必改）

macOS 没有 `malloc.h`（`malloc` 声明在 `stdlib.h`）。`stdlib.h` 已经 include 了，删掉这一行就行。

### 2.4 `src/log.c` / `src/ctp_stdio.c` —— `__atomic_*` 内建（不改，但要知道）

`__atomic_load_n`/`__atomic_store_n`/`__atomic_add_fetch` 在 Apple clang 上支持（内部映射到 `stdatomic.h`），**不需要改**。
但 `log.c` 是 service.lua 的逐字副本，**不能为了 macOS 动它**——好在也不需要动。

### 2.5 `src/*.cpp` —— `std::cout/cerr`（建议顺手改，和跨平台无关）

`CustomTradeSpi.cpp` 里密码修改的回报用 `std::cout`/`std::cerr` 打（DESIGN.md 里 #14/#15 已有记录）。这和 §2.1 的改道是同一个问题：C++ 流在 `ctp_stdio` 改道的**下游**，改不到。修法是改成 `log_info`/`log_warn`（本来就该改，Linux 上也是漏洞）。

### 2.6 Lua 侧 —— 基本不用改

| 位置 | 情况 |
| --- | --- |
| `ffi.load(LIBDIR .. "/libctpc.so")` | **改成按平台选扩展名**：`jutil.os()` 或 `ffi.os`（`"OSX"` / `"Linux"`）→ `.so` / `.dylib`。或者干脆 `ffi.load(LIBDIR .. "/libctpc")`，让 LuaJIT 自己补后缀（LuaJIT 在 Darwin 上会尝试 `.dylib`）——后者更简洁，推荐 |
| `libthost*_se.so` 名字 | 只出现在 C 侧 `ctp_stdio.c` 的 `ctp_libraries[]`，Lua 不关心 |
| `uv_async_send(md->async)` / `luv` | libuv 是跨平台的，`uv_async_send` 语义一样（macOS 上底层是 kqueue + pipe），**不用改** |
| `iconv`（GBK → UTF-8） | 用本项目的 `iconv.lua`（POSIX `iconv(3)` 绑定，同时支持 Linux/macOS）。macOS 上它必须链接 `-liconv`，否则 `require` 报 `symbol not found in flat namespace '_iconv'`；Makefile 已在 Darwin 上自动加。统一由 `ctp.gbk` 调用，读不到时原样返回 |
| `os.date`/`os.time` | 无差异 |

### 2.7 `tools/gen.lua` —— 要处理多个 SDK 版本/平台

两个点：

1. **头文件签名差异**：6.7.13 之前 mac 版 `ReqUserLogin` 是 4 参数，生成器的正则 `virtual int ReqXxx(struct *, int nRequestID)` 会直接 `fail`。这其实**是好事**——它明确告诉你"这个 SDK 不支持"，而不是悄悄生成一个错误的函数。只要在 README 里写清"macOS 需要 6.7.13+"即可。
2. **SDK 选择**：`lib/<CTP_VER>/` 的目录约定要扩展成能表达平台。建议：

   ```
   lib/v6.7.13-official-macos/   ThostFtdc*.h + thostmduserapi_se.framework/
   lib/v6.7.13-official-linux/   ThostFtdc*.h + libthost*.so
   ```

   然后 `make CTP_VER=v6.7.13-official-macos` 就是一个平台一套构建，产物落在 `build/<CTP_VER>/`，**多平台库可以并存**——这正好和 DESIGN §2.3 的"私有安装目录"设计一致，不用改架构。

### 2.8 `tests/c/*` —— 见 §1.3

## 3. 落地顺序（推荐）

**第 1 步：让 Linux 构建不破坏，把平台变量抽出来。**
Makefile 加 `UNAME_S` 分支、`TARGET` 带扩展名、`$ORIGIN`→`@loader_path`。Linux CI 照常跑，macOS 至少 `make` 能过。

**第 2 步：源码最小改动。**
删 `malloc.h`、flow 目录按平台取、`ctp_stdio` 在 macOS 上返回"不支持"而不是"失败"。

**第 3 步：拿到 6.7.13+ 的 macOS SDK。**
这是唯一需要外部依赖的一步，见 §5。

**第 4 步：`luajit examples/collector_smoke.lua` 打通行情。**
行情链路不涉及交易、不下单，最适合先验证 SDK 加载、flow 路径、回调线程、`uv_async` 唤醒是否都正常。

**第 5 步：`trader_smoke`（只查询）。**
验证登录链路（认证、登录、结算确认）在 mac 版 SDK 上的行为；注意 6.7.13 之前 mac 版 `ReqUserLogin` 签名不同，如果只能用旧版就得打补丁。

**第 6 步（可选）：Mach-O 版 `ctp_stdio`。**

## 4. 不需要改的部分（避免过度设计）

- **libuv / `uv_async`**：跨平台，**不用改**。
- **`msgq`（pthread mutex + cond）**：POSIX，**不用改**。
- **`ctp_rsp_t` 分配/释放、`cdefs.lua` 生成、`ctpc_build_info` ABI 校验**：纯逻辑，**不用改**。
- **Lua 模板 `collector.lua` / `trader.lua`**：只要 `libctpc` 的 ABI 不变就**不用改**，这正是这套分层的价值。

## 5. 从哪搞 macOS 版 CTP SDK

| 来源 | 形式 | 版本 | 说明 |
| --- | --- | --- | --- |
| 上期技术官网 / simnow 下载页 | `thostmduserapi_se.framework`、`thosttraderapi_se.framework` | 6.7.0 起 | 官方包，universal（x86_64 + arm64）。**注意**：官方打包的 framework 里软链接可能变成普通文本文件，下载后要检查 `ls -l`，必要时自己 `ln -s` 修 |
| openctp | `.dylib` | 6.7.7 / 6.7.10 / 6.7.13+ | 头文件一直和 Linux 统一（两参数 `ReqUserLogin`），早期版本就不用打补丁；但**只能连 TTS 环境**，连官方前置会被反复断开（README 里已有同样的提醒） |
| 社区整理（如 `pseudocodes/go2ctp` 的 `ctp/lib/v6.7.13_MacOS_*`） | framework | 6.7.13 | 已修好软链接问题，省事，但**来源不是官方，生产环境慎用** |

**首次运行提示**：macOS 会对 `thostmduserapi_se` / `thosttraderapi_se` 弹"无法验证开发者"，要去 `系统设置 → 隐私与安全性` 手动允许一次。

## 6. Apple Silicon 的现实问题

- 官方 mac 包是 **universal**，arm64 原生可跑，`libctpc` 自己编译成 arm64 就行。
- **`libctpc.dylib` 的架构必须和 SDK 框架一致**：如果你 `make ARCH=-arch arm64` 但拿到的是 x86_64-only 的旧包，链接会报 `building for macOS-arm64 but attempting to link with file built for macOS-x86_64`。
- 如果只有 Linux `.so`（比如公司只给了 Linux 版生产库），那 Apple Silicon 上唯一的路是 **x86_64 Linux 容器 + Rosetta**，性能损失和网络抖动都不小，**不建议**。
- 交易类程序在 Apple Silicon 上跑，**建议 native arm64 + 真实 mac SDK**，别用 Rosetta 兼容层。

## 7. 改完后怎么验证

```bash
# 1. Linux 回归
make clean && make CTP_VER=ctp-6.7.10 && make test

# 2. macOS 构建
make CTP_VER=v6.7.13-official-macos
export CTPC_LIBDIR=$PWD/build/v6.7.13-official-macos
export LUA_PATH="$PWD/lua/?.lua;$PWD/lua/?/init.lua;;"

# 3. 行情冒烟
luajit examples/collector_smoke.lua simnow

# 4. 交易只查询
luajit examples/trader_smoke.lua simnow

# 5. 输出改道的预期行为（macOS 上应该看到 keep 的提示，而不是警告刷屏）
CTPC_OUTPUT=keep SERVICE_LOG_LEVEL=debug luajit examples/collector_smoke.lua simnow
```

## 8. 一句话总结

**代码改造量很小**（Makefile 分支 + 2 处 `#ifdef __APPLE__` + 1 个 `malloc.h` + Lua 的 `.dylib` 后缀），**真正的门槛是 CTP 官方的 macOS SDK 版本和分发形式**。最优路径：**CTP 6.7.13+ 官方 universal framework + native arm64 构建 + `CTPC_OUTPUT=keep`（不改道）**。
