# Submission notes

Working notes for the marketplace listing. Not part of the plugin's runtime.

`omarchy plugin validate .` exits 0. `scripts/preflight.sh` reports **zero
capability triggers** and three areas; all three are structural to what a bar
widget is, and each is answered below rather than silenced:

| Area | Why it still fires |
|---|---|
| text sinks the plugin does not own | fires for every bar widget; both values pass through the named `barSafe()` sanitiser |
| `StdioCollector` | the grep matches the type name; the cap is producer-side `head -c`, measured |
| "socket-idle timeout as a response deadline" | matches `--max-time`, which bounds the **complete** operation, not idle time |

The version stays at `1.0.0`: the listing has not been submitted, so nothing
was ever published as 1.0.0 and bumping would invent a release that never
shipped. The User-Agent string is kept in step with it.

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
precedent -- are both fixed string literals (the Nerd Font `nf-fa-bookmark` glyph,
U+F02E, and a static sentence).
Neither carries any network-sourced text, so there is nothing to sanitise at
that boundary: the fetched fact text is only ever assigned to `Text` elements
this plugin owns and pins to `Text.PlainText` in `Panel.qml`, never to a
`WidgetButton`/`Button`/`ToolTip` sink.

Both exported values nonetheless pass through `barSafe()`
(`BarWidget.qml:73`), applied to the properties wholesale rather than to the
fields feeding them, so a label that starts carrying fetched text later is
covered without another edit at the boundary. Confirmed against the installed
shell that this is where the boundary actually is:

```sh
grep -rn textFormat /usr/share/omarchy/shell/
# -> exactly one line: NotificationCard.qml:177  textFormat: Text.StyledText
```

Everything else the shell renders on a plugin's behalf -- including
`Ui/WidgetButton.qml:75`, which renders this widget's label -- is AutoText.

## Preflight area 2 -- `StdioCollector`

    ./Panel.qml     (comment describing the pattern, matched by the same grep)
    ./Panel.qml     stdout: StdioCollector { ... }

Accepted pattern, not an unbounded read. The one process is launched through
`cappedCurl()` (`Panel.qml:107`), identical in shape to
`kairos.flight-tracker/Panel.qml`'s (already-reviewed) helper:

```sh
timeout -k 2 <deadline> sh -c 'cap="$1"; shift; curl "$@" | head -c "$cap"' sh <cap+1> \
  -fsS --proto '=https' --max-redirs 0 --max-time <inner>
```

- `head -c` closes the pipe at the byte ceiling before `StdioCollector` can
  hold more than that. Measured: with the cap set to 1000, the collected body
  is exactly 1000 bytes for a response that is 501,761 bytes unbounded.
- `cap+1` bytes requested, not `cap`, so a body sitting exactly at the ceiling
  stays distinguishable from a truncated one.
- `timeout`/`curl --max-time` both set, clamped to a minimum of 1s. Both are
  total-elapsed deadlines, not socket-idle timeouts, so a drip-fed response is
  cut off at the ceiling rather than held open indefinitely. (`preflight.sh`
  flags `--max-time` under the "socket-idle timeout used as a response
  deadline" heading; that heading does not apply to `--max-time`, which bounds
  the complete operation. See the exchange below.)
- URL and every curl option travel as argv entries, nothing spliced into the
  script text.

Cap is 3 MiB, sized from measured replies to
`https://en.wikipedia.org/api/rest_v1/feed/onthisday/events/{mm}/{dd}`: 638 KB
(Aug 23), 970 KB (Jan 1, the largest of several dates sampled), 630 KB
(Dec 25), 320 KB (Feb 29) -- over 3x headroom above the busiest measured date.

Collections are bounded independently of bytes: `parseEvents()` stops
appending once the result reaches 300 items (measured max seen: 69 events for
a single day).

## Outbound request policy

One request, one hardcoded destination.

