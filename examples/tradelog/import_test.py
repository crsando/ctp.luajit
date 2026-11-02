"""import.py 的离线测试：python3 examples/tradelog/import_test.py"""

import importlib.util
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

SCRIPT = Path(__file__).with_name("import.py")

# import 是关键字，只能这样加载
spec = importlib.util.spec_from_file_location("tradelog_import", SCRIPT)
tradelog_import = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tradelog_import)

is_complete = tradelog_import.is_complete
BEIJING = tradelog_import.BEIJING

# 与 clean_test.lua 断言的输出一致
TRADE = {"trade_id": "123456.20261102.SHFE.12345.buy", "investor_id": "123456",
         "trading_day": "2026-11-02", "traded_at": "2026-10-30T21:05:13+08:00",
         "instrument_id": "rb2601", "direction": "buy", "volume": 2, "price": 3456.2,
         "commission": None}


def summary(records, symbol=None, investor_id="123456", trading_day="2026-11-02"):
    return {"summary": True, "profile": "sim", "symbol": symbol,
            "investor_id": investor_id, "trading_day": trading_day, "count": len(records)}


def at(hour, minute=0, day=2):
    return datetime(2026, 11, day, hour, minute, tzinfo=BEIJING)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db = Path(self.tmp.name) / "sub" / "t.sqlite"

    def run_import(self, lines):
        return subprocess.run([sys.executable, str(SCRIPT), "--db", str(self.db)],
                              input="\n".join(lines) + "\n", text=True, capture_output=True)

    def feed(self, records, symbol=None):
        lines = [json.dumps(r) for r in records] + [json.dumps(summary(records, symbol))]
        return self.run_import(lines)

    def query(self, sql):
        conn = sqlite3.connect(self.db)
        try:
            return conn.execute(sql).fetchall()
        finally:
            conn.close()


