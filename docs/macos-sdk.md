# macOS 版 CTP SDK：下载、签名、使用

> 本文的数据取自 **2026-10-28 实测**：从 simnow 下载页拿到 mac 6.7.13 包的信息，
> 并用同名同版本的 framework 二进制在本机（arm64 macOS 27.0.1）跑了 `dlopen` +
> `GetApiVersion()`，返回 `v6.7.13_MacOS_20260529 15:38:00`。

## 1. 官方在哪下

**上期技术官方下载页（也是 simnow 的 API 下载页）**

```
https://www.simnow.com.cn/static/apiDownload.action
```

进入后左侧菜单选 **`综合交易平台API` → `期货期权` → `MacOS`**。

页面信息（实测）：

| 项 | 值 |
| --- | --- |
| 版本号 | `v6.7.13_MacOS_20260529 15:38:00` |
| 更新时间 | 2026-08-25 |
| 适配系统 | macOS 10.15+ |
| 架构 | **x86_64 + arm64（universal）** |
| md5 | `1eb6fa7f830e6612bb283d3415417038` |
| 直链 | `https://www.simnow.com.cn/DocumentDown/api_3/5_2_2/TraderapiMduserapi_6.7.13_MacOS.zip` |
| 内容 | **只有 traderapi**；采集模块（看穿式）要另外从「看穿式采集库 → 生产/评测版本Mac看穿式采集库」下载 |

⚠️ 三个坑，实测踩到了：

1. **直链有反爬**。用 `curl` 直接请求下载地址，返回的不是 zip，而是 209 字节的
   `<script src="/C2WF946J0/probe.js">` 挑战页。**必须在浏览器里点「api下载」链接下载**，
   或手工过了那道 challenge 再抓。别浪费时间写 `curl`。
2. **嵌套 zip**：外层 zip 里装的是 `thost*.framework.zip`，还要再解一次。

3. **软链接问题：官方包是好的，社区转载的容易坏。** 实测 2026-10 下的官方包里
   `Headers` / `Resources` / `thosttraderapi_se` 三个软链接都完整；但从 GitHub
   （如 `pseudocodes/go2ctp`）拿到的副本，软链接经常被压成普通文本文件，直接用会报
   `file was built for unsupported file format`。解压后先检查：

   ```bash
   cd lib/<你的macos版本目录>
   ls -l thosttraderapi_se.framework
   ```

   正常应该是这样（`->` 表示软链接）：

   ```
   Headers                  -> Versions/Current/Headers
   Resources                -> Versions/Current/Resources
   thosttraderapi_se        -> Versions/Current/thosttraderapi_se
   Versions/
     A/                       （里面的 thosttraderapi_se 是真正的二进制）
     Current              -> A
   ```

   如果是普通文本文件，自己重建：

   ```bash
   cd thosttraderapi_se.framework
   mkdir -p Versions/A
   mv thosttraderapi_se Versions/A/ 2>/dev/null || true   # 先确认二进制在哪
   ln -sfn A Versions/Current
   ln -sfn Versions/Current/Headers Headers
   ln -sfn Versions/Current/thosttraderapi_se thosttraderapi_se
   ```

## 2. 官方 zip 的真实结构，以及怎么摆进项目

官方 zip **不是**直接解压就能用的，它是个两层嵌套包，而且里面**没有 error.xml**：

```
TraderapiMduserapi_6.7.13_MacOS.zip
  macOS_API_6.7.13/
    README.txt                            ← 版本说明，建议一起留下
    PrivacyNotice/*.pdf
    thostmduserapi_se.framework.zip       ← 嵌套 zip，要再解一次
    thosttraderapi_se.framework.zip       ← 同上
```

framework 解开后的内容（比社区包完整得多）：

```
thosttraderapi_se.framework/
  thosttraderapi_se        -> Versions/Current/thosttraderapi_se    （软链接，官方包是好的）
  Headers                  -> Versions/Current/Headers
  Resources                -> Versions/Current/Resources
  Versions/A/
    thosttraderapi_se                    universal x86_64 + arm64
    _CodeSignature/CodeResources         官方签名
    Resources/Info.plist                 com.sfit.thosttraderapi-se
    Headers/ThostFtdcTraderApi.h         ← 头文件在这里，不在顶层
                                  ThostFtdcUserApiDataType.h
                                  ThostFtdcUserApiStruct.h
```

