# 日志

ctp.luajit 与 service.lua 使用同一套日志实现，并通过同一组环境变量配置。

## 分工

| 位置 | 写日志的方式 |
| --- | --- |
| `libctpc.so`（C/C++） | `log_debug` / `log_info` / `log_warn` / `log_error`，见 `src/log.h` |
| Lua（`templates/`、`demo/`、`examples/`） | `service.log.debug/info/warn/error` |

`ctp` 不提供 Lua 侧的日志封装，也不导出 `log_set_level`。Lua 代码统一通过
`service.log` 输出日志。

两边的输出格式相同：每条记录占一行，以一次 `write(2)` 写入 stderr，多个线程的
记录不会互相穿插：

```text
2026-10-26 13:44:55.572 DEBUG src/CustomTradeSpi.cpp:15: OnFrontConnected | FrontAddr:tcp://...
2026-10-26 13:44:55.580 INFO  entry.lua:35: [svc 1] booting root
```

`service.log.*(fmt, ...)` 是 printf 风格，与 C 侧 `log_debug` 用法一致（需要
service.lua `5c8577c` 及之后的版本）：

```lua
service.log.debug("order cancel : %s | %s", o._key, o.InstrumentID)
service.log.info("100% done")       -- 只有一个参数时原样输出，% 不需要转义
```

- 格式化规则同 `string.format`；`%s` 可以接受 nil、table、boolean。
- 级别未启用时不做格式化，但参数仍会先求值；`inspect(...)` 之类开销大的参数要注意。
- 格式串与参数不匹配时不会抛错，输出原始参数并附上 `(log format error: ...)`。
- FFI 的 `char[]` 字段传给 `%s` 输出的是地址，需要先 `ffi.string(...)`；
  `ctp` 转换出来的 Lua table 中已经是字符串，不受影响。

## 配置

| 环境变量 | 取值 | 默认 |
| --- | --- | --- |
| `SERVICE_LOG_LEVEL` | `debug` / `info` / `warn` / `error` / `off` | `info` |
| `SERVICE_LOG_FORMAT` | `text` / `journal` | `text`；stderr 接到 journald 时为 `journal` |

**必须在进程启动前设置**，例如：

```bash
SERVICE_LOG_LEVEL=debug luajit run.lua
```

或在 systemd unit 中写 `Environment=SERVICE_LOG_LEVEL=debug`。

默认级别是 `info`，而 libctpc 的大部分 C 侧日志（请求、回报、订单状态）都是
`debug` 级别；排查问题时需要显式设为 `debug`。登录、认证、结算确认失败，
`OnRspError`，断线和心跳超时使用 `warn` / `error`，默认即可见。

## 同步范围：只在启动时

`libctpc.so` 和 service.lua 的 `service_c.so` 各自编译了一份 `log.c`，各有一份
独立的日志状态（两者都以 `RTLD_LOCAL` 加载）。每份状态在**各自第一次写日志时**
读取一次环境变量，之后不再读取。因此：

- 启动前设置的 `SERVICE_LOG_LEVEL` / `SERVICE_LOG_FORMAT` 对两边同时生效；
- `service.log_config{ level = ... }` 只修改 service.lua 一侧，**不影响 libctpc 的
  C 侧日志**；
- 不要在 Lua 中通过 ffi 调用 `setenv` 来修改这两个变量：生效与否取决于哪个
  service 先写第一条日志，而且与其他线程中的 `getenv` 并发属于未定义行为；
- 值无效时两边各打印一条 `ignoring invalid SERVICE_LOG_LEVEL` 警告，并使用默认值。

单独使用 `ctp`（不加载 service.lua）时，C 侧日志照常按上述环境变量工作；
Lua 侧没有日志接口，需要时自行输出。

## CTP SDK 自身的输出

