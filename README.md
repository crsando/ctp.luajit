# ctp.luajit

基于上期 CTP 接口、以 LuaJIT 为主力语言的期货交易基础设施：`libctpc.so` 把 CTP 的
C++ API 桥接成 C 接口，Lua 模块 `ctp`（`require "ctp"`）通过 LuaJIT FFI 调用它，
`ctp.templates` 在 service.lua 的 actor 框架上提供行情采集和交易服务模板。

```
lua/ctp/           init.lua（FFI 绑定）、accounts.lua、templates/{collector,trader}.lua
src/               libctpc.so：Spi 回调 → 队列 → uv_async 唤醒 Lua
tools/gen.lua      从 CTP 头文件生成请求包装函数和 Lua 用的 cdefs.lua
lib/<CTP_VER>/     CTP SDK（目前只带 ctp-6.7.10）
tests/             C 测试、Lua 离线测试
examples/          基于 service.lua 的示例
```

整体设计与改进路线见 [`DESIGN.md`](DESIGN.md)。
交易回报消息 `ctp_rsp_t` 的分配、转交与释放见 [`docs/ctp_rsp.md`](docs/ctp_rsp.md)。

## 发送请求

CTP 交易接口的每个 `ReqXxx` 都有一个由 `tools/gen.lua` 生成的 C 包装函数
`ctp_trader_ReqXxx`，Lua 侧统一用 `trader:req(name, fields)` 调用，`name` 是去掉
`Req` 前缀的 CTP 原名，`fields` 是请求结构体的字段：

```lua
local ctp = require "ctp"
local trader = ctp.new_trader(server)   -- 通常经 ctp.templates.trader 使用，见下文

local req_id, err = trader:req("QryInvestorPosition", { InstrumentID = "rb2601" })
-- 回报是 OnRspQryInvestorPosition，req_id 相同
```

- `BrokerID`、`InvestorID` 默认填当前账户，`fields` 里显式给出的优先。
- 字符串超长、字段名不存在、请求名不存在会直接抛错，不会传到 C 侧。
- 返回值大于 0 是请求号；小于 0 表示请求没有发出去，不会有回报，第二个返回值是原因
  （`ctp.strerror`）：`-1` 网络失败、`-2` 未处理请求过多、`-3` 每秒请求过多、
  `-100` trader 未启动。

## 行情

`ctp.templates.collector` 是行情 service 模板：

```lua
local ok, err = service.call("collector", "start", { timeout = 10000 }) -- 默认 10 秒
service.call("collector", "subscribe", { "rb2601", "au2612" })          -- 启动前后都可以
service.call("collector", "status")  -- state / reconnects / last_error / ticks_dropped ...
```

- `start` 成功返回 `true`；登录被拒、超时或本地初始化失败时返回 `nil, err`，并已自动 stop。
- 启动成功后的断线由 CTP 自动重连、libctpc 自动重新登录，模板按订阅集合重订阅。
- 使用者覆盖 `S.on_tick(tick)`；它抛错只会被计数和记日志，不影响后续 tick。
- 用真实前置检查：`luajit examples/collector_smoke.lua <profile>`。
- `front_addr` 必须带协议，如 `tcp://host:port`；少了 `tcp://` 时 CTP SDK 会直接崩溃，
  所以 `new_collector` / `new_trader` 会先报错。
- openctp 的 TTS 环境（如 `trading.openctp.cn`）需要 openctp 自己的 SDK 库，用官方
  `ctp-6.7.10` 连接会被反复断开。

## 交易

`ctp.templates.trader` 是交易 service 模板：

```lua
local ok, err = service.call("trader", "start", { timeout = 10000 }) -- 认证、登录、结算确认
service.call("trader", "status")  -- state / front_id / session_id / trading_day / reconnects / last_error
```

- `start` 成功返回 `true`；认证、登录、结算确认任一步失败或超时，返回 `nil, err` 并已自动 stop。
  超时的原因（例如 SDK 与前置不匹配导致的握手失败 4040）记在 `status().last_error`。
- 启动成功后的断线由 CTP 自动重连、libctpc 自动重走登录链路；断线时正在执行的查询立即以
  `"disconnected"` 失败，排队中的查询等重新就绪后再发。未启动时查询立即返回 `"not started"`。
- 用真实前置检查（只查询、不下单）：`luajit examples/trader_smoke.lua <profile>`。

模板在此之上提供按 1 次/秒流控的查询队列（`S.query_account` 等）
和订单簿。

---

## ⚠️ 特别提示：libctpc 会在运行时改造 CTP SDK 库

> **libctpc 在第一次创建 CTP API 之前，会改写 `libthostmduserapi_se.so` /
> `libthosttraderapi_se.so` 在内存中的导入表（GOT），改变 CTP 库自身的输出行为。**
> 这是默认开启的。磁盘上的 SDK 文件不会被修改，进程里 CTP 库以外的代码也不受影响。
> 遇到任何疑似与此有关的问题，先用 `CTPC_OUTPUT=keep` 关掉它对比。

### 为什么

CTP 库会绕过我们的日志系统，直接往 stdout/stderr 写东西，和程序日志混在一起，
也无法按级别过滤：

- 库内的 `fprintf(stderr)`、`printf`、`puts`、`perror`、对 fd 1/2 的 `write`；
- 采集穿透式监管终端信息时，经 `popen` 执行 `lshw`、`dmidecode`，子进程的报错直接写到
  终端，例如：

  ```text
  WARNING: you should run this program as super-user.
  sh: 1: dmidecode: not found
  ```