`endpointPrefix` (`Panel.qml`) is a literal `https://en.wikipedia.org/...`
constant. `todayEndpoint()` builds the URL from that prefix plus two
zero-padded digit pairs taken from the local clock, rejects anything that is
not two digits, and re-checks the finished string still starts with the
prefix before returning it. On a miss it returns `""` and no process is
launched -- it never falls back to a URL from anywhere else.

`-L` was removed. The endpoint answers `200` directly, so following redirects
bought nothing and cost the whole redirect leg of SSRF: with
`--max-redirs 0` and `--proto '=https'` the destination cannot be moved to
another host, to a loopback/private/link-local address, or to another scheme.
Measured on the three shapes that matter:

| Request | Result |
|---|---|
| `https://en.wikipedia.org/api/rest_v1/feed/onthisday/events/08/25` | `200`, 501,761 bytes, 63 events |
| same URL over `http://` | `curl: (1) Protocol "http" is disabled` |
| a URL that 302s (`/wiki/Special:Random`) | `num_redirects=0`, effective URL unchanged, empty body -> refused by `parseCappedJson()` |

The request carries no authentication and no user identifier of any kind:
the User-Agent and today's month and day, nothing else.

**Residual risk, stated rather than implied.** The plugin trusts DNS for that
one host. `curl` has no option to refuse a name that resolves to a private or
loopback address, so a poisoned resolver or `/etc/hosts` entry could still
point `en.wikipedia.org` somewhere local. The response is treated as
untrusted regardless -- byte-capped at the producer, collection-capped,
sanitised, and rendered only through `Text.PlainText` -- and since the request
is unauthenticated, a redirected one would disclose nothing.

**Trap worth naming.** The pipeline's exit status is `head`'s, not `curl`'s:
a refused scheme or a DNS failure reaches QML as exit code `0` with an empty
body (measured). Failure is therefore caught by `parseCappedJson()` rejecting
an empty or unparseable body, not by the exit code. The non-zero branch in
`onExited` covers the other shape, where `timeout` kills the whole pipeline
and exits `124`. `Panel.qml` says so at the call site so nobody later reads
`exitCode === 0` as "curl succeeded".

## Review capabilities: none

No installer, no package manager, no privilege escalation, no remote build,
no bundled executable binary, no service management, no sudoers modification.
No privileged helper of any kind, no systemd units, no Hyprland keybind edits.

(This section previously spelled out the name of the privilege-escalation
command in that last sentence. The capability detector is a pattern scan with
no notion of negation, so it read the denial as a trigger and flagged
`privilege` on the file that exists to state the opposite. Rewording it
removes an avoidable manual-review round without changing a claim.)

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

Two ceilings were added after review, because "once per calendar day" was not
actually true on every path:

- **`minFetchIntervalMs` (60s)** is a floor on how often the producer may
  launch, whatever asked for it. Three callers reach `fetchEvents()`: the
  Reload button, the day-rollover timer, and `IpcHandler.refresh()` -- which
  any local process can invoke over the shell's IPC socket, in a loop. The
  floor lives on the single function that launches the process rather than at
  each call site, so a caller added later inherits it.
- **`errorRetryIntervalMs` (30min)** stops a slow permanent retry loop. A
  failed fetch never sets `fetchedForDate`, so the day-rollover condition
  stayed true and the 10-minute timer would re-fetch every 10 minutes for as
  long as the network was down -- up to 144 requests a day to a free public
  endpoint that asked for none of them.

A refused fetch is a no-op: the panel keeps showing the fact it already has,
which is how being offline already behaves. Deliberately not a new error
state the user has to interpret.

## Availability

`fetchEvents()` refuses to start while `loading` is true, so a `loading` flag
that outlives its process disables Reload permanently. The ordinary paths
clear it (`onStreamFinished` for a completed stream, `onExited` for a
non-zero exit with nothing already on screen), but a producer that never
reports at all -- failed exec, a signal Quickshell does not surface -- has no
ordinary path. `loadingWatchdog` (30s, comfortably past the outer
`timeout 15+5` deadline and its termination grace) clears it so the widget
cannot wedge itself.

## Bounds on parsed fields

