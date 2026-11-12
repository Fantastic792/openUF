#!/usr/bin/env python3
"""labtest runner: python3 labtest/run.py <stage> [--target NAME]. One PASS/FAIL line per check."""
import argparse
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)

from labtest import catalog, results, target, unifi  # noqa: E402
from labtest.safety import flashguard, packguard, plug, proof  # noqa: E402


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


def pull_plug(args):
    conf = target.load_config()
    if not os.path.exists(conf["account_file"]):
        return [("plug", False, "no account file")]
    r = plug.run(conf, target.get_target(conf, args.target), unifi.Controller(conf))
    detail = "; ".join(
        f"+{c['offset']}s cut_ms={c['cut_ms']} mid_apply={c['mid_apply']} booted={c['booted']} "
        f"connected={c['connected']}" + "".join(f" [{e}]" for e in [c["error"]] + c["problems"] if e)
        for c in r["cuts"])
    if r["pass"] is False and not any(c["mid_apply"] for c in r["cuts"]):
        detail += "; no cut landed inside the apply"
    return [("plug", r["pass"], detail)]


def catalog_stage(args):
    conf = target.load_config()
    d = conf.get("fields_dir")
    if not d or not os.path.isdir(d):
        return [("catalog", False, "no fields_dir")]
    s = catalog.summary(catalog.load(d))
    results.save(conf, "catalog", s)
    return [("catalog", s["fields"] > 0, f"{s['files']} files, {s['fields']} fields, in scope {s['in_scope']} "
                                         f"({s['sections']} setting sections), "
                                         f"kinds in scope {s['kinds']}", True)]


def safety(args):
    out = []
    for stage in (guards, timer_proof, pull_plug):
        checks = stage(args)
        out += checks
        if not all(c[1] for c in checks):
            break
    return out


# stage name -> function(args) returning [(check_name, passed, detail)]
STAGES = {"guards": guards, "proof": timer_proof, "plug": pull_plug, "safety": safety, "catalog": catalog_stage}


def main(argv=None):
    ap = argparse.ArgumentParser(prog="labtest/run.py")
    ap.add_argument("stage")
    ap.add_argument("--target", default="vm1")
    args = ap.parse_args(argv)
    if args.stage not in STAGES:
        print(f"unknown stage {args.stage}; stages: {', '.join(STAGES) or '(none yet)'}")
        return 2
    failed = False
    for name, passed, detail, *show in STAGES[args.stage](args):  # show: print the detail on PASS too
        print((f"PASS {name}: {detail}" if show else f"PASS {name}") if passed else f"FAIL {name}: {detail}")
        failed |= not passed
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
