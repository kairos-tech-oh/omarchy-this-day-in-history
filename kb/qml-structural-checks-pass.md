---
id: omarchy-this-day-in-history.qml-structural-checks-pass
project: omarchy-this-day-in-history
category: logic
severity: warn
environment: any
depends_on: []
---

# QML avoids two known failure patterns

## Claim
`tools/check-qml.py` passes: no stdin-writing Process runs without enabling
stdin first, and no declared property shadows a built-in Item property.

## Why
Both are real bugs the plugin family this repo came from has hit before —
a shadowed property can silently empty a widget's children, and a
`.running = true` without `stdinEnabled` first drops writes. Lint doesn't
catch either, and this plugin has no other test coverage.

## Check
```bash
python3 tools/check-qml.py
```

## Depends On
None
