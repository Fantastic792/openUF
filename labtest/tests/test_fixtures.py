import json
import os
import shutil
import tempfile
import unittest

from labtest import fixtures, results, table, unifi

WLAN = {"_id": "w1", "name": "T", "usergroup_id": "g0", "networkconf_id": "n0", "radiusprofile_id": "r0"}


class FakeCtl:
    """Lists per REST path; every call is logged in order."""

    def __init__(self, items=None, refuse_post=False):
        self.items = {"rest/wlanconf": [dict(WLAN)], **(items or {})}
        self.calls, self.refuse_post, self.n = [], refuse_post, 0

    def get(self, path):
        return [dict(x) for x in self.items.get(path, [])]

    def wlans(self):
        return self.get("rest/wlanconf")

    def device(self, host):
        return {"_id": "d1", "ip": host, "port_overrides": []}

    def post(self, path, body):
        self.calls.append(("post", path, json.loads(json.dumps(body))))
        if self.refuse_post:
            raise unifi.Refused(f"controller refused {path}: api.err.Invalid")
        if path == "cmd/stamgr":  # forget-sta: the one way a client record goes
            self.items["rest/user"] = [o for o in self.items.get("rest/user", []) if o.get("mac") not in body["macs"]]
            return [{}]
        self.n += 1
        o = dict(body, _id=f"f{self.n}")
        self.items.setdefault(path, []).append(o)
        return [o]

    def put(self, path, body):
        self.calls.append(("put", path, dict(body)))
        base, oid = path.rsplit("/", 1)
        for o in self.items.get(base, []):
            if o["_id"] == oid:
                o.update(body)

    def delete(self, path):
        self.calls.append(("delete", path, None))
        base, oid = path.rsplit("/", 1)
        if base == "rest/user":  # the controller has no DELETE for a client record
            raise RuntimeError(f"controller: HTTP 404 on {path}")
        self.items[base] = [o for o in self.items.get(base, []) if o["_id"] != oid]


class FixturesTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.conf = {"results_dir": self.dir, "row_wlan": "T", "row_port": 2}

    def test_make_ties_usergroup_to_wlan(self):
        ctl = FakeCtl()
        path, o = fixtures.make(ctl, "UserGroup", self.conf, "h")
        self.assertEqual(path, "rest/usergroup/f1")
        self.assertEqual(o["name"], fixtures.NAME)
        self.assertEqual([(c[0], c[1]) for c in ctl.calls], [("post", "rest/usergroup"), ("put", "rest/wlanconf/w1")])
        self.assertEqual(ctl.calls[1][2], {"usergroup_id": "f1"})
        fixtures.make(ctl, "UserGroup", self.conf, "h")      # second use: found by name, already tied
        self.assertEqual(len(ctl.calls), 2)

    def test_portconf_tied_to_row_port(self):
        ctl = FakeCtl()
        fixtures.make(ctl, "PortConf", self.conf, "h")
        self.assertEqual(ctl.calls[-1], ("put", "rest/device/d1", {"port_overrides": [{"port_idx": 2, "portconf_id": "f1"}]}))
        # born without tagged_vlan_mgmt, a port_security flip adds it and forward "all" comes back "native"
        self.assertEqual(next(c[2] for c in ctl.calls if c[0] == "post")["tagged_vlan_mgmt"], "auto")

    def test_refused_make_raises_refused(self):
        with self.assertRaises(unifi.Refused):
            fixtures.make(FakeCtl(refuse_post=True), "ChannelPlan", self.conf, "h")

    def test_clean_unties_before_delete(self):
        ctl = FakeCtl()
        fixtures.make(ctl, "UserGroup", self.conf, "h")
        fixtures.make(ctl, "NetworkConf", self.conf, "h")
        ctl.calls.clear()
        self.assertEqual(fixtures.clean(ctl, self.conf), 2)
        kinds = [c[0] for c in ctl.calls]
        self.assertEqual(kinds, ["put", "put", "delete", "delete"])
        self.assertEqual(ctl.calls[0][2], {"networkconf_id": "n0"})        # last tie undone first
        self.assertEqual(ctl.calls[1][2], {"usergroup_id": "g0"})
        self.assertEqual(ctl.wlans()[0]["usergroup_id"], "g0")
        self.assertEqual(fixtures.clean(ctl, self.conf), 0)                 # nothing left: second call is 0

    def test_clean_forgets_a_user_instead_of_deleting_it(self):
        # live, 2026-11-16: DELETE rest/user/<id> is HTTP 404; the release stage died on it and the object stayed
        ctl = FakeCtl()
        fixtures.make(ctl, "User", self.conf, "h")
        ctl.calls.clear()
        self.assertEqual(fixtures.clean(ctl, self.conf), 1)
        self.assertEqual(ctl.calls, [("post", "cmd/stamgr", {"cmd": "forget-sta",
                                                             "macs": [fixtures._body("User")["mac"]]})])
        self.assertEqual(ctl.get("rest/user"), [])

    def test_fixture_secret_not_in_results(self):
        ctl = FakeCtl()
        fixtures.make(ctl, "RadiusProfile", self.conf, "h")
        secret = ctl.calls[0][2]["auth_servers"][0]["x_secret"]
        self.assertGreaterEqual(len(secret), 16)
        table._write_journal(self.conf, "rest/radiusprofile/f1", {"auth_servers": [{"x_secret": secret}]})
        results.save(self.conf, "table", fixtures.scrub({"rows": [{"changed": [f"+auth_server_shared_secret={secret}"]}]}))
        for name in os.listdir(self.dir):
            with open(os.path.join(self.dir, name)) as f:
                self.assertNotIn(secret, f.read(), name)


if __name__ == "__main__":
    unittest.main()