日志实现（`src/log.c`）与 service.lua 共用、必须保持逐字一致，不能为此改动，因此只能
在 CTP 库这一侧处理。

### 改了什么

| CTP 库导入的符号 | 改造后 |
| --- | --- |
| `stderr`、`stdout`（数据槽） | 指向 libctpc 的流，SDK 对它们的 `fprintf` / `fputs` / `fwrite` / `fputc` / `vfprintf` 全部改道 |
| `printf`、`puts` | 按行写入日志，`INFO  [ctp] ...` |
| `perror`、写 stderr 的上述函数 | 按行写入日志，`WARN  [ctp] ...` |
| `write` | 仅 fd 1/2 改道进日志；其他 fd（流文件、socket）原样交给 libc |
| `popen` | 命令包成 `{ 原命令\n} 2>/dev/null` 执行：stdout 照常交还 SDK，**stderr 丢弃** |

由环境变量 `CTPC_OUTPUT` 控制（只在启动时读取一次，不区分大小写）：

| 取值 | 行为 |
| --- | --- |
| `log`（默认） | 如上，SDK 输出并入日志 |
| `null` | SDK 输出全部丢弃 |
| `keep` | 不做任何改造，与原版 SDK 行为完全相同 |

### 必须知道的后果

- **终端信息采集并没有因此成功。** 丢弃 `lshw` / `dmidecode` 的报错只是不再显示：
  非 root 运行或未安装 dmidecode 时，上报给期货公司的硬盘序列号、BIOS 序列号、CPU ID
  仍然为空。期货公司要求完整采集信息时，需安装 dmidecode 并以其要求的权限运行。
  想看原始报错：`CTPC_OUTPUT=keep`。
- **只支持 Linux x86-64 + glibc**，其他平台上自动相当于 `keep`。
- 覆盖不到：SDK 加载时就缓存起来的 `FILE *`，以及 libc / libstdc++ 内部的输出
  （`std::terminate`、`abort`、断言失败），它们仍写到原 stderr。

### 升级或更换 CTP SDK 时

改造依赖 SDK 的导入表，换 SDK 版本后务必重新验证：

```bash
make test CTP_VER=<新版本目录>
```

测试会用 `readelf` 独立统计应改的槽数，与实际改动比对。运行时若某个库一个槽都没改成，
会记一条 `warn`；设 `SERVICE_LOG_LEVEL=debug` 可看到每个库实际改了几个槽。
已知各版本的槽数：

| SDK | 槽数 | 说明 |
| --- | --- | --- |
| ctp 6.3.15、6.6.7、6.6.9、6.7.7、6.7.9-p1、6.7.10 | 7 | |
| ctp 6.7.8、6.7.11 | 6 | 不导入 `write`；依赖 `libssl.so.1.1` |
| openctp 6.7.7、6.7.10 | 1 | 只导入 `write`，不采集终端信息 |

实现在 [`src/ctp_stdio.c`](src/ctp_stdio.c)，测试在 [`tests/c/`](tests/c/)，
完整说明见 [`docs/logging.md`](docs/logging.md#ctp-sdk-自身的输出)。

---

## 构建与安装

依赖：gcc/g++、libuv、LuaJIT 2.1（同时用于构建期代码生成），以及 `lib/` 下的 CTP SDK。
其他版本的 SDK 放到 `lib/<版本目录>/` 即可用 `CTP_VER` 选择。

```bash
make                              # 使用默认 SDK（ctp-6.7.10）
make CTP_VER=ctp-6.7.11           # 使用 lib/ 下的其他 SDK
make test                         # C 测试、生成器测试、Lua 离线测试
sudo make install                 # 安装到 /usr/local
make help                         # 全部目标和变量
```

构建输出在 `build/<CTP_VER>/`：`libctpc.so`、与它配套生成的 `cdefs.lua`，以及复制过来的
CTP 动态库。安装后的布局：

```
$(PREFIX)/lib/ctp.luajit/<CTP_VER>/   libctpc.so、cdefs.lua、CTP 动态库（每个 SDK 版本一个目录）
$(PREFIX)/share/lua/5.1/ctp/          Lua 模块；config.lua 记录最近一次安装的库目录
$(PREFIX)/include/ctp.luajit/         ctpc.h、ctpc_req.h 和 CTP 类型头文件（供 C 使用）
```

`require "ctp"` 先看环境变量 `CTPC_LIBDIR`，没有再用 `ctp/config.lua` 里的库目录，
从中加载 `cdefs.lua` 和 `libctpc.so`，并核对两者的 `ctpc_build_info()` 是否来自同一次构建，
不一致直接报错。不安装、直接用构建目录：

```bash
export CTPC_LIBDIR=$PWD/build/ctp-6.7.10
export LUA_PATH="$PWD/lua/?.lua;$PWD/lua/?/init.lua;;"
```

账户配置由 `ctp.accounts` 从 `~/.ctp.luajit/accounts.lua` 读取，不要放进仓库。

## 日志

C 侧（libctpc）与 Lua 侧（`service.log`）使用同一套日志实现，由同一组环境变量控制，
**需在启动前设置**：

```bash
SERVICE_LOG_LEVEL=debug luajit run.lua    # debug|info|warn|error|off，默认 info
```

libctpc 的大部分 C 侧日志是 `debug` 级别，默认看不到。运行中调用 `service.log_config`
只影响 service.lua 一侧，不影响 libctpc。详见 [`docs/logging.md`](docs/logging.md)。

`src/log.c`、`src/log.h` 是 service.lua 中同名文件的原样副本，**不要在本仓库修改**：
先改 service.lua，再 `make sync-log` 同步；`make check-log` 检查两边是否一致。
