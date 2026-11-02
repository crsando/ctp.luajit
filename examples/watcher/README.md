# watcher 示例

一个基于 LuaJIT、CTP 和 QuestDB 的期货行情采集程序。项目使用
`service` 将行情采集、交易查询和数据库写入拆分成独立 service：启动后连接
CTP，查询可用期货合约，订阅行情，并将每个 tick 写入 QuestDB。

本目录属于 `ctp.luajit` 主仓库，没有独立的包管理清单或自动化测试。
运行前需要先安装并配置项目依赖，以及 CTP 柜台和 QuestDB 网络连接。

## 数据流

```text
entry.lua                          根 service（service.root）
    |-- ctp.templates.trader      连接交易前置，查询合约
    |-- ctp.templates.collector   连接行情前置，接收 tick
    `-- db_writer.lua                  将 tick 写入 QuestDB
```

根 service 的启动流程如下：

1. 确定账户组名（命令行参数 > `service.config.profile` > 默认 `gtja-3`），
   从 `~/.ctp.luajit/accounts.lua` 读取对应的 collector 和 trader 配置；
   任一缺失则报错退出（退出码 1）。
2. 启动 `db_writer`、`collector` 和 `trader`。
3. 等待交易 service 建立连接并查询期货合约。
4. 每 10 个合约一批调用行情 service 的 `subscribe`。
5. `collector` 收到 tick 后发送给 `db_writer`。

## 目录结构

| 路径 | 作用 |
| --- | --- |
| [`entry.lua`](entry.lua) | 入口脚本兼根 service，可选传入账户组名；编排子 service 的生命周期、定时启停和订阅流程 |
| [`db_writer.lua`](db_writer.lua) | 将 tick 写入 QuestDB 表 `ctp_md_buffer`，设计见 [`db_writer.md`](db_writer.md) |
| [`lua/ctp/templates/collector.lua`](../../lua/ctp/templates/collector.lua) | 连接 CTP 行情前置、订阅/取消订阅、转发 tick |
| [`lua/ctp/templates/trader.lua`](../../lua/ctp/templates/trader.lua) | 交易前置、查询请求队列和订单状态管理 |
| `*.con` | CTP 运行时配套的状态/配置文件，需与所用 CTP SDK 保持一致 |

## 运行环境

至少需要以下组件：

- LuaJIT 2.1（Lua 5.1 API）；
- `service` 及其 `service_c` 原生模块；
- 本仓库的 Lua 模块 `ctp`，以及 `libctpc.so`、生成的 `cdefs.lua` 和 CTP API 动态库；
- `questdb.luajit` 及其底层 `libquestdb_client`；
- Lua 模块 `inspect`、`cjson.safe` 和 `luv`（GBK 转码用系统 iconv，不需要额外模块）；
- 可访问的 CTP 行情/交易前置；
- 可写入的 QuestDB 实例。

`make install` 之后，`require "ctp"` 按安装时生成的 `ctp/config.lua` 找到库目录：

```text
/usr/local/share/lua/5.1/ctp/            Lua 模块
/usr/local/lib/ctp.luajit/ctp-6.7.10/    libctpc.so、cdefs.lua、CTP 动态库
```

不安装时，可以设置 `CTPC_LIBDIR` 指向构建目录，见根目录 README。

### 构建依赖

下面是一个与本机源码目录布局匹配的示例。每个依赖也可以按其自己的 README
选择其他安装方式：

```bash
cd /home/twando/src/lservice3
make
sudo make install

cd /home/twando/src/ctp.luajit
make
sudo make install

