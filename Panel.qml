import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "HistoryLogic.js" as Logic

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

  function todayMonthDay() { return Logic.todayMonthDay(new Date()) }

  function todayLabel() {
    var now = new Date()
    return now.toLocaleDateString(Qt.locale(), "MMMM d")
  }

  function numberOrNaN(value) { return Logic.numberOrNaN(value) }

  function sanitizeText(raw, maxLength) { return Logic.sanitizeText(raw, maxLength) }

  function cappedCurl(url, capBytes, maxTimeSec, extraArgs) { return Logic.cappedCurl(url, capBytes, maxTimeSec, extraArgs) }

  function todayEndpoint() { return Logic.todayEndpoint(root.todayMonthDay(), root.endpointPrefix, root.allowedOrigin) }

  function utf8ByteLength(text) { return Logic.utf8ByteLength(text) }

  function parseCappedJson(raw, capBytes) { return Logic.parseCappedJson(raw, capBytes) }

  function parseEvents(raw) { return Logic.parseEvents(raw, root.eventsCapBytes, root.maxEvents, root.minYear, root.maxYear) }

  function pickRandomFact() { root.currentIndex = Logic.nextFactIndex(root.events.length, root.currentIndex, Math.random) }


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
