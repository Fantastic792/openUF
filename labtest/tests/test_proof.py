import re
import unittest

from labtest.safety import proof
from labtest.tests.test_heal_py import FakeTarget


class ProofTest(unittest.TestCase):
    def test_proof_refuses_hardware(self):
        t = FakeTarget(kind="hw")
        with self.assertRaises(SystemExit):
            proof.run({"results_dir": "/nonexistent"}, t)
        self.assertEqual(t.cmds, [])

    def test_openuf_back_is_synced_before_the_next_power_cut(self):
        t = FakeTarget()
        self.assertTrue(proof._openuf_back(t))
        self.assertTrue(t.cmds[0].rstrip().endswith("sync"), t.cmds[0])

    def test_breaks_are_the_three_from_the_spec(self):
        self.assertEqual(set(proof.BREAKS), {"wrong_address", "deleted_network", "bad_vlan"})

    def test_breaks_use_only_documentation_addresses(self):
        for cmd in proof.BREAKS.values():
            for ip in re.findall(r"\d+\.\d+\.\d+\.\d+", cmd):
                self.assertTrue(ip.startswith("198.51.100.") or ip.startswith("255."), ip)


if __name__ == "__main__":
    unittest.main()