所以摆进项目时要把 `Versions/A/Headers/*.h` 提到顶层（`tools/gen.lua` 和编译都在
`$(CTP_DIR)` 下找头文件）：

```bash
cd lib && S=ctp-6.7.13-macos && O=/path/to/macOS_API_6.7.13
mkdir -p $S
cp -R $O/thostmduserapi_se.framework $O/thosttraderapi_se.framework $S/
cp $O/thostmduserapi_se.framework/Versions/A/Headers/*.h $S/
cp $O/thosttraderapi_se.framework/Versions/A/Headers/*.h $S/
cp $O/README.txt $S/
xattr -dr com.apple.quarantine $S/          # 见 §3
```

结果：

```
lib/
  ctp-6.7.10/                  ← 现有 Linux SDK（.so）
  ctp-6.7.13-macos/            ← 新增
    README.txt
    ThostFtdcMdApi.h
    ThostFtdcTraderApi.h
    ThostFtdcUserApiDataType.h
    ThostFtdcUserApiStruct.h
    thostmduserapi_se.framework/
    thosttraderapi_se.framework/
```

（`error.xml` 官方 mac 包里没有，本项目也不需要它——错误码来自 `ThostFtdcUserApiDataType.h`。）
满足 DESIGN §2.3 的私有安装目录设计，和 Linux SDK 并存互不影响。

**注意**：macOS 头文件里的 `ReqUserLogin` 和 Linux 6.7.13 一样是两参数：

```c
virtual int ReqUserLogin(CThostFtdcReqUserLoginField *pReqUserLoginField, int nRequestID) = 0;
```

但 **6.7.13 之前**的 mac 版头文件是四参数（多两个穿透式信息参数）。本项目
`tools/gen.lua` 的正则只认两参数形式，遇到四参数会直接 `fail` —— 这是**故意的**，
免得生成一个签名错误的包装函数然后运行时崩溃。所以 **macOS 只用 6.7.13+**。

## 3. 签名与 quarantine

macOS 比 Linux 严格得多：**签名无效的 dylib 会被 `dyld` 直接拒绝加载**。但官方包和
社区包的情况完全不同，别一概而论：

### 3.1 官方包：签名是好的，只需要清 quarantine

官方 framework 用**真实的 Apple Developer 证书**签名（实测
`Apple Development: Lei Xu (8HL32W8669)`，TeamIdentifier `HQGP43W47S`），
`codesign -v` 直接通过。解压后 `dlopen` 报的是：

```
code signature ... not valid for use in process: library load disallowed by system policy
```

注意关键词是 **`disallowed by system policy`**，不是 `invalid`。这是 Gatekeeper 的
quarantine，因为 zip 是从网上下载的：

```bash
xattr -dr com.apple.quarantine lib/ctp-6.7.13-macos/
```

清完就能加载，**不要重新签名**——重新签反而会把官方签名换成 ad-hoc
（`flags=0x2(adhoc)`，不再带 TeamIdentifier）。`make` 会先用 `codesign -v` 检查，
有效就原样保留。

### 3.2 社区/手工拷贝的包：需要 ad-hoc 签名

从 GitHub、别人拷过来的 framework 往往是没签名或签名已失效，这时才需要：

```bash
codesign --force --sign - path/to/framework/Versions/A/<名字>
```

⚠️ 两个坑：
- **不要对整个 framework 用 `--deep`**，会报 `bundle format unrecognized, invalid, or unsuitable`。
  直接签里面的二进制（`Versions/A/<名字>`）就够了。
- 文件一旦被改动（重新解压、cp 覆盖），签名就失效，需要重签。

`libctpc.dylib` 自己用 `-` 签一份即可（harden runtime 才需要更强的签名）。

## 4. 二进制架构与加载

```
$ file thosttraderapi_se.framework/Versions/A/thosttraderapi_se
Mach-O universal binary with 2 architectures: [x86_64] [arm64]
```

