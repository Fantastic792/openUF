"""table.md: the feature table for people, worst first."""
ORDER = [("broken", "Broken"), ("ignored", "Ignored"), ("not_covered", "Not covered"), ("not_sent", "Not sent"),
         ("works", "Works")]


def _cell(items):
    if isinstance(items, str):
        items = [items] if items else []
    shown = "; ".join(items[:3]) + (f"; +{len(items) - 3} more" if len(items) > 3 else "")
    return shown.replace("|", "\\|")


def counts_line(result):
    c = result["counts"]
    return f"{len(result['rows'])} rows: " + ", ".join(f"{c.get(k, 0)} {title.lower()}" for k, title in ORDER)


def markdown(result):
    out = ["# Feature table", "",
           f"Commit {result.get('commit', '?')}, {result.get('date', '?')}: {'PASS' if result['pass'] else 'FAIL'}", "",
           counts_line(result), ""]
    if result.get("stopped"):
        out += [f"Stopped: {result['stopped']}", ""]
    for key, title in ORDER:
        group = [r for r in result["rows"] if r["result"] == key]
        if not group:
            continue
        out += [f"## {title} ({len(group)})", "",
                "| Row | Note | Sent keys | Router changes | Controller also changed |", "|---|---|---|---|---|"]
        out += [f"| {r['name']} | {_cell(r['note'])} | {_cell(r['sent'])} | {_cell(r['changed'])} | "
                f"{_cell(r.get('also_changed', []))} |" for r in group]
        out.append("")
    hw = [r["name"] for r in result["rows"] if r.get("needs") == "hw"]
    if hw:  # a VM only says sent or not sent for these; the router-side check is Part 3
        out += [f"## Waits for hardware ({len(hw)})", "", ", ".join(hw), ""]
    return "\n".join(out)
