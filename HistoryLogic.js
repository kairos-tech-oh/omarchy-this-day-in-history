.pragma library

// Local calendar date, not UTC -- "today" here means the user's own today.
function todayMonthDay(now) {
  now = now || new Date()
  var mm = String(now.getMonth() + 1).padStart(2, "0")
  var dd = String(now.getDate()).padStart(2, "0")
  return { mm: mm, dd: dd, key: mm + "-" + dd }
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
function todayEndpoint(today, endpointPrefix, allowedOrigin) {
    if (!/^[0-9]{2}$/.test(today.mm) || !/^[0-9]{2}$/.test(today.dd)) return ""
  var url = endpointPrefix + today.mm + "/" + today.dd
  if (url.indexOf(allowedOrigin + "/") !== 0) return ""
  if (url.indexOf(endpointPrefix) !== 0) return ""
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
  if (utf8ByteLength(text) > capBytes) throw new Error("response exceeded " + capBytes + " bytes")
  return JSON.parse(text)
}

function parseEvents(raw, capBytes, maxEvents, minYear, maxYear) {
  var response = parseCappedJson(raw, capBytes)
  var list = (response && Array.isArray(response.events)) ? response.events : []
  var result = []
  for (var i = 0; i < list.length && result.length < maxEvents; i++) {
    // A null or non-object element would throw on property access and take
    // the whole response down with it, via the try/catch in
    // onStreamFinished -- one bad entry costing the user every other event
    // of the day. Skip the element instead.
    if (!list[i] || typeof list[i] !== "object") continue
    var year = numberOrNaN(list[i].year)
    var text = sanitizeText(list[i].text, 400)
    if (text !== "" && isFinite(year) && year >= minYear && year <= maxYear)
      result.push({ year: Math.round(year), text: text })
  }
  return result
}

function nextFactIndex(count, current, random) {
  if (count <= 0) return -1
  if (count === 1) return 0
  var next = current
  while (next === current) next = Math.floor(random() * count)
  return next
}

function barSafe(value) {
  var input = String(value === undefined || value === null ? "" : value)
  var out = ""
  for (var i = 0; i < input.length && out.length < 200; i++) {
    var code = input.charCodeAt(i)
    var ch = input.charAt(i)
    if (code < 32 || code === 127) { out += " "; continue }
    if (ch === "<" || ch === ">" || ch === "&") { out += " "; continue }
    out += ch
  }
  return out.trim()
}
