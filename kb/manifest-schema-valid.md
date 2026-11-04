---
id: omarchy-this-day-in-history.manifest-schema-valid
project: omarchy-this-day-in-history
category: manifest
severity: critical
environment: any
depends_on: []
---

# manifest.json is well-formed and its entry point exists

## Claim
`manifest.json` has `schemaVersion`, `id`, `name`, `version`, and
`entryPoints.barWidget` set, and that file actually exists in the repo.

## Why
This is the only entry point the plugin has — if it's missing or
misnamed, the plugin doesn't load at all.

## Check
```bash
m=manifest.json
jq -e '.schemaVersion and .id and .name and .version and .entryPoints.barWidget' "$m" >/dev/null
bw=$(jq -r '.entryPoints.barWidget' "$m")
[ -f "$bw" ]
```

## Depends On
None