`dlopen` 时，`dyld` 会按当前进程架构挑对应的 slice。**你编 `libctpc.dylib` 用的架构必须
和能跑起来的那一半一致**：Apple Silicon 上用 `-arch arm64`（或默认），Intel 用 `-arch x86_64`，
`-arch arm64 -arch x86_64` 才会出 fat 的 `libctpc.dylib`。

实测加载与调用（arm64 macOS，ad-hoc 签名后）：

```
$ ./t2
CTP API Version = v6.7.13_MacOS_20260529 15:38:00
```

对应代码只需要 `dlopen` + `dlsym` 取 C++ mangled 符号（注意 macOS 符号多一个前导下划线）：

```c
void *h = dlopen(".../thosttraderapi_se.framework/thosttraderapi_se", RTLD_NOW);
const char *(*ver)(void) =
    (const char *(*)(void))dlsym(h, "_ZN19CThostFtdcTraderApi13GetApiVersionEv");
printf("%s\n", ver());
```

> 本项目走的是**编译期链接**（`-framework thosttraderapi_se`）而不是 `dlopen`，两条路都通；
> 编译期链接的好处是 `tools/gen.lua` 生成的包装函数能拿到完整类型信息。

## 5. 首次运行的系统提示

macOS 会对未公证的二进制弹「无法验证开发者」。两种处理：

1. **系统设置 → 隐私与安全性 → 安全性**，底部点「仍要打开」。
   注意 SDK 是**每个 framework 单独弹一次**（`thostmduserapi_se`、`thosttraderapi_se`），
   第一次 `collector_smoke` 和第一次 `trader_smoke` 各弹一次。
2. 命令行清 quarantine（仍需签名正确）：

   ```bash
   xattr -dr com.apple.quarantine lib/ctp-6.7.13-macos/
   ```

**注意**：即使清了 quarantine，**签名无效仍然加载不了**。quarantine 和签名是两回事，
别以为 `xattr` 能省掉 §3 的 `codesign`。

## 6. 另一个来源：openctp

如果只想连 TTS 环境（`trading.openctp.cn`），openctp 的 mac 版是 `.dylib`：

- 优点：头文件一直和 Linux 统一（两参数 `ReqUserLogin`），甚至旧版本也能用；
- 缺点：**连官方前置会被反复断开**（README 已有同样的警告）；官方 framework 的
  `-framework` 链接方式在它这里不适用，得改成 `-L` + `-lthosttraderapi_se` + `@rpath`。

社区打包好的副本（`pseudocodes/go2ctp` 的 `ctp/lib/v6.7.13_MacOS_20260529/`）已经
修好了软链接问题，实测 framework 结构和二进制都正常，适合拿来先打通链路 ——
**但生产环境请以官方下载为准**，并在仓库里记录 md5。

## 7. 一页速查

```bash
# 1. 官网下载（必须在浏览器里点，curl 会被反爬挡住）
open https://www.simnow.com.cn/static/apiDownload.action
#    综合交易平台API → 期货期权 → MacOS → v6.7.13

# 2. 校验 md5（官方公布 1eb6fa7f830e6612bb283d3415417038）
md5 ~/Downloads/TraderapiMduserapi_6.7.13_MacOS.zip

# 3. 解外层，再解嵌套的 framework zip
O=$(mktemp -d)
unzip -q ~/Downloads/TraderapiMduserapi_6.7.13_MacOS.zip -d "$O"
cd "$O/macOS_API_6.7.13" && unzip -q -o thost*.framework.zip && rm -rf __MACOSX

# 4. 摆进项目（头文件从 framework 里提出来）
S=<仓库>/lib/ctp-6.7.13-macos
mkdir -p "$S"
cp -R thost*.framework "$S"/
cp thost*_se.framework/Versions/A/Headers/*.h "$S"/
cp README.txt "$S"/
xattr -dr com.apple.quarantine "$S"/          # 官方包签名有效，只需清 quarantine

# 5. 验证：签名应该是真实证书，不是 adhoc
codesign -dv "$S/thosttraderapi_se.framework" 2>&1 | grep -E "Authority|TeamIdentifier"
file "$S/thosttraderapi_se.framework/Versions/A/thosttraderapi_se"   # x86_64 + arm64

# 6. 构建并测试
cd <仓库> && make CTP_VER=ctp-6.7.13-macos && make CTP_VER=ctp-6.7.13-macos test
```

