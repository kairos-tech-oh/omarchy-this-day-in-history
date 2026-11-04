---
id: omarchy-this-day-in-history.shell-conventions-hold
project: omarchy-this-day-in-history
category: ui
severity: warn
environment: any
depends_on: []
---

# QML follows the shell's palette, motion and textFormat conventions

## Claim
`tools/check-conventions.sh` passes: no bare `Color`, no literal animation
duration, and every dynamic Text declares a textFormat.

## Why
Qt 6.12's own `Color` type shadows the palette singleton and leaves colours
undefined, and an AutoText binding can render outside data as rich text.

## Check
```bash
bash tools/check-conventions.sh
```

## Depends On
None