> 这是 libctpc 对 CTP SDK 库的运行时改造，默认开启。概要、后果和升级 SDK 时的检查
> 步骤见 [README](../README.md#️-特别提示libctpc-会在运行时改造-ctp-sdk-库)。

CTP 的 `libthostmduserapi_se.so` / `libthosttraderapi_se.so` 会自己往 stdout/stderr
打印（`fprintf(stderr)`、`printf`、`puts`、`perror`、对 fd 1/2 的 `write`）。默认情况下，
libctpc 会在第一次创建 CTP API 之前，把这些输出改道进 logger：

```text
2026-10-26 14:02:11.031 WARN  [ctp] ...      # SDK 写 stderr 的内容
2026-10-26 14:02:11.032 INFO  [ctp] ...      # SDK 写 stdout 的内容
```

于是它们和其他日志一样受 `SERVICE_LOG_LEVEL` / `SERVICE_LOG_FORMAT` 控制，每行一次
`write(2)`，不会与其他日志交错。

| `CTPC_OUTPUT` | 行为 |
| --- | --- |
| `log`（默认） | SDK 输出按行变成 `[ctp]` 日志：stdout 为 `info`，stderr 为 `warn` |
| `null` | SDK 输出直接丢弃 |
| `keep` | 不做任何修改，SDK 照常写 stdout/stderr（出现问题时的退路） |

与 `SERVICE_LOG_LEVEL` 一样，只在第一次创建 CTP API 时读取一次，需在启动前设置；取值不区分大小写。

### 实现方式

实现在 `src/ctp_stdio.c`。只改两个 SDK 库自己的导入槽，进程里其他代码、fd 2、
libc 的 `stdout`/`stderr` 都保持不变：

- `stderr`、`stdout` 的 `GLOB_DAT` 槽改为指向 libctpc 的两个 `FILE *`（用
  `fopencookie` 创建，按行交给 logger）。SDK 对这两个流的 `fprintf`、`fputs`、
  `fwrite`、`fputc`、`vfprintf` 因此全部改道，无需逐个接管。
- `printf`、`puts`、`perror` 在 libc 内部使用 libc 自己的流，`write` 直接写 fd，
  所以这四个函数槽换成 libctpc 的替代函数。`write` 只截获 fd 1/2，其他 fd
  （流文件、socket）原样转给 libc。
- SDK 采集穿透式监管终端信息时会经 `popen` 执行 `lshw -class disk|grep serial`、
  `dmidecode -t 1 | grep "Serial Number"` 等命令。子进程的 stderr 直接继承 fd 2，
  不经过上面任何一个槽位，于是会出现 `WARNING: you should run this program as
  super-user`、`sh: 1: dmidecode: not found`。`popen` 槽也被替换：命令包成
  `{ 原命令\n} 2>/dev/null` 再执行，stdout 照常交还 SDK，采集结果不变，只丢弃
  stderr（`log` 模式下在 `debug` 级别记录执行的命令）。
- 部分 SDK（ctp 6.7.8、6.7.11、openctp）带 RELRO，`stderr`/`stdout` 槽在加载后是
  只读的，修改时临时 `mprotect` 为可写，改完恢复。

各 SDK 导入的函数不同，被修改的槽数也不同：ctp 6.7.8 / 6.7.11 不导入 `write`，
为 6 个；openctp 只导入 `write`（也不采集终端信息），为 1 个；其余为 7 个。`SERVICE_LOG_LEVEL=debug` 时
会记录每个库实际修改的槽数；某个库一个都没改成时记一条 `warn`。

### 限制

- 只支持 Linux x86-64 + glibc；其他平台上相当于 `keep`。
- SDK 在加载时（构造函数里）就缓存起来的 `FILE *`，以及 libc / libstdc++ 内部的输出
  （例如 `std::terminate`、`abort`、断言失败的提示）不受影响，仍然写到原 stderr。
- 未写完一行（没有换行）的输出会留在缓冲中，进程退出时可能丢失。
- 丢弃 `lshw` / `dmidecode` 的 stderr 只是不再显示，并不让采集成功：非 root 运行或
  未安装 dmidecode 时，硬盘序列号、BIOS 序列号、CPU ID 等字段仍然为空。需要完整
  采集信息时，安装 dmidecode 并按期货公司要求的权限运行；想看原始报错可设
  `CTPC_OUTPUT=keep`。

### 测试

```bash
make test
```

`tests/c/fakectp.c` 模拟 SDK，通过上述每一种途径打印；测试分别在无 RELRO / 部分
RELRO、延迟绑定 / 立即绑定四种组合下检查每种输出都变成一条 `[ctp]` 记录、其他 fd
不受影响、进程自身的 stderr 不受影响、`null` 模式不输出，以及 `popen` 子进程的
stdout 照常读回、stderr 和 sh 的 "not found" 不会写到 fd 2。另外对当前 `CTP_VER` 的两个
真实库检查修改的槽数，与 `readelf` 独立统计的结果比对。

## 与 service.lua 保持一致

`src/log.c` 和 `src/log.h` 是 service.lua 中同名文件的原样副本，**不要在本仓库中
修改**。需要改动时先改 service.lua，再同步过来：

```bash
make sync-log                          # 复制文件，并把上游 commit 写入 src/log.UPSTREAM
make check-log                         # 与上游逐字比较，不一致时失败
make check-log SERVICE_LUA=/path/to/service.lua
```

`SERVICE_LUA` 默认为 `$(HOME)/src/service.lua`。`sync-log` 会拒绝复制上游尚未提交
的修改，保证 `log.UPSTREAM` 中记录的 commit 与文件内容对应。