## 8. 实测记录（2026-10-28）

用这份官方包，在本机 arm64 macOS 27.0.1 上完整跑通：

```
md5           1eb6fa7f830e6612bb283d3415417038  ✓ 与官方一致
签名          Apple Development: Lei Xu (8HL32W8669), Team HQGP43W47S  ✓
架构          Mach-O universal x86_64 + arm64                          ✓
构建          make CTP_VER=ctp-6.7.13-macos → libctpc.dylib (arm64)     ✓
test          125 request wrappers / 155 Lua checks / C tests           ✓
运行          ctp_md_init api version v6.7.13_MacOS_20260529            ✓
              flow 文件正常写入 $TMPDIR/ctp_md/<broker>/<user>/         ✓
```

## 9. macOS 上的行为和 Linux 的差异清单

查代码过程中确认的差异，按重要性排：

### 9.1 SDK 的终端信息采集走 IOKit，不 popen

Linux 版 SDK 用 `popen("lshw")` / `popen("dmidecode")` 采集硬件信息，这也是
`ctp_stdio` 要改道 `popen` 的原因。**macOS 版完全不 `popen`**（`nm -u` 里没有
`popen` / `fork` / `posix_spawn`），改用 IOKit：

```
_IOServiceGetMatchingService   _IOServiceMatching   ...
=== IOKit.framework, Foundation.framework, CoreFoundation.framework
```

后果：

- README 里"`dmidecode: not found`"那类问题在 macOS 上不会出现；
- 但 **macOS 上未授权时硬件序列号同样可能为空** —— 它现在依赖 IOKit 权限和
  Xcode 环境（官方 README：「开发者需要配置 Xcode 开发环境，否则采集模块可能无法正常使用」）。
  实际影响是上报给期货公司的信息不完整，属于合规问题，不是程序问题。

### 9.2 输出改道完全不生效

`ctp_stdio` 操作 ELF 重定位槽，Mach-O 上没有对应的东西，所以 macOS 上等于
`CTPC_OUTPUT=keep`，启动时记一条 info。SDK 的输出直接写终端。

### 9.3 libuv 的 install_name

Homebrew 的 `libuv.dylib` 自带绝对路径 install_name
（`/opt/homebrew/opt/libuv/lib/libuv.1.dylib`），会被烤进 `libctpc.dylib`。
`make` 链接后用 `install_name_tool` 改写成 `@rpath/libuv.1.dylib`，配合
`-Wl,-rpath,$(BREW_PREFIX)/lib`，这样整个库目录可以搬走、可以换机器。

不属于 Homebrew 的 libuv（比如自己编的 `~/Develop/libuv`）不走这段改写。

### 9.4 universal 构建

`ARCHS="arm64 x86_64"` 会链接出 universal 的 `libctpc.dylib`（SDK framework 本身就是
universal）。**但 Homebrew 的 libuv 只有宿主架构**，所以会因为缺 x86_64 那份失败。
`make` 会提前给出提示而不是让 ld 报一句含糊的 `found architecture 'arm64'`。
要真出 universal 包，得先自己 `./configure` 一个双架构 libuv。

### 9.5 其他确认过没问题的

| 项 | 结论 |
| --- | --- |
| `uv_async_send` / `msgq`（pthread mutex + cond） | libuv 和 POSIX 都是跨平台的，语义一致 |
| `__atomic_*` 内建 | Apple clang 支持 |
| `iconv` | 用项目自己的 `iconv.lua`；macOS 必须链 `-liconv`（在 `libiconv.dylib`，不在 `libSystem`） |
| `-Werror` 构建 | 通过；`src/log.c` 是 service.lua 的逐字副本，`-Wformat-nonliteral` / `-Wstrncat-size` 按文件单独抑制 |
