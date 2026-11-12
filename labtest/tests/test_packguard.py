import unittest

from labtest.safety import packguard


class PackGuardTest(unittest.TestCase):
    def test_labtest_name_is_a_problem(self):
        self.assertEqual(len(packguard.name_problems(["openuf/a.lua", "labtest/run.py"])), 1)

    def test_clean_names(self):
        self.assertEqual(packguard.name_problems(["openuf/a.lua"]), [])


if __name__ == "__main__":
    unittest.main()