class ImportTest(Base):
    def test_insert_and_idempotent(self):
        self.assertEqual(self.feed([TRADE]).returncode, 0)
        self.assertEqual(self.feed([TRADE]).returncode, 0)
        self.assertEqual(self.query("SELECT count(*) FROM trades"), [(1,)])
        self.assertEqual(self.query("SELECT count, inserted, conflicts FROM runs"),
                         [(1, 1, 0), (1, 0, 0)])
        self.assertEqual(self.query("SELECT typeof(price), typeof(volume) FROM trades"),
                         [("real", "integer")])

    def test_sdk_noise_skipped(self):
        lines = ["Decrypt handshake data failed", json.dumps(TRADE), json.dumps(summary([TRADE]))]
        self.assertEqual(self.run_import(lines).returncode, 0)
        self.assertEqual(self.query("SELECT count(*) FROM trades"), [(1,)])

    def test_invalid_records_reject_whole_batch(self):
        good = dict(TRADE, trade_id="good")
        for bad in (dict(TRADE, direction="x"), dict(TRADE, price=None)):
            r = self.feed([good, bad])
            self.assertNotEqual(r.returncode, 0, bad)
            self.assertEqual(self.query("SELECT count(*) FROM trades"), [(0,)])
            self.assertEqual(self.query("SELECT count(*) FROM runs"), [(0,)])

    def test_truncated_input_rejected(self):
        self.assertNotEqual(self.run_import([json.dumps(TRADE)]).returncode, 0)
        wrong = dict(summary([TRADE]), count=2)
        self.assertNotEqual(self.run_import([json.dumps(TRADE), json.dumps(wrong)]).returncode, 0)
        self.assertFalse(self.db.exists())

    def test_sources_may_differ(self):
        # trades 取自成交回报，runs 取自登录 session，各存各的
        lines = [json.dumps(TRADE), json.dumps(summary([TRADE], None, "login-user"))]
        self.assertEqual(self.run_import(lines).returncode, 0)
        self.assertEqual(self.query("SELECT investor_id FROM trades"), [("123456",)])
        self.assertEqual(self.query("SELECT investor_id FROM runs"), [("login-user",)])

    def test_summary_needs_session_fields(self):
        for bad in (summary([], None, None), summary([], None, "123456", None)):
            r = self.run_import([json.dumps(bad)])
            self.assertNotEqual(r.returncode, 0, bad)
            self.assertIn("summary: empty", r.stderr)

    def test_conflict_keeps_data_and_fails(self):
        self.assertEqual(self.feed([TRADE]).returncode, 0)
        changed = dict(TRADE, price=1.0)
        fresh = dict(TRADE, trade_id="fresh")
        r = self.feed([changed, fresh])
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(TRADE["trade_id"], r.stderr)
        self.assertEqual(self.query(f"SELECT price FROM trades WHERE trade_id = '{TRADE['trade_id']}'"),
                         [(3456.2,)])
        self.assertEqual(self.query("SELECT count(*) FROM trades WHERE trade_id = 'fresh'"), [(1,)])
        self.assertEqual(self.query("SELECT inserted, conflicts FROM runs ORDER BY rowid DESC LIMIT 1"),
                         [(1, 1)])

    def test_commission_survives_reimport(self):
        self.assertEqual(self.feed([TRADE]).returncode, 0)
        conn = sqlite3.connect(self.db)
        with conn:
            conn.execute("UPDATE trades SET commission = 1.5")
        conn.close()
        self.assertEqual(self.feed([TRADE]).returncode, 0)
        self.assertEqual(self.query("SELECT commission FROM trades"), [(1.5,)])
        self.assertEqual(self.query("SELECT conflicts FROM runs ORDER BY rowid DESC LIMIT 1"), [(0,)])

    def test_no_trades_still_identifies_account_and_day(self):
        self.assertEqual(self.feed([]).returncode, 0)
        self.assertEqual(self.query("SELECT profile, investor_id, trading_day, count FROM runs"),
                         [("sim", "123456", "2026-11-02", 0)])

    def test_old_schema_rejected(self):
        self.db.parent.mkdir(parents=True)
        conn = sqlite3.connect(self.db)
        conn.execute("CREATE TABLE trades (trade_id TEXT PRIMARY KEY)")
        conn.close()
        r = self.feed([TRADE])
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("old schema", r.stderr)


class StoreCompleteTest(Base):
    def stored_complete(self, records, now, symbol=None):
        tradelog_import.store(self.db, records, summary(records, symbol), now)
        return self.query("SELECT complete FROM runs ORDER BY rowid DESC LIMIT 1")[0][0]

    def test_store_records_complete_and_beijing_time(self):
        self.assertEqual(self.stored_complete([TRADE], at(15, 35)), 1)
        self.assertEqual(self.stored_complete([TRADE], at(3, 10)), 0)
        self.assertEqual(self.query("SELECT run_at FROM runs ORDER BY rowid DESC LIMIT 1"),
                         [("2026-11-02T03:10:00+08:00",)])


class IsCompleteTest(unittest.TestCase):
    def test_after_last_close(self):
        day = "2026-11-02"
        self.assertFalse(is_complete(at(15, 14), None, day))
        self.assertTrue(is_complete(at(15, 15), None, day))
        self.assertTrue(is_complete(at(19, 0), None, day))

    def test_other_trading_day_is_not_complete(self):
        # 交易日已切换：晚上 22:00、凌晨 3:10，或收盘后却已是下一个交易日
        self.assertFalse(is_complete(at(22, 0), None, "2026-11-03"))
        self.assertFalse(is_complete(at(3, 10, day=3), None, "2026-11-03"))
        self.assertFalse(is_complete(at(15, 35), None, "2026-11-03"))

    def test_symbol_is_not_complete(self):
        self.assertFalse(is_complete(at(15, 35), "rb2601", "2026-11-02"))


if __name__ == "__main__":
    unittest.main()
