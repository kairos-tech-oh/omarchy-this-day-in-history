import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "kairos.day-in-history"
  ipcTarget: "kairos.day-in-history"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var events: []
  property int currentIndex: -1
  property bool loading: false
  property bool hasError: false
  property string errorText: ""
  property string fetchedForDate: ""
  property real lastUpdatedMs: 0

  // Sized from measured replies for the events endpoint: 638 KB (Aug 23),
  // 970 KB (Jan 1, the largest of several dates sampled), 630 KB (Dec 25),
  // 320 KB (Feb 29). 3 MiB leaves better than 3x headroom over the busiest.
  readonly property int eventsCapBytes: 3145728
  readonly property int maxEvents: 300

  // A year field arriving as 1e308 would otherwise render as a screenful of
  // digits and size the card from upstream data. Wikipedia's earliest "on this
  // day" events sit in the low thousands BC, so this bounds the field without
  // discarding anything the feed actually carries.
  readonly property int minYear: -10000
  readonly property int maxYear: 3000

  // Destination allowlist: exactly one origin, and exactly one path prefix
  // under it. Both are literals here -- never derived from a response, a
  // config file, or a setting -- and todayEndpoint() re-checks the finished
  // URL against both before any process is launched.
  readonly property string allowedOrigin: "https://en.wikipedia.org"
  readonly property string endpointPrefix: root.allowedOrigin + "/api/rest_v1/feed/onthisday/events/"

  // Floor on how often the producer may launch, whatever asked for it. Three
  // separate callers can reach fetchEvents(): the Reload button, the 10-minute
  // day-rollover timer, and IpcHandler.refresh(), which any local process can
  // invoke over the shell's IPC socket. The floor lives on the one function
  // that launches the process rather than at each call site, so a caller added
  // later inherits it.
  readonly property int minFetchIntervalMs: 60 * 1000

  // A failed fetch leaves fetchedForDate unset, so the day-rollover timer
  // would otherwise re-fetch every 10 minutes for as long as the network is
  // down -- 144 requests a day to a free public endpoint that asked for none
  // of them.
  readonly property int errorRetryIntervalMs: 30 * 60 * 1000

  property real lastFetchStartedMs: 0

  readonly property var currentFact: (root.currentIndex >= 0 && root.currentIndex < root.events.length)
      ? root.events[root.currentIndex] : null

  function open() {
    root.controller.show()
  }

  function openFromHotkey() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Local calendar date, not UTC -- "today" here means the user's own today.
  function todayMonthDay() {
    var now = new Date()
    var mm = String(now.getMonth() + 1).padStart(2, "0")
    var dd = String(now.getDate()).padStart(2, "0")
    return { mm: mm, dd: dd, key: mm + "-" + dd }
  }

  function todayLabel() {
    var now = new Date()
    return now.toLocaleDateString(Qt.locale(), "MMMM d")
  }

  // Number(null) is 0 and isFinite(null) is true, so a JSON null "year" would
  // otherwise read as a genuine event from year zero rather than being dropped.
  function numberOrNaN(value) {
    if (value === null || value === undefined || value === "") return NaN
    var parsed = Number(value)
    return isFinite(parsed) ? parsed : NaN
  }

  // Every Text element in this panel is pinned Text.PlainText, and this is the
  // second layer: markup-significant and control characters are stripped from
  // the upstream text before it is ever stored, so a sink added later can
  // never inherit a raw string carrying them. Char codes are walked directly
  // (not a regex control-char range) to sidestep encoding a raw control byte
  // into this source file.
  function sanitizeText(raw, maxLength) {
    var input = String(raw === undefined || raw === null ? "" : raw)
    var out = ""
    for (var i = 0; i < input.length && out.length < maxLength; i++) {
      var code = input.charCodeAt(i)
      var ch = input.charAt(i)
      if (code < 32 || code === 127) { out += " "; continue }
      if (ch === "<" || ch === ">" || ch === "&") { out += " "; continue }
      out += ch
    }
    return out.trim()
  }

  // Every network producer is built here. Both bounds are external to the QML
  // side on purpose: StdioCollector retains the whole of stdout before
  // onStreamFinished ever runs, so a size check up there is too late to bound
  // anything -- the memory is already committed inside omarchy-shell.
  //
  //   head -c        closes the pipe at the byte ceiling, at the producer
  //   timeout        outer wall-clock deadline that keeps running while curl
  //                  is blocked in a syscall
  //   --max-time     curl's own limit on the COMPLETE operation. Both of these
  //                  are total-elapsed deadlines, not socket-idle timeouts, so
  //                  a server drip-feeding one byte every 50ms is cut off at
  //                  the ceiling instead of holding the transfer open forever.
  //   --proto =https
  //   --max-redirs 0 pin the destination to the literal URL built by
  //                  todayEndpoint(). -L is deliberately absent: the endpoint
  //                  answers 200 directly (measured), so nothing is lost, and
  //                  without redirects a compromised or hostile reply cannot
  //                  move the request to another host, to a loopback/private/
  //                  link-local address, or to another scheme. That closes the
  //                  redirect leg of SSRF without needing to re-validate a
  //                  destination that can never change.
  //
  // cap+1 bytes are requested so a body sitting exactly at the ceiling stays
  // distinguishable from one that got cut off. The URL and every curl option
  // travel as argv entries -- nothing is ever spliced into the script text.
  //
  // Trap worth naming: the pipeline's exit status is head's, not curl's, so a
  // curl failure (refused scheme, DNS failure, 404 under -f) reaches QML as
  // exit code 0 with an empty body -- measured. That still fails closed, in
  // parseCappedJson(), which rejects an empty or unparseable body; the
  // non-zero branch in onExited covers the other shape, where `timeout` kills
  // the whole pipeline and exits 124. Do not read exitCode here as "curl
  // succeeded".
  //
  // Residual, stated rather than implied: the plugin trusts DNS for the one
  // hardcoded host. curl offers no way to refuse a name that resolves to a
  // private or loopback address, so a poisoned resolver or hosts entry could
  // still point en.wikipedia.org somewhere local. The response is treated as
  // untrusted either way -- capped, sanitised, and rendered as plain text --
  // and the request carries no authentication of any kind, so even a
  // redirected request would disclose nothing beyond the User-Agent and
  // today's month and day.
  function cappedCurl(url, capBytes, maxTimeSec, extraArgs) {
    var innerSec = Math.max(1, Math.round(maxTimeSec))
    var deadlineSec = Math.max(1, innerSec + 5)
    var command = ["timeout", "-k", "2", String(deadlineSec),
                   "sh", "-c", 'cap="$1"; shift; curl "$@" | head -c "$cap"', "sh",
                   String(capBytes + 1),
                   "-fsS", "--proto", "=https", "--max-redirs", "0",
                   "--max-time", String(innerSec)]
    if (extraArgs) command = command.concat(extraArgs)
    return command.concat(["--", String(url)])
  }

  // Built from the hardcoded prefix plus two zero-padded digit pairs taken
  // from the local clock, then checked against that same prefix before it can
  // be handed to curl. mm/dd never come from a response today; the check is
  // here so that a future caller cannot introduce a URL sourced from data
  // without tripping it. Returns "" rather than a fallback URL on a miss.
  function todayEndpoint() {
    var today = root.todayMonthDay()
    if (!/^[0-9]{2}$/.test(today.mm) || !/^[0-9]{2}$/.test(today.dd)) return ""
    var url = root.endpointPrefix + today.mm + "/" + today.dd
    if (url.indexOf(root.allowedOrigin + "/") !== 0) return ""
    if (url.indexOf(root.endpointPrefix) !== 0) return ""
    return url
  }

  // head -c cuts on BYTES; String.length counts UTF-16 code units, and the two
  // disagree on every multi-byte character -- so a byte ceiling compared
  // against .length is not a byte ceiling. Measured in the unit the producer
  // actually cut in.
  function utf8ByteLength(text) {
    var bytes = 0
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i)
      if (code < 0x80) bytes += 1
      else if (code < 0x800) bytes += 2
      else if (code >= 0xd800 && code <= 0xdbff) { bytes += 4; i++ }
      else bytes += 3
    }
    return bytes
  }

  // Fails closed on truncation. A body that came back at cap+1 bytes is
  // refused outright rather than parsed for whatever prefix happens to still
  // be valid: a document that parses but is silently missing its tail is worse
  // than no document. JSON.parse is the backstop for a cut landing
  // mid-character or mid-element, but the byte check is what makes the refusal
  // deliberate rather than incidental.
  function parseCappedJson(raw, capBytes) {
    var text = String(raw || "")
    if (text.trim() === "") throw new Error("empty response")
    if (root.utf8ByteLength(text) > capBytes) throw new Error("response exceeded " + capBytes + " bytes")
    return JSON.parse(text)
  }

  function parseEvents(raw) {
    var response = root.parseCappedJson(raw, root.eventsCapBytes)
    var list = (response && Array.isArray(response.events)) ? response.events : []
    var result = []
    for (var i = 0; i < list.length && result.length < root.maxEvents; i++) {
      // A null or non-object element would throw on property access and take
      // the whole response down with it, via the try/catch in
      // onStreamFinished -- one bad entry costing the user every other event
      // of the day. Skip the element instead.
      if (!list[i] || typeof list[i] !== "object") continue
      var year = root.numberOrNaN(list[i].year)
      var text = root.sanitizeText(list[i].text, 400)
      if (text !== "" && isFinite(year) && year >= root.minYear && year <= root.maxYear)
        result.push({ year: Math.round(year), text: text })
    }
    return result
  }

  function pickRandomFact() {
    if (root.events.length === 0) {
      root.currentIndex = -1
      return
    }
    if (root.events.length === 1) {
      root.currentIndex = 0
      return
    }
    var next = root.currentIndex
    while (next === root.currentIndex) next = Math.floor(Math.random() * root.events.length)
    root.currentIndex = next
  }

  // The one place the producer is launched, so the rate floor cannot be
  // bypassed by adding a caller. A refused fetch is a no-op: the panel keeps
  // showing the fact it already has, which is how being offline already
  // behaves -- deliberately not a new error state the user has to interpret.
  function fetchEvents() {
    if (root.loading) return false
    var now = Date.now()
    var sinceLast = now - root.lastFetchStartedMs
    // A negative elapsed means the wall clock moved backwards (NTP step,
    // manual change, DST-adjacent tick). Treat that as "interval elapsed"
    // rather than locking fetching out until the clock catches up again.
    if (root.lastFetchStartedMs > 0 && sinceLast >= 0 && sinceLast < root.minFetchIntervalMs)
      return false
    var url = root.todayEndpoint()
    if (url === "") return false
    root.lastFetchStartedMs = now
    root.loading = true
    root.hasError = false
    loadingWatchdog.restart()
    eventsProcess.command = root.cappedCurl(
      url, root.eventsCapBytes, 15,
      ["-A", "kairos-day-in-history/1.0 (https://github.com/kairos-tech-oh/omarchy-this-day-in-history)"])
    eventsProcess.running = true
    return true
  }

  // Called by the 10-minute timer -- no network call unless the calendar date
  // has actually rolled over since the last successful fetch.
  //
  // A failed fetch never sets fetchedForDate, so without the backoff below
  // this condition stays true and the timer retries every 10 minutes for as
  // long as the network is down. The backoff is separate from
  // minFetchIntervalMs on purpose: the floor exists to stop bursts, this
  // exists to stop a slow permanent retry loop against a free public API.
  function refreshIfNewDay() {
    if (root.loading) return
    if (root.todayMonthDay().key === root.fetchedForDate) return
    if (root.hasError && root.lastFetchStartedMs > 0) {
      var sinceLast = Date.now() - root.lastFetchStartedMs
      if (sinceLast >= 0 && sinceLast < root.errorRetryIntervalMs) return
    }
    root.fetchEvents()
  }

  function reload() {
    root.fetchEvents()
  }

  function relativeUpdateLabel() {
    if (root.lastUpdatedMs <= 0) return ""
    var minutes = Math.max(0, Math.floor((Date.now() - root.lastUpdatedMs) / 60000))
    if (minutes < 1) return "Updated just now"
    if (minutes < 60) return "Updated " + minutes + "m ago"
    return "Updated " + Math.floor(minutes / 60) + "h ago"
  }

  IpcHandler {
    target: root.ipcTarget
    function open() { root.openFromHotkey() }
    function close() { root.close() }
    function show() { root.openFromHotkey() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { root.reload(); return "ok" }
  }

  Process {
    id: eventsProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = root.parseEvents(text)
          if (parsed.length === 0) throw new Error("no events for today")
          root.events = parsed
          root.fetchedForDate = root.todayMonthDay().key
          root.lastUpdatedMs = Date.now()
          root.hasError = false
          root.pickRandomFact()
        } catch (error) {
          root.hasError = true
          root.errorText = "Unable to load today's history"
        }
        loadingWatchdog.stop()
        root.loading = false
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.events.length === 0) {
        root.hasError = true
        root.errorText = "Unable to load today's history"
        loadingWatchdog.stop()
        root.loading = false
      }
    }
  }

  // fetchEvents() refuses to start while `loading` is true, so a `loading`
  // that outlives its process disables Reload permanently. Every ordinary
  // path clears it -- onStreamFinished for a completed stream, onExited for a
  // non-zero exit with nothing already on screen -- but a producer that never
  // reports at all (failed exec, a signal Quickshell does not surface) has no
  // ordinary path. The outer producer deadline is timeout(15+5)s; 30s leaves
  // margin over that and over the termination grace period, so it only fires
  // for a process that genuinely went missing.
  Timer {
    id: loadingWatchdog
    interval: 30000
    repeat: false
    onTriggered: root.loading = false
  }

  Timer {
    interval: 1
    running: true
    repeat: false
    onTriggered: root.fetchEvents()
  }

  Timer {
    interval: 10 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.refreshIfNewDay()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(420))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(12)

          Row {
            width: parent.width
            spacing: Style.space(8)

            Column {
              width: parent.width - reloadButton.width - parent.spacing
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "THIS DAY IN HISTORY"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.todayLabel() + (root.relativeUpdateLabel() !== "" ? " - " + root.relativeUpdateLabel() : "")
                color: Qt.darker(root.bar.foreground, 1.25)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            Button {
              id: reloadButton
              text: root.loading ? "Reloading..." : "Reload"
              implicitWidth: Style.space(84)
              implicitHeight: Style.space(30)
              enabled: !root.loading
              onClicked: root.reload()

              background: Rectangle {
                color: "transparent"
                border.color: root.bar.foreground
                border.width: 1
                radius: Style.space(4)
                opacity: reloadButton.enabled ? 1.0 : 0.45
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.loading && root.events.length === 0

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Fetching today's history from Wikipedia..."
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.hasError && root.events.length === 0

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.errorText
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
            }

            Button {
              text: "Try Again"
              implicitHeight: Style.space(30)
              onClicked: root.reload()
              background: Rectangle {
                color: "transparent"
                border.color: root.bar.foreground
                border.width: 1
                radius: Style.space(4)
              }
            }
          }

          Column {
            id: factCard
            width: parent.width
            spacing: Style.space(8)
            visible: root.currentFact !== null

            Rectangle {
              width: parent.width
              height: factColumn.implicitHeight + Style.space(24)
              radius: Style.space(6)
              color: Qt.darker(root.bar.foreground, 6)

              Column {
                id: factColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(12)
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.currentFact ? "In " + root.currentFact.year : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.currentFact ? root.currentFact.text : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.Wrap
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                id: shuffleButton
                text: "Another fact"
                implicitHeight: Style.space(30)
                enabled: root.events.length > 1
                onClicked: root.pickRandomFact()
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                  opacity: shuffleButton.enabled ? 1.0 : 0.45
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.events.length + " events found for today. Data: Wikipedia contributors, CC BY-SA 4.0"
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }
        }
      }
    }
  }
}
