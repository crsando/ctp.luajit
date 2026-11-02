#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""把 tradelog.lua 输出的 JSONL 写入 SQLite。

    luajit tradelog.lua <profile> | uv run import.py [--db PATH]

只处理以 "{" 开头的行，其余（CTP SDK 可能打到 stdout 的内容）跳过并提示。
必须读到汇总行且条数一致，否则整批回滚、退出码非 0。重复导入是幂等的：
已有的 trade_id 被忽略，不覆盖（以后补的 commission 不会被冲掉）。
"""

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_DB = Path.home() / ".ctp.luajit" / "tradelog.sqlite"

SCHEMA = """
CREATE TABLE IF NOT EXISTS trades (
    trade_id      TEXT PRIMARY KEY,   -- 交易日.交易所.成交编号.方向，如 20261102.SHFE.12345.buy
    investor_id   TEXT NOT NULL,
    trading_day   TEXT NOT NULL,      -- 结算所属交易日 YYYY-MM-DD，夜盘算下一个交易日
    traded_at     TEXT NOT NULL,      -- 成交发生的时刻，ISO 8601 +08:00
    instrument_id TEXT NOT NULL,
    direction     TEXT NOT NULL CHECK (direction IN ('buy', 'sell')),
    volume        INTEGER NOT NULL,
    price         REAL NOT NULL,
    commission    REAL                -- 手续费，暂为 NULL
);
CREATE INDEX IF NOT EXISTS trades_day ON trades (investor_id, trading_day);
CREATE TABLE IF NOT EXISTS runs (     -- 每次导入一行，用来发现漏跑的交易日
    run_at      TEXT NOT NULL,
    investor_id TEXT NOT NULL,
    trading_day TEXT NOT NULL,
    count       INTEGER NOT NULL,     -- CTP 返回的成交笔数
    inserted    INTEGER NOT NULL      -- 本次新写入的笔数
);
"""

FIELDS = ("trade_id", "investor_id", "trading_day", "traded_at", "instrument_id",
          "direction", "volume", "price", "commission")


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
        if obj.get("summary"):
            summary = obj
        else:
            missing = [f for f in FIELDS if f not in obj]
            if missing:
                raise ValueError(f"line {n}: missing {', '.join(missing)}")
            records.append(obj)
    if summary is None:
        raise ValueError("no summary line; tradelog.lua did not finish")
    if summary["count"] != len(records):
        raise ValueError(f"summary count {summary['count']} != {len(records)} records")
    return records, summary


def store(db, records, summary):
    db.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.executescript(SCHEMA)
        with conn:  # 一个事务：任何一步失败整批回滚
            before = conn.total_changes
            conn.executemany(
                f"INSERT OR IGNORE INTO trades ({', '.join(FIELDS)}) "
                f"VALUES ({', '.join('?' * len(FIELDS))})",
                [tuple(r[f] for f in FIELDS) for r in records])
            inserted = conn.total_changes - before
            conn.execute(
                "INSERT INTO runs (run_at, investor_id, trading_day, count, inserted) "
                "VALUES (?, ?, ?, ?, ?)",
                (datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
                 summary["investor_id"], summary["trading_day"], summary["count"], inserted))
        return inserted
    finally:
        conn.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", type=Path, default=DEFAULT_DB, help=f"默认 {DEFAULT_DB}")
    args = ap.parse_args()
    try:
        records, summary = parse(sys.stdin)
        inserted = store(args.db, records, summary)
    except (ValueError, KeyError, sqlite3.Error) as e:
        sys.exit(f"import failed: {e}")
    print(f"{summary['investor_id']} {summary['trading_day']}: "
          f"{summary['count']} trades, {inserted} new -> {args.db}", file=sys.stderr)


if __name__ == "__main__":
    main()
