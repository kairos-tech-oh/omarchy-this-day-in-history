import QtQuick
import "../HistoryLogic.js" as Logic

QtObject {
  function fail(code) {
    Qt.exit(code)
    return false
  }

  Component.onCompleted: {
    var origin = "https://en.wikipedia.org"
    var prefix = origin + "/api/rest_v1/feed/onthisday/events/"
    var day = Logic.todayMonthDay(new Date(2026, 0, 5, 12, 0))
    if (day.key !== "01-05") return fail(1)
    if (Logic.todayEndpoint(day, prefix, origin) !== prefix + "01/05") return fail(2)
    if (Logic.todayEndpoint({ mm: "../", dd: "05" }, prefix, origin) !== "") return fail(3)

    if (!isNaN(Logic.numberOrNaN(null)) || Logic.numberOrNaN("1969") !== 1969) return fail(10)
    if (/[<>&]/.test(Logic.sanitizeText("<img src=x>&", 400))) return fail(11)
    if (Logic.sanitizeText("Zürich — 東京", 400) !== "Zürich — 東京") return fail(12)
    if (Logic.barSafe("x".repeat(500)).length !== 200) return fail(13)

    if (Logic.utf8ByteLength("a😀b") !== 6 || Logic.utf8ByteLength("東") !== 3) return fail(20)
    var threw = false
    try { Logic.parseCappedJson(JSON.stringify({ t: "東東東東東東東東東東東東東東東東東東東東" }), 40) } catch (e) { threw = true }
    if (!threw) return fail(21)

    var feed = JSON.stringify({ events: [{ year: 1969, text: "Apollo" }, null, { year: null, text: "x" }, { year: 5000, text: "y" }, { year: "1066.4", text: "Hastings" }] })
    var ev = Logic.parseEvents(feed, 1048576, 300, -10000, 3000)
    if (ev.map(function (e) { return e.year }).join(",") !== "1969,1066") return fail(30)

    var cmd = Logic.cappedCurl(prefix, 10, 0)
    if (cmd[cmd.indexOf("--max-time") + 1] !== "1" || cmd[3] !== "6") return fail(40)
    if (cmd[cmd.indexOf("--max-redirs") + 1] !== "0") return fail(41)

    for (var i = 0, cur = 0; i < 500; i++) {
      var n = Logic.nextFactIndex(3, cur, Math.random)
      if (n === cur || n < 0 || n > 2) return fail(50)
      cur = n
    }
    if (Logic.nextFactIndex(0, 2, Math.random) !== -1) return fail(51)

    Qt.exit(0)
  }
}
