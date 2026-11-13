import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

from labtest import table, unifi

BOOL = {"kind": "bool", "values": [True, False]}


def row(key="hide_ssid", risk="safe", obj="WlanConf", field=BOOL, keys=None):
    return {"name": f"{obj}.{key}", "obj": obj, "key": key, "field": field, "risk": risk, "needs": "vm", "set": None,
            "keys": keys if keys is not None else [key]}


class Router:
    """Fake target plus router state. What a put does is set by the flags."""

    def __init__(self, kind="vm"):
        self.name, self.host, self.kind = "fake", "h", kind
        self.up, self.come_back, self.running = True, True, True
        self.lines, self.pushes, self.applied, self.pid, self.errors = ["base=1"], [], None, "100", []
        self.sends = self.applies = True
        self.changes = self.sticks = self.restarts = self.logs_error = self.cuts = False
        self.cmds, self.lag, self.late = [], 0, None

    # target side
    def ssh(self, cmd, timeout=20, stdin=None):
        self.cmds.append(cmd)
        if not self.up:
            return 255, ""
        if "openuf running" in cmd:
            return (0 if self.running else 1), ""
        return 0, ""

    def reachable(self):
        return self.up

    def wait(self, up, secs):
        self.up = self.come_back
        return self.come_back

    def snap(self):
        if not self.up:
            raise RuntimeError("not reachable")
        if self.late is not None:  # the put-back reaches the snapshot only after `lag` more takes
            self.late[0] -= 1
            if self.late[0] < 0:
                self.lines, self.late = self.late[1], None
        return {"uci": list(self.lines)}

    # what the router does with a push carrying the controller's object
    def react(self, obj, is_flip):
        if not self.sends:
            return
        cv = str(len(self.pushes) + 1)
        self.pushes.append({"cfgversion": cv, "keys": {f"w.{k}": str(v) for k, v in obj.items() if k != "_id"}})
        if self.cuts and is_flip:
            self.up = False
            return
        if self.applies or not is_flip:
            self.applied = cv
        if self.changes and not (self.sticks and not is_flip):
            lines = ["base=1"] + [f"w.{k}={v}" for k, v in sorted(obj.items()) if k not in ("_id", "name", "uapsd_enabled")
                                  and v is True]
            if self.lag and not is_flip:
                self.late = [self.lag, lines]
            else:
                self.lines = lines
        if is_flip and self.restarts:
            self.pid = "101"
        if is_flip and self.logs_error:
            self.errors = ["lua: inform.lua:12: attempt to index a nil value"]


class Ctl:
    def __init__(self, router, obj=None):
        self.r = router
        self.obj = obj if obj is not None else {"_id": "w1", "name": "T", "hide_ssid": False}
        self.puts, self.refuse, self.refuse_putback, self.flips = [], False, False, 0
        self.side, self.sticky = {}, False  # side: keys the controller changes itself on a flip; sticky: they stay

    def login(self):
        pass

    def locate(self, obj, host, wlan):
        return ("rest/wlanconf/w1", dict(self.obj)) if obj == "WlanConf" and wlan == "T" else None

    def put(self, path, body):
        self.puts.append((path, dict(body)))
        if self.refuse:
            raise unifi.Refused(f"controller refused {path}: api.err.Invalid")
        is_flip = "uapsd_enabled" not in body and (len([p for p in self.puts if "uapsd_enabled" not in p[1]]) % 2 == 1)
        if self.refuse_putback and "uapsd_enabled" not in body and not is_flip:
            raise RuntimeError("controller: HTTP 500 on " + path)
        self.obj.update(body)
        if is_flip or self.sticky:
            self.obj.update(self.side)
        self.r.react(self.obj, is_flip)

    def force_push(self, wlan_id):
        self.put("rest/wlanconf/w1", {"uapsd_enabled": not self.obj.get("uapsd_enabled", False)})


class TableTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.conf = {"results_dir": self.dir, "row_wlan": "T"}
        self.r = Router()
        self.ctl = Ctl(self.r)
        for target, new in (("time.sleep", None), ("labtest.table.snapshot.take", lambda t: t.snap()),
                            ("labtest.table.push.pushes", lambda t: list(t.pushes)),
                            ("labtest.table._applied", lambda t: t.applied), ("labtest.table._pid", lambda t: t.pid),
                            ("labtest.table._errors", lambda t, mark: t.errors)):
            p = mock.patch(target, new) if new else mock.patch(target)
            p.start()
            self.addCleanup(p.stop)
        self.ctl.force_push("w1")  # the router has seen one push before any row

    def env(self):
        return {"conf": self.conf, "t": self.r, "ctl": self.ctl, "wlan": "T", "ignore": frozenset(),
                "base": self.r.pushes[-1], "push_wait": 10, "apply_wait": 10}

    def flips(self):
        return [b for _, b in self.ctl.puts if "uapsd_enabled" not in b]

    def journal(self):
        return os.path.join(self.dir, "table-pending.json")

    # one row, step by step
    def test_skip_risk_is_not_covered_with_the_reason(self):
        res = table.one(self.env(), row(risk="skip: secret"))
        self.assertEqual((res["result"], res["note"]), ("not_covered", "secret"))
        self.assertEqual(self.flips(), [])

    def test_no_such_object_is_not_covered(self):
        res = table.one(self.env(), row(obj="Setting.ntp", key="x"))
        self.assertEqual((res["result"], res["note"]), ("not_covered", "the site has no such object"))

    def test_flip_none_is_not_covered(self):
        res = table.one(self.env(), row(key="pmf_mode", field={"kind": "enum", "values": ["disabled", "required"]}))
        self.assertEqual((res["result"], res["note"]), ("not_covered", "not set on this object"))
        self.assertEqual(self.flips(), [])

    def test_refused_put_is_not_covered_and_nothing_is_left(self):
        self.ctl.refuse = True
        res = table.one(self.env(), row())
        self.assertEqual(res["result"], "not_covered")
        self.assertIn("controller refused", res["note"])
        self.assertEqual(len(self.flips()), 1)  # no put-back of a put that never happened
        self.assertFalse(os.path.exists(self.journal()))

    def test_no_push_is_not_sent(self):
        self.r.sends = False
        res = table.one(self.env(), row())
        self.assertEqual(res["result"], "not_sent")
        self.assertEqual(self.flips(), [{"hide_ssid": True}, {"hide_ssid": False}])
        self.assertFalse(os.path.exists(self.journal()))

    def test_push_not_applied_is_broken(self):
        self.r.applies = False
        res = table.one(self.env(), row())
        self.assertEqual(res["result"], "broken")
        self.assertIn("not applied", res["note"])
        self.assertEqual(self.flips()[-1], {"hide_ssid": False})

    def test_push_but_no_router_change_is_ignored(self):
        res = table.one(self.env(), row())
        self.assertEqual(res["result"], "ignored")
        self.assertEqual(res["sent"], ["-w.hide_ssid=False", "+w.hide_ssid=True"])
        self.assertEqual(res["changed"], [])

    def test_router_change_without_check_is_not_covered(self):
        self.r.changes = True
        res = table.one(self.env(), row())
        self.assertEqual((res["result"], res["note"]), ("not_covered", "router changed, no check yet"))
        self.assertEqual(res["changed"], ["uci: +w.hide_ssid=True"])
        self.assertEqual(res["also_changed"], [])
        self.assertEqual(self.ctl.obj["hide_ssid"], False)

    def test_snapshot_waits_until_the_router_is_quiet(self):
        snaps = [{"uci": ["a"]}, {"uci": ["b"]}, {"uci": ["c"]}, {"uci": ["c"]}, {"uci": ["d"]}]
        with mock.patch("labtest.table.snapshot.take", side_effect=snaps):
            self.assertEqual(table._snap(self.env()), {"uci": ["c"]})

    def test_router_that_goes_back_late_is_not_broken(self):
        # openUF's l2guard rebuilds once a minute: the router is back, only later than the apply
        self.r.changes, self.r.lag = True, 8
        res = table.one(self.env(), row())
        self.assertEqual(res["result"], "not_covered")
        self.assertNotIn("did not go back", res["note"])

    def test_router_that_does_not_go_back_is_broken(self):
        self.r.changes = self.r.sticks = True
        res = table.one(self.env(), row())
        self.assertEqual(res["result"], "broken")
        self.assertIn("did not go back", res["note"])

    def test_lua_error_in_log_is_broken(self):
        self.r.logs_error = True
        res = table.one(self.env(), row())
        self.assertEqual(res["result"], "broken")
        self.assertIn("attempt to index", res["note"])

    def test_openuf_restart_is_broken(self):
        self.r.restarts = True
        res = table.one(self.env(), row())
        self.assertEqual(res["result"], "broken")
        self.assertIn("pid", res["note"])

    def test_absent_bool_goes_back_as_false(self):
        self.ctl.obj = {"_id": "w1", "name": "T"}
        table.one(self.env(), row(key="l2_isolation"))
        self.assertEqual(self.flips(), [{"l2_isolation": True}, {"l2_isolation": False}])

    def test_what_the_controller_changed_on_its_own_is_put_back_too(self):
        self.ctl.obj.update(wlan_band="both", x_passphrase="hunter2hunter2")
        self.ctl.side = {"wlan_band": "2g"}  # e.g. enhanced_iot: the controller narrows the band itself
        res = table.one(self.env(), row(keys=["hide_ssid", "wlan_band", "x_passphrase", "name"]))
        self.assertEqual(res["also_changed"], ["wlan_band"])  # so a router change is not credited to hide_ssid alone
        self.assertEqual(self.ctl.obj["wlan_band"], "both")
        self.assertEqual(self.flips()[-1], {"hide_ssid": False, "wlan_band": "both", "name": "T"})
        self.assertNotIn("hunter2", str(self.ctl.puts))

    def test_a_key_that_does_not_come_back_stops_the_row_loudly(self):
        self.ctl.obj["wlan_band"] = "both"
        self.ctl.side, self.ctl.sticky = {"wlan_band": "2g"}, True
        with self.assertRaises(table.PutBackFailed):
            table.one(self.env(), row(keys=["hide_ssid", "wlan_band"]))
        self.assertTrue(os.path.exists(self.journal()))

    def test_journal_holds_the_old_value_during_the_row(self):
        seen = []
        real = self.ctl.put
        self.ctl.put = lambda path, body: (seen.append(json.load(open(self.journal()))), real(path, body))
        table.one(self.env(), row())
        self.assertEqual(seen[0], {"path": "rest/wlanconf/w1", "old": {"hide_ssid": False}})  # keys: ["hide_ssid"]
        self.assertFalse(os.path.exists(self.journal()))

    # the whole run
    def run_table(self, rowlist, kind="vm"):
        self.r.kind = kind
        with mock.patch("labtest.table.push.on"), mock.patch("labtest.table.push.off"), \
                mock.patch("labtest.table.heal") as heal, mock.patch("labtest.table.proof._openuf_back"), \
                mock.patch("labtest.table.plug._connected", return_value=True), \
                mock.patch("labtest.table.results.save") as save, \
                mock.patch("labtest.table.results.commit", return_value="abc1234"):
            heal.disarm.return_value = []
            heal.healed.return_value = True
            out = table.run(self.conf, self.r, self.ctl, rowlist)
        return out, save, heal

    def test_pending_row_is_put_back_at_start(self):
        with open(self.journal(), "w") as fh:
            json.dump({"path": "rest/wlanconf/w1", "old": {"hide_ssid": True}}, fh)
        self.ctl.obj["hide_ssid"] = False
        self.ctl.puts.clear()
        self.run_table([])
        self.assertEqual(self.ctl.puts[0], ("rest/wlanconf/w1", {"hide_ssid": True}))
        self.assertFalse(os.path.exists(self.journal()))

    def test_failed_put_back_stops_the_run(self):
        self.ctl.refuse_putback = True
        out, _, _ = self.run_table([row(), row(key="l2_isolation")])
        self.assertFalse(out["pass"])
        self.assertEqual([x["name"] for x in out["rows"]], ["WlanConf.hide_ssid"])
        self.assertEqual(out["rows"][0]["result"], "broken")
        self.assertIn("put-back", out["stopped"])
        self.assertTrue(os.path.exists(self.journal()))

    def test_cut_off_row_on_a_vm_is_broken_and_the_run_goes_on(self):
        self.r.cuts = True
        out, _, heal = self.run_table([row(), row(key="l2_isolation", risk="skip: secret")])
        self.assertEqual(out["rows"][0]["result"], "broken")
        self.assertEqual(out["rows"][0]["note"], "cut off, healed by the timer")
        self.assertEqual(len(out["rows"]), 2)
        self.assertIsNone(out["stopped"])
        self.assertEqual(self.ctl.obj["hide_ssid"], False)  # put back
        self.assertGreaterEqual(heal.arm.call_count, 2)  # armed again after the heal

    def test_cut_off_row_on_hardware_stops_the_run(self):
        self.r.cuts = True
        out, _, _ = self.run_table([row(), row(key="l2_isolation", risk="skip: secret")], kind="hw")
        self.assertFalse(out["pass"])
        self.assertEqual(len(out["rows"]), 1)
        self.assertIn("hardware", out["stopped"])

    def test_cut_off_that_does_not_come_back_stops_the_run(self):
        self.r.cuts, self.r.come_back = True, False
        out, _, _ = self.run_table([row(), row(key="l2_isolation", risk="skip: secret")])
        self.assertEqual(out["rows"][0]["note"], "cut off, did not come back")
        self.assertEqual(len(out["rows"]), 1)

    def test_results_are_saved_after_every_row(self):
        out, save, heal = self.run_table([row(), row(key="a", risk="skip: secret"), row(key="b", risk="skip: secret")])
        names = [c[0][1] for c in save.call_args_list]
        self.assertGreaterEqual(names.count("table"), 3)
        self.assertIn("table-abc1234-", names[-1])
        self.assertTrue(out["pass"])
        self.assertEqual(out["counts"]["ignored"], 1)
        self.assertEqual(out["counts"]["not_covered"], 2)
        self.assertTrue(os.path.exists(os.path.join(self.dir, "table.md")))
        heal.disarm.assert_called()

    def test_broken_row_fails_the_run(self):
        self.r.logs_error = True
        out, _, _ = self.run_table([row()])
        self.assertFalse(out["pass"])


if __name__ == "__main__":
    unittest.main()
