import unittest

from labtest.safety import proof
from labtest.tests.test_heal_py import FakeTarget


class ProofTest(unittest.TestCase):
    def test_proof_refuses_hardware(self):
        t = FakeTarget(kind="hw")
        with self.assertRaises(SystemExit):
            proof.run({"results_dir": "/nonexistent"}, t)
        self.assertEqual(t.cmds, [])

    def test_breaks_are_the_three_from_the_spec(self):
        self.assertEqual(set(proof.BREAKS), {"wrong_address", "deleted_network", "bad_vlan"})

    def test_breaks_use_no_lab_address(self):
        for cmd in proof.BREAKS.values():
            self.assertNotIn("10.99.", cmd)


if __name__ == "__main__":
    unittest.main()
