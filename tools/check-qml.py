#!/usr/bin/env python3
# Structural checks on the plugin's QML that lint cannot see.
# A Process that writes stdin must switch it back on before every run.
import os, re, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
failures = 0


def check(name, ok, detail=""):
    global failures
    print("%s %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else "  -- " + detail))
    if not ok:
        failures += 1


def blocks(text, keyword):
    # Yields (start, body) for each `keyword {` block, matching braces.
    for m in re.finditer(r"\b%s\s*\{" % keyword, text):
        depth, i = 0, m.end() - 1
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    yield m.start(), text[m.start():i + 1]
                    break
            i += 1


def stdin_processes(text):
    out = []
    for _, body in blocks(text, "Process"):
        ident = re.search(r"\bid:\s*(\w+)", body)
        if ident and re.search(r"\bwrite\s*\(", body):
            out.append(ident.group(1))
    return out


def run_sites_missing_stdin(text, ident):
    # Every `ident.running = true` must have `ident.stdinEnabled = true` in the
    # few lines before it, in the same function that starts the run.
    lines = text.split("\n")
    missing = []
    for n, line in enumerate(lines):
        if re.search(r"\b%s\.running\s*=\s*true" % re.escape(ident), line):
            window = "\n".join(lines[max(0, n - 6):n])
            if not re.search(r"\b%s\.stdinEnabled\s*=\s*true" % re.escape(ident), window):
                missing.append(n + 1)
    return missing


# Names every QML Item already owns. Declaring a property by one of these
# replaces the built-in: `data` swallowed a component's children and it drew
# empty, and lint accepted it.
BUILTIN_ITEM_PROPERTIES = ("data", "children", "resources", "visibleChildren", "states",
                           "transitions", "state", "parent", "anchors", "layer")


def shadowed_builtins(text):
    found = []
    for n, line in enumerate(text.split("\n")):
        m = re.match(r"\s*(?:readonly\s+|required\s+)*property\s+\S+\s+(\w+)\s*[:\n]?", line)
        if m and m.group(1) in BUILTIN_ITEM_PROPERTIES:
            found.append("property %s at line %d shadows a built-in" % (m.group(1), n + 1))
    return found


def audit(path):
    text = open(path, encoding="utf-8").read()
    problems = list(shadowed_builtins(text))
    for ident in stdin_processes(text):
        for line in run_sites_missing_stdin(text, ident):
            problems.append("%s.running at line %d has no %s.stdinEnabled = true before it" % (ident, line, ident))
    return problems


if __name__ == "__main__":
    targets = sys.argv[1:] or sorted(os.path.join(root, f) for f in os.listdir(root) if f.endswith(".qml"))
    total = []
    for path in targets:
        total += ["%s: %s" % (os.path.basename(path), p) for p in audit(path)]
    stdin = [t for t in total if "shadows a built-in" not in t]
    shadow = [t for t in total if "shadows a built-in" in t]
    check("every stdin-writing Process switches stdin on before each run", not stdin, "; ".join(stdin))
    check("no property shadows a built-in Item property", not shadow, "; ".join(shadow))
    print("\nall qml checks pass" if failures == 0 else "\n%d QML check(s) failed" % failures)
    sys.exit(1 if failures else 0)