cd /home/twando/src/questdb.luajit
make install
```

构建 `questdb.luajit` 前，还需要准备与其 FFI ABI 匹配的
`libquestdb_client.so`。详情见该项目的 README。

## CTP 账户配置

`ctp.accounts` 固定读取：

```text
$HOME/.ctp.luajit/accounts.lua
```

Windows 环境会尝试使用 `USERPROFILE`。该文件必须返回一个 Lua table，且
`collector` 和 `trader` 下都要有所用账户组名的配置（默认 `gtja-3`）。示例：

```lua
-- ~/.ctp.luajit/accounts.lua
return {
    collector = {
        ["gtja-3"] = {
            front_addr = "tcp://行情前置地址:端口",
            broker = "期货公司编号",
            user = "期货账户",
        },
    },
    trader = {
        ["gtja-3"] = {
            front_addr = "tcp://交易前置地址:端口",
            broker = "期货公司编号",
            user = "期货账户",
            pass = "账户密码",
            app_id = "应用标识",
            auth_code = "授权码",
        },
    },
}
```

`front_addr`、`broker`、`user`、`pass`、`app_id` 和 `auth_code` 的具体值由
CTP 柜台提供。不要将真实账户文件提交到 Git，也不要把密码和授权码写进本仓库。

## QuestDB

`db_writer` 使用 `questdb.luajit` 的行式写入接口，把完整的行情快照写入表
`ctp_md_buffer`：原始日期/时间字段、本机接收时间 `received_at`、价格、成交量、
持仓量和五档盘口。第一次运行前先在 QuestDB 执行
[`ctp_md_buffer.sql`](ctp_md_buffer.sql) 建表。

指定时间戳 `ts` 由 `ActionDay` + `UpdateTime` + `UpdateMillisec` 按
`+08:00` 解析。列定义、无效值处理和错误处理策略见
[`db_writer.md`](db_writer.md)。旧表 `ctp_tmp` 不再写入。

默认连接字符串为：

```text
http::addr=192.168.5.13:9000;
```

可以在 `db_writer` 的 service 配置中传入 `questdb_conf` 覆盖它。例如：

```lua
service.spawn {
    name = "db_writer",
    source = "@db_writer.lua",
    config = { questdb_conf = "http::addr=127.0.0.1:9000;" },
}
```

当前 `entry.lua` 启动 `db_writer` 时传入的是空配置，因此要修改默认地址，需先
调整根 service 的 spawn 配置，或让默认地址对应可访问的 QuestDB 实例。

## 启动

确认账户、CTP 动态库和 QuestDB 均已就绪后，**在本目录**运行 `entry.lua`
（`db_writer` 按相对路径 `@db_writer.lua` 加载，换目录启动会找不到）：

```bash
cd ~/src/ctp.luajit/examples/watcher
luajit entry.lua              # 使用默认账户组 gtja-3
luajit entry.lua my-profile   # 使用其他账户组
```

`entry.lua` 在顶层 `require "service.root"`，因此它本身就是可执行的入口，
命令行第一个参数会传给 `boot(profile)`。

`service` 和 `service_c` 需先安装到 LuaJIT 可搜索的位置。若 `ctp` 和
`questdb.luajit` 的 Lua 模块没有安装到系统路径，可显式设置 `LUA_PATH`，
并用 `CTPC_LIBDIR` 指向 `libctpc.so` 所在的构建目录：

```bash
export LUA_PATH="$HOME/src/ctp.luajit/lua/?.lua;$HOME/src/ctp.luajit/lua/?/init.lua;$HOME/src/questdb.luajit/lua/?.lua;$HOME/src/questdb.luajit/lua/?/init.lua;;"
# Linux
export CTPC_LIBDIR=$HOME/src/ctp.luajit/build/ctp-6.7.10
# macOS
export CTPC_LIBDIR=$HOME/src/ctp.luajit/build/ctp-6.7.13-macos
luajit entry.lua
```

日志统一输出到 stderr，默认级别为 `info`。libctpc 的请求、回报等 C 侧日志以及
示例中的 `service.log.debug` 都是 `debug` 级别，需要在启动前设置环境变量才能看到；
运行中调用 `service.log_config` 不会改变 C 侧级别。详见
[`docs/logging.md`](../../docs/logging.md)：

```bash
SERVICE_LOG_LEVEL=debug luajit entry.lua
```

启动后根 service 会立即执行一次 `start_all`，之后按以下时间定时启停：

| 时间 | 动作 |
| --- | --- |
| 08:45 | `start_all`（日盘） |
| 15:45 | `stop_all` |
| 20:45 | `start_all`（夜盘） |
| 04:00 | `stop_all` |

`start` 是幂等的：已经 ready 时再次调用直接返回，因此重复触发 `start_all` 无害。

进程会一直运行以接收行情。退出时应通过 service 的退出流程停止；不要在有未完成
订单时直接强制终止进程。

## Service 接口

### `collector`

- `start()`：连接行情前置并等待 ready；
- `subscribe(symbol)` 或 `subscribe({ symbol1, symbol2, ... })`：订阅行情；
- `unsubscribe(symbol)` 或 `unsubscribe({ ... })`：取消订阅；
- `quit()`：停止 service。

收到行情后，collector 会调用 `service.send("db_writer", "on_tick", tick)`。

### `trader`

- `start()`：启动交易前置并等待结算完成；
- `query_account()`：查询账户资金；
- `query_position()`：查询持仓；
- `query_instrument([symbol])`：查询全部期货合约或单个合约；
- `query_instrument_margin_rate(symbol)`：查询合约保证金率；
- `query_order()`：查询订单；
- `trade(symbol, price, volume, flag)`：提交订单并等待订单完成；
- `trade({ symbol, price, volume, flag, timeout })`：提交订单，可设置超时自动撤单；
- `nuke()`：查询当前持仓并逐项平仓；
- `quit()`：停止 service。

交易接口是真实下单接口。`price` 为 `0` 时按当前代码约定表示市价单，`flag` 默认为
开仓。调用 `trade` 或 `nuke` 前请先确认账户、合约、方向和数量，建议先在仿真环境验证。

## 注意事项

- 账户路径和默认 QuestDB 地址目前都写在代码约定中；账户组名可作为 `entry.lua` 的命令行参数指定。
- `start_all` 目前不检查 `start` 和 `query_instrument` 的返回值。前置未开放（周末、节假日的定时启动）
  导致查询失败时，`query_instrument` 返回 `nil`，后续遍历会报错。
- 根 service 会根据交易查询结果订阅全部期货合约，可能产生较大的行情量和数据库写入压力。
- `db_writer` 不逐字段校验 tick。时间字段解析失败的 tick 被跳过；一行写到一半失败时会清空当前批次（最多 `batch_size` 条或 1 秒的数据）；flush 失败时丢弃该批。这些情况都会记录错误日志。
- libctpc 默认会改造 CTP 库的输出：CTP 自身的打印并入日志（`[ctp]` 前缀），采集终端信息时
  `lshw` / `dmidecode` 的报错被丢弃。这只是隐藏报错：非 root 运行或未装 dmidecode 时，
  上报的终端信息仍不完整。详见根目录 [README](../../README.md) 的特别提示。
- 仓库当前没有自动化测试。修改行情字段映射、时间戳处理或订单状态机后，应至少在仿真柜台和测试 QuestDB 上做端到端验证。
