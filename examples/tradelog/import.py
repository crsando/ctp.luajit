#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""把 tradelog.lua 输出的 JSONL 写入 SQLite。

    luajit tradelog.lua <profile> | uv run import.py [--db PATH]

只处理以 "{" 开头的行，其余（CTP SDK 可能打到 stdout 的内容）跳过并提示。
必须读到汇总行且条数一致，否则整批回滚、退出码非 0；不合法的记录同样整批回滚。
重复导入是幂等的：已有的 trade_id 不覆盖（以后补的 commission 不会被冲掉）。
trade_id 相同但内容不同时不覆盖，其余记录照常写入，记入 runs.conflicts，退出码非 0。
"""

import argparse
import json
import sqlite3
import sys
from datetime import datetime, time, timedelta, timezone
from pathlib import Path

DEFAULT_DB = Path.home() / ".ctp.luajit" / "tradelog.sqlite"

BEIJING = timezone(timedelta(hours=8))

# 最晚收盘的品种 15:15 收盘（北京时间），在这之前的导入不算完整
LAST_CLOSE = time(15, 15)

SCHEMA_VERSION = 1

SCHEMA = """
CREATE TABLE trades (
    trade_id      TEXT PRIMARY KEY,   -- 账号.交易日.交易所.成交编号.方向，如 123456.20261102.SHFE.12345.buy
    investor_id   TEXT NOT NULL,
    trading_day   TEXT NOT NULL,      -- 结算所属交易日 YYYY-MM-DD，夜盘算下一个交易日
    traded_at     TEXT NOT NULL,      -- 成交发生的时刻，ISO 8601 +08:00
    instrument_id TEXT NOT NULL,
    direction     TEXT NOT NULL CHECK (direction IN ('buy', 'sell')),
    volume        INTEGER NOT NULL,
    price         REAL NOT NULL,
    commission    REAL                -- 手续费，暂为 NULL
);
CREATE INDEX trades_day ON trades (investor_id, trading_day);
CREATE TABLE runs (                   -- 每次导入一行，用来发现漏跑的交易日
    run_at      TEXT NOT NULL,        -- 北京时间
    profile     TEXT NOT NULL,        -- accounts.lua 里的名字
    symbol      TEXT,                 -- 只查了一个合约时的合约代码，否则 NULL
    investor_id TEXT NOT NULL,        -- 登录 session 的 UserID，与 trades 的来源不同
    trading_day TEXT NOT NULL,        -- 登录 session 的交易日，没有成交时也有值
    count       INTEGER NOT NULL,     -- CTP 返回的成交笔数
    inserted    INTEGER NOT NULL,     -- 本次新写入的笔数
    conflicts   INTEGER NOT NULL,     -- trade_id 已存在但内容不同的笔数，应该永远是 0
    complete    INTEGER NOT NULL      -- 1：这次导入覆盖了 trading_day 整个交易日，见 is_complete
);
"""

FIELDS = ("trade_id", "investor_id", "trading_day", "traded_at", "instrument_id",
          "direction", "volume", "price", "commission")
# 判断内容是否一致时不比较 commission：它以后由 UPDATE 补上
IDENTITY_FIELDS = tuple(f for f in FIELDS if f != "commission")
SUMMARY_FIELDS = ("profile", "symbol", "investor_id", "trading_day", "count")


def parse(lines):
    records, summary = [], None
    for n, line in enumerate(lines, 1):
        line = line.strip()
        if not line:
            continue
        if not line.startswith("{"):
            print(f"skip line {n}: {line[:80]}", file=sys.stderr)
            continue
        obj = json.loads(line)
        if summary is not None:
            raise ValueError(f"line {n}: data after summary")
        fields = SUMMARY_FIELDS if obj.get("summary") else FIELDS
        missing = [f for f in fields if f not in obj]
        if missing:
            raise ValueError(f"line {n}: missing {', '.join(missing)}")
        if obj.get("summary"):
            summary = obj
        else:
            records.append(obj)
    if summary is None:
        raise ValueError("no summary line; tradelog.lua did not finish")
    if summary["count"] != len(records):
        raise ValueError(f"summary count {summary['count']} != {len(records)} records")
    # trades 取自成交回报，runs 取自登录 session，两边来源不同，不要求一致；
    # 这两项必须有值：已建好的库 runs 表上可能没有 NOT NULL
    for f in ("investor_id", "trading_day"):
        if not summary[f]:
            raise ValueError(f"summary: empty {f}")
    return records, summary


def is_complete(now, symbol, trading_day):
    """这次导入是否覆盖了 trading_day 的整个交易日。

    必须查全部合约，登录 session 的交易日就是今天（否则查到的是别的交易日），并且在
    收盘之后运行。夜里的运行交易日已切到下一天，不算完整。
    """
    return (symbol is None
            and trading_day == now.date().isoformat()
            and now.time() >= LAST_CLOSE)


def open_db(db):
    db.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        if version == 0:
            if conn.execute("SELECT 1 FROM sqlite_master WHERE name = 'trades'").fetchone():
                raise ValueError(f"{db}: old schema, trade_id format differs; migrate or use another --db")
            conn.executescript(SCHEMA + f"PRAGMA user_version = {SCHEMA_VERSION};")
        elif version != SCHEMA_VERSION:
            raise ValueError(f"{db}: unknown schema version {version}")
    except Exception:
        conn.close()
        raise
    return conn


def store(db, records, summary, now=None):
    now = now or datetime.now(BEIJING)
    columns = ", ".join(FIELDS)
    placeholders = ", ".join("?" * len(FIELDS))
    inserted, conflicts = 0, []
    conn = open_db(db)
    try:
        with conn:  # 一个事务：任何一步失败整批回滚
            for r in records:
                # 不用 INSERT OR IGNORE：它连 CHECK、NOT NULL 违规也会悄悄跳过
                before = conn.total_changes
                conn.execute(
                    f"INSERT INTO trades ({columns}) VALUES ({placeholders}) "
                    "ON CONFLICT (trade_id) DO NOTHING",
                    tuple(r[f] for f in FIELDS))
                if conn.total_changes > before:
                    inserted += 1
                    continue
                existing = conn.execute(
                    f"SELECT {', '.join(IDENTITY_FIELDS)} FROM trades WHERE trade_id = ?",
                    (r["trade_id"],)).fetchone()
                if existing != tuple(r[f] for f in IDENTITY_FIELDS):
                    conflicts.append(r["trade_id"])
            conn.execute(
                "INSERT INTO runs (run_at, profile, symbol, investor_id, trading_day, "
                "count, inserted, conflicts, complete) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (now.isoformat(timespec="seconds"), summary["profile"], summary["symbol"],
                 summary["investor_id"], summary["trading_day"], summary["count"],
                 inserted, len(conflicts),
                 int(is_complete(now, summary["symbol"], summary["trading_day"]))))
        return inserted, conflicts
    finally:
        conn.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", type=Path, default=DEFAULT_DB, help=f"默认 {DEFAULT_DB}")
    args = ap.parse_args()
    try:
        records, summary = parse(sys.stdin)
        inserted, conflicts = store(args.db, records, summary)
    except (ValueError, KeyError, sqlite3.Error) as e:
        sys.exit(f"import failed: {e}")
    print(f"{summary['profile']} {summary['trading_day'] or '-'}: "
          f"{summary['count']} trades, {inserted} new -> {args.db}", file=sys.stderr)
    if conflicts:
        sys.exit(f"import conflict: same trade_id, different content: {', '.join(conflicts)}")


if __name__ == "__main__":
    main()
