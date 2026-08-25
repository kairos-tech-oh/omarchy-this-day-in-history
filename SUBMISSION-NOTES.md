# Submission notes

Working notes for the marketplace listing. Not part of the plugin's runtime.

`omarchy plugin validate .` exits 0. `scripts/preflight.sh` reports two areas;
both are explained below rather than silenced.

## Suggested listing metadata

| Field | Value |
|---|---|
| Category | `Widgets` |
| Tags | `bar, quickshell` |
| Title | `[Plugin]: This Day in History` |

**The submission issue has not been opened.** The marketplace's guidance for
agents is that only the owner may confirm the ownership statement and the
checklist, so that step is left to the repository owner.

The repository referenced by the README install command and the Wikipedia
User-Agent in `Panel.qml` is
`https://github.com/kairos-tech-oh/omarchy-this-day-in-history`. If the
repository is ever renamed or moved, the User-Agent has to move with it --
Wikimedia's API etiquette expects it to identify the application with a
working contact/link.

## Preflight area 1 -- text crossing into shell-owned AutoText sinks

    ./Panel.qml:300  Button { text: root.loading ? "Reloading..." : "Reload" }

Both branches are plugin-authored string literals with no input of any kind
-- `root.loading` is a `bool` the panel itself sets, never text from the
network. This is the same shape accepted at `kairos.night-sky/Panel.qml:658`
(`root.settingsOpen ? "Close" : "Settings"`).

More generally for this plugin: `BarWidget.qml`'s `WidgetButton.text` and
`tooltipText` -- the two sinks that actually matter, per issue #1666's
precedent -- are both fixed string literals (`"🔖"` and a static sentence).
Neither carries any network-sourced text, so there is nothing to sanitise at
that boundary: the fetched fact text is only ever assigned to `Text` elements
this plugin owns and pins to `Text.PlainText` in `Panel.qml`, never to a
`WidgetButton`/`Button`/`ToolTip` sink.

## Preflight area 2 -- `StdioCollector`

    ./Panel.qml:99   (comment describing the pattern, matched by the same grep)
    ./Panel.qml:197  stdout: StdioCollector { ... }

Accepted pattern, not an unbounded read. The one process is launched through
`cappedCurl()` (`Panel.qml:107`), identical in shape to
`kairos.flight-tracker/Panel.qml`'s (already-reviewed) helper:

```sh
timeout -k 2 <deadline> sh -c 'cap="$1"; shift; curl "$@" | head -c "$cap"' sh <cap+1> -fsSL --max-time <inner>
```

- `head -c` closes the pipe at the byte ceiling before `StdioCollector` can
  hold more than that.
- `cap+1` bytes requested, not `cap`, so a body sitting exactly at the ceiling
  stays distinguishable from a truncated one.
- `timeout`/`curl --max-time` both set, clamped to a minimum of 1s.
- URL and every curl option travel as argv entries, nothing spliced into the
  script text.

Cap is 3 MiB, sized from measured replies to
`https://en.wikipedia.org/api/rest_v1/feed/onthisday/events/{mm}/{dd}`: 638 KB
(Aug 23), 970 KB (Jan 1, the largest of several dates sampled), 630 KB
(Dec 25), 320 KB (Feb 29) -- over 3x headroom above the busiest measured date.

Collections are bounded independently of bytes: `parseEvents()` stops
appending once the result reaches 300 items (measured max seen: 69 events for
a single day).

## Review capabilities: none

No installer, no package manager, no privilege escalation, no remote build,
no bundled executable binary, no service management, no sudoers modification.
No `sudo`, no systemd units, no Hyprland keybind edits.

The plugin writes nothing to disk -- no state file, no cache, no temporary
directory -- so the findings around predictable paths, symlink-redirected
truncation, TOCTOU check-then-reopen, and untrusted fields becoming path
components have no surface here. There are no PIDs stored and no signals
sent, and no settings/config schema at all.

## Rate limits

One endpoint, key-free. The panel fetches once on load and otherwise only
when the local calendar date has rolled over since the last successful fetch
(checked by a 10-minute timer with no network cost of its own) or when the
user clicks Reload. "Another fact" re-picks from the events already held in
memory and never triggers a request.

## Verification performed

- `omarchy plugin validate .` → exit 0
- `scripts/preflight.sh .` → 2 hits, both explained above
- `qmllint` on both `.qml` files → no syntax errors; only expected
  unresolved-import warnings for the shell-provided `qs.Commons`/`qs.Ui`
  modules, the same class of warning any plugin gets outside a running shell
- Installed, enabled, hard-refreshed (`qmlcache` dropped, `omarchy restart
  shell`) -- confirmed no QML load errors in the journal
- Screenshot-confirmed: the bookmark icon renders in the configured bar
  section; `qs ipc call kairos.day-in-history open` opened the panel showing
  a real fact fetched live for today's actual date (August 23: the 1973
  Stockholm bank robbery/hostage crisis that coined "Stockholm syndrome");
  `qs ipc call kairos.day-in-history refresh` re-fetched and rendered a
  different real event (a 406 AD battle), confirming the fetch → parse →
  sanitise → random-pick → render path end to end, twice
- Not separately fault-injected: the error-state UI (`hasError`/`errorText`
  + "Try Again") was verified by reading the code against
  `kairos.flight-tracker`'s identical, already-reviewed try/catch +
  `onExited` shape, not by forcing a live failure in this session
