#!/usr/bin/env python3
"""labtest runner: python3 labtest/run.py <stage> [--target NAME]. One PASS/FAIL line per check."""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# stage name -> function(args) returning [(check_name, passed, detail)]
STAGES = {}


def main(argv=None):
    ap = argparse.ArgumentParser(prog="labtest/run.py")
    ap.add_argument("stage")
    ap.add_argument("--target", default="vm1")
    args = ap.parse_args(argv)
    if args.stage not in STAGES:
        print(f"unknown stage {args.stage}; stages: {', '.join(STAGES) or '(none yet)'}")
        return 2
    failed = False
    for name, passed, detail in STAGES[args.stage](args):
        print(f"PASS {name}" if passed else f"FAIL {name}: {detail}")
        failed |= not passed
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
