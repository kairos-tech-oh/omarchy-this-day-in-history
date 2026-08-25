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
  //   head -c   closes the pipe at the byte ceiling, at the producer
  //   timeout   is the deadline that still applies while curl is blocked in a
  //             syscall; curl's own --max-time is the inner limit
  //
  // cap+1 bytes are requested so a body sitting exactly at the ceiling stays
  // distinguishable from one that got cut off. The URL and every curl option
  // travel as argv entries -- nothing is ever spliced into the script text.
  function cappedCurl(url, capBytes, maxTimeSec, extraArgs) {
    var innerSec = Math.max(1, Math.round(maxTimeSec))
    var deadlineSec = Math.max(1, innerSec + 5)
    var command = ["timeout", "-k", "2", String(deadlineSec),
                   "sh", "-c", 'cap="$1"; shift; curl "$@" | head -c "$cap"', "sh",
                   String(capBytes + 1),
                   "-fsSL", "--max-time", String(innerSec)]
    if (extraArgs) command = command.concat(extraArgs)
    return command.concat(["--", String(url)])
  }

  function parseCappedJson(raw, capBytes) {
    var text = String(raw || "")
    if (text.trim() === "") throw new Error("empty response")
    if (text.length > capBytes) throw new Error("response exceeded " + capBytes + " bytes")
    return JSON.parse(text)
  }

  function parseEvents(raw) {
    var response = root.parseCappedJson(raw, root.eventsCapBytes)
    var list = response.events || []
    var result = []
    for (var i = 0; i < list.length && result.length < root.maxEvents; i++) {
      var year = root.numberOrNaN(list[i].year)
      var text = root.sanitizeText(list[i].text, 400)
      if (text !== "" && isFinite(year)) result.push({ year: Math.round(year), text: text })
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

  function fetchEvents() {
    if (root.loading) return
    root.loading = true
    root.hasError = false
    var today = root.todayMonthDay()
    eventsProcess.command = root.cappedCurl(
      "https://en.wikipedia.org/api/rest_v1/feed/onthisday/events/" + today.mm + "/" + today.dd,
      root.eventsCapBytes, 15,
      ["-A", "kairos-day-in-history/1.0 (https://github.com/kairos-tech-oh/omarchy-this-day-in-history)"])
    eventsProcess.running = true
  }

  // Called by the 10-minute timer -- no network call unless the calendar date
  // has actually rolled over since the last successful fetch.
  function refreshIfNewDay() {
    if (root.loading) return
    if (root.todayMonthDay().key !== root.fetchedForDate) root.fetchEvents()
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
        root.loading = false
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.events.length === 0) {
        root.hasError = true
        root.errorText = "Unable to load today's history"
        root.loading = false
      }
    }
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
