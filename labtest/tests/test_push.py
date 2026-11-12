import unittest

from labtest import push
from labtest.tests.test_heal_py import FakeTarget

# made-up lines, no lab data
LINE1 = ('2026-01-01T00:00:00Z {"_type":"setparam","mgmt_cfg":"cfgversion=aa\\nauthkey=0011\\n",'
         '"system_cfg":"wireless.1.ssid=T\\nwireless.1.hide_ssid=false\\n"}')
LINE2 = LINE1.replace("cfgversion=aa", "cfgversion=bb").replace("hide_ssid=false", "hide_ssid=true")


class PushTest(unittest.TestCase):
    def test_parse_and_sent(self):
        p = push.parse("\n".join([LINE1, '2026-01-01T00:00:10Z {"_type":"noop"}', "garbage",
                                  "2026-01-01T00:00:11Z TX {not json", LINE2]))
        self.assertEqual([x["cfgversion"] for x in p], ["aa", "bb"])
        self.assertNotIn("0011", str(p))  # authkey redacted
        self.assertEqual(p[0]["keys"]["wireless.1.ssid"], "T")
        self.assertEqual(push.sent(p[0], p[1]), ["-wireless.1.hide_ssid=false", "+wireless.1.hide_ssid=true"])
        self.assertEqual(push.sent(p[0], p[0]), [])

    def test_top_level_cfgversion_when_mgmt_cfg_has_none(self):
        line = '2026-01-01T00:00:00Z {"_type":"setparam","cfgversion":"cc","mgmt_cfg":"x=1\\n","system_cfg":"a=b\\n"}'
        self.assertEqual(push.parse(line)[0]["cfgversion"], "cc")

    def test_sent_lists_added_and_removed_keys(self):
        a = {"cfgversion": "a", "keys": {"mgmt.cfgversion": "a", "x": "1"}}
        b = {"cfgversion": "b", "keys": {"mgmt.cfgversion": "b", "y": "2"}}
        self.assertEqual(push.sent(a, b), ["-x=1", "+y=2"])

    def test_on_puts_back_a_left_over_backup_first(self):
        t = FakeTarget()
        push.on(t)
        self.assertIn(f"mv {push.BAK} {push.CONF}", t.cmds[0])
        later = " ".join(t.cmds[1:])
        self.assertIn(f"cp {push.CONF} {push.BAK}", later)
        self.assertIn(push.DUMP, later)
        self.assertIn("/etc/init.d/openuf restart", later)

    def test_on_raises_when_the_conf_line_is_missing(self):
        t = FakeTarget({"grep -q": (1, "")})
        with self.assertRaises(RuntimeError):
            push.on(t)
        self.assertFalse(any("sed -i" in c for c in t.cmds))

    def test_off_puts_the_backup_back_and_removes_the_dump(self):
        t = FakeTarget()
        push.off(t)
        self.assertIn(f"mv {push.BAK} {push.CONF}", t.cmds[0])
        self.assertIn(f"rm -f {push.DUMP}", t.cmds[0])

    def test_pushes_reads_the_dump(self):
        t = FakeTarget({push.DUMP: (0, LINE1 + "\n" + LINE2 + "\n")})
        self.assertEqual([p["cfgversion"] for p in push.pushes(t)], ["aa", "bb"])


if __name__ == "__main__":
    unittest.main()
