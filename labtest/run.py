#!/usr/bin/env python3
"""labtest runner: python3 labtest/run.py <stage> [--target NAME]. One PASS/FAIL line per check."""
import argparse
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)

from labtest import catalog, report, results, rows, table, target, unifi  # noqa: E402
from labtest.extra import cycle, garbage, soak, writes  # noqa: E402
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


def table_stage(args):
    conf = target.load_config()
    if not os.path.exists(conf["account_file"]):
        return [("table", False, "no account file")]
    if not conf.get("fields_dir") or not os.path.isdir(conf["fields_dir"]):
        return [("table", False, "no fields_dir")]
    todo = [r for r in rows.build(catalog.load(conf["fields_dir"])) if re.search(args.only, r["name"])][:args.limit]
    r = table.run(conf, target.get_target(conf, args.target), unifi.Controller(conf), todo)
    detail = report.counts_line(r) + (f"; stopped: {r['stopped']}" if r["stopped"] else "") + \
        (f"; left on target: {r['left']}" if r.get("left") else "")
    return [("table", r["pass"], detail, True)]


def writes_stage(args):
    conf = target.load_config()
    if not os.path.exists(conf["account_file"]):
        return [("writes", False, "no account file")]
    r = writes.run(conf, target.get_target(conf, args.target), unifi.Controller(conf))
    if r["error"]:
        return [("writes", False, r["error"])]
    i, p = r["idle"], r["push"]
    return [("writes", r["pass"], f"idle {i['secs']} s: {i['sectors']} sectors, files {i['files'][:5]}; "
                                  f"push there and back: {p['sectors']} sectors, files {p['files'][:5]}", True)]


def cycle_stage(args):
    conf = target.load_config()
    if not os.path.exists(conf["account_file"]):
        return [("cycle", False, "no account file")]
    r = cycle.run(conf, target.get_target(conf, args.target), unifi.Controller(conf))
    return [(f"cycle.{s['name']}", s["ok"], s["detail"]) for s in r["steps"]]


def garbage_stage(args):
    conf = target.load_config()
    if not os.path.exists(conf["account_file"]):
        return [("garbage", False, "no account file")]
    r = garbage.run(conf, target.get_target(conf, args.target), unifi.Controller(conf))
    if r["error"]:
        return [("garbage", False, r["error"])]
    return [(f"garbage.{c['name']}", c["ok"], "; ".join(c["problems"]) or f"rss {c['rss_kb']} kB") for c in r["cases"]]


def soak_stage(args):
    conf = target.load_config()
    if not os.path.exists(conf["account_file"]):
        return [("soak", False, "no account file")]
    r = soak.run(conf, target.get_target(conf, args.target), unifi.Controller(conf), hours=args.hours)
    last = r["samples"][-1]
    return [("soak", r["pass"], "; ".join(r["problems"]) or f"{len(r['samples'])} samples, last rss "
             f"{last['rss_kb']}, fds {last['fds']}, tmp {last['tmp_kb']} kB, pushes {r['pushes']}", True)]


def vm_stage(args):
    out = []
    for fn, tgt in ((catalog_stage, args.target), (table_stage, args.target), (writes_stage, args.target),
                    (cycle_stage, "vm4"), (garbage_stage, "vm4")):  # cycle wipes its VM: always the spare one
        checks = fn(argparse.Namespace(**dict(vars(args), target=tgt)))
        out += checks
        if not all(c[1] for c in checks):
            break
    return out


def safety(args):
    out = []
    for stage in (guards, timer_proof, pull_plug):
        checks = stage(args)
        out += checks
        if not all(c[1] for c in checks):
            break
    return out


# stage name -> function(args) returning [(check_name, passed, detail)]
STAGES = {"guards": guards, "proof": timer_proof, "plug": pull_plug, "safety": safety, "catalog": catalog_stage,
          "table": table_stage, "writes": writes_stage, "cycle": cycle_stage,
          "garbage": garbage_stage, "soak": soak_stage, "vm": vm_stage}


def main(argv=None):
    ap = argparse.ArgumentParser(prog="labtest/run.py")
    ap.add_argument("stage")
    ap.add_argument("--target", default="vm1")
    ap.add_argument("--only", default="", help="table: run only rows whose name matches this regex")
    ap.add_argument("--limit", type=int, default=None, help="table: at most this many rows")
    ap.add_argument("--hours", type=float, default=24, help="soak: how long")
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
