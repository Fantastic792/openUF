#!/usr/bin/env python3
"""labtest runner: python3 labtest/run.py <stage> [--target NAME]. One PASS/FAIL line per check."""
import argparse
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)

from labtest import target  # noqa: E402
from labtest.safety import flashguard, packguard, proof  # noqa: E402


def guards(args):
    hits = flashguard.scan(REPO)
    problems = packguard.check(REPO)
    return [("flash_guard", not hits, ", ".join(f"{p}:{n}" for p, n, _ in hits[:3])),
            ("pack_guard", not problems, "; ".join(problems))]


def timer_proof(args):
    conf = target.load_config()
    r = proof.run(conf, target.get_target(conf, args.target))
    bad = [b for b in r["breaks"] if not proof.ok(b)]
    return [("timer_proof", r["pass"], "; ".join(f"{b['name']}: {b}" for b in bad) or "not all breaks ran")]


# stage name -> function(args) returning [(check_name, passed, detail)]
STAGES = {"guards": guards, "proof": timer_proof}


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