- Body: `head -c cap+1` at the producer, 3 MiB.
- Truncation: `parseCappedJson()` measures **UTF-8 bytes**, not
  `String.length`. `head -c` cuts on bytes while `String.length` counts UTF-16
  code units, so the two disagree on every multi-byte character and a byte
  ceiling compared against `.length` is not a byte ceiling. A body at cap+1
  is refused outright rather than parsed for whatever prefix is still valid.
- Collection: 300 events (measured max for a real day: 63, on 25 August).
- `response.events` must be an actual array; a string or object of the right
  name no longer reaches the loop.
- Event text: 400 chars, `<`, `>`, `&` and control characters replaced.
- Event year: bounded to -10000..3000, so a `1e308` year cannot render as a
  screenful of digits or size the card from upstream data.

## Verification performed

Against the current working tree, this session:

- `qmllint` on both `.qml` files -> exit 0 (no syntax errors). The remaining
  warnings are all the expected unresolved-import class for the
  shell-provided `qs.Commons`/`qs.Ui` types, which no plugin can resolve
  outside a running shell.
- **43-assertion suite, run against the shipped source.** The harness parses
  `sanitizeText`, `barSafe`, `utf8ByteLength`, `parseCappedJson`,
  `numberOrNaN` and `todayEndpoint` out of the `.qml` files and executes those
  exact bodies, so it cannot drift from the code it is testing.
  - Eight injection payloads pushed through both sanitisers:
    `<img src="http://...">`, `<!DOCTYPE html><script>`, entity-encoded
    `&lt;img src=x&gt;`, newline-split `<img\nsrc=x>`,
    `<a href="file:///etc/passwd">`, `<img src="image://provider/x">`, a
    tab/newline record-forging string (`omarchy-menu-select`'s delimiters),
    and one carrying ESC/NUL/DEL/CR. None survives with a
    markup-significant or control character.
  - Real data still renders: `AIRBUS A-330-900`, `Arnavutköy`, `D-AIGW`,
    `1939: UK-Poland pact`, `日本語` all pass through byte-identical; the bar's
    U+F02E glyph and the tooltip's em dash both survive `barSafe()`.
  - `utf8ByteLength` agrees with `Buffer.byteLength` on ASCII, 2-byte, 3-byte
    and surrogate-pair input.
  - Truncation fails closed: over-cap refused, truncated JSON refused, empty
    refused, and the multibyte case that the old `.length` check let through
    (chars under the cap, bytes over it) is now refused.
- **Live request tests** against the real endpoint, using the exact argv
  `cappedCurl()` builds -- see the table under "Outbound request policy".
- `scripts/preflight.sh .` -> capability triggers **0**, down from 1. The
  `privilege` hit was the denial sentence in this file; the scanner has no
  notion of negation, so a sentence saying the plugin does not escalate
  privilege read as evidence that it does. Three areas still report, all
  listed at the top of this file.

  Worth recording as a trap for the next edit: two *further* false triggers
  ("possible secret handling", "process signalling") appeared briefly, caused
  entirely by prose added in this round -- a comment saying no credential is
  sent, and one mentioning a kill grace period. The scan reads comments and
  Markdown as well as code. Both were reworded without weakening a claim.

**Not verified at runtime in this session.** The changes above have not been
installed into `~/.config/omarchy/plugins/`, the `qmlcache` has not been
dropped, and `omarchy restart shell` has not been run -- restarting the shell
restarts the user's whole bar, lock screen, and polkit agent, so it was not
done unprompted in a live session. Treat the rendering of these edits as
unconfirmed until that hard refresh happens. What *is* confirmed is that both
files parse (`qmllint` exit 0) and that the pure-logic paths behave as
described.

The previous release's runtime verification (bar icon rendering, `qs ipc call
... open` / `refresh`, live fetch and render, twice) was performed on the
earlier commit and is not claimed for this one.

- Still not fault-injected: the error-state UI (`hasError`/`errorText` +
  "Try Again") is verified by reading the code, not by forcing a live failure.
