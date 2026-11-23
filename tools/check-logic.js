#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(path.join(__dirname, "..", "HistoryLogic.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const ctx = {};
vm.runInNewContext(src + "\nthis.L = { todayMonthDay, numberOrNaN, sanitizeText, cappedCurl, todayEndpoint, utf8ByteLength, parseCappedJson, parseEvents, nextFactIndex, barSafe };", ctx);
const F = ctx.L;

let failed = 0;
function check(name, cond, detail) {
  if (cond) console.log("ok   " + name);
  else { failed++; console.log("FAIL " + name + (detail === undefined ? "" : "  got " + JSON.stringify(detail))); }
}
function throws(fn) { try { fn(); return false; } catch (e) { return true; } }

const ORIGIN = "https://en.wikipedia.org";
const PREFIX = ORIGIN + "/api/rest_v1/feed/onthisday/events/";

const jan5 = F.todayMonthDay(new Date(2026, 0, 5, 23, 59));
check("todayMonthDay zero-pads month and day", jan5.mm === "01" && jan5.dd === "05" && jan5.key === "01-05", jan5);
const dec31 = F.todayMonthDay(new Date(2026, 11, 31, 0, 1));
check("todayMonthDay uses the local date", dec31.key === "12-31", dec31);

check("todayEndpoint builds the feed URL", F.todayEndpoint(jan5, PREFIX, ORIGIN) === PREFIX + "01/05");
check("todayEndpoint refuses a non-digit month", F.todayEndpoint({ mm: "../", dd: "05" }, PREFIX, ORIGIN) === "");
check("todayEndpoint refuses a three-digit day", F.todayEndpoint({ mm: "01", dd: "005" }, PREFIX, ORIGIN) === "");
check("todayEndpoint refuses a prefix outside the origin", F.todayEndpoint(jan5, "https://evil.example/", ORIGIN) === "");

check("numberOrNaN: null, undefined and empty are NaN", [null, undefined, ""].every((v) => Number.isNaN(F.numberOrNaN(v))));
check("numberOrNaN: numbers and numeric strings parse", F.numberOrNaN("1969") === 1969 && F.numberOrNaN(-44) === -44);
check("numberOrNaN: junk is NaN", Number.isNaN(F.numberOrNaN("year one")) && Number.isNaN(F.numberOrNaN(Infinity)));

check("sanitizeText strips tag-shaped input", F.sanitizeText('<img src="http://x">Apollo', 400).indexOf("<") < 0);
check("sanitizeText replaces & and control characters", F.sanitizeText("A&B\nC\u0000D\u007fE", 400) === "A B C D E", F.sanitizeText("A&B\nC\u0000D\u007fE", 400));
check("sanitizeText keeps non-ASCII text", F.sanitizeText("Zürich — 東京", 400) === "Zürich — 東京");
check("sanitizeText truncates then trims", F.sanitizeText("  abcdef", 5) === "abc", F.sanitizeText("  abcdef", 5));
check("sanitizeText of null is empty", F.sanitizeText(null, 10) === "");

check("utf8ByteLength counts ASCII as 1", F.utf8ByteLength("abc") === 3);
check("utf8ByteLength counts 2- and 3-byte characters", F.utf8ByteLength("é") === 2 && F.utf8ByteLength("東") === 3);
check("utf8ByteLength counts a surrogate pair as 4", F.utf8ByteLength("😀") === 4 && F.utf8ByteLength("a😀b") === 6);

check("parseCappedJson: blank body throws", throws(() => F.parseCappedJson("  ", 100)));
const multibyte = JSON.stringify({ t: "東".repeat(20) });
check("parseCappedJson: caps on bytes, not UTF-16 units", multibyte.length <= 40 && throws(() => F.parseCappedJson(multibyte, 40)), multibyte.length);
check("parseCappedJson: a truncated body throws", throws(() => F.parseCappedJson('{"events":[{"year":1', 1000)));
check("parseCappedJson: valid body parses", F.parseCappedJson('{"a":1}', 100).a === 1);

const feed = JSON.stringify({ events: [
  { year: 1969, text: "Apollo 11 lands." },
  null,
  "not an object",
  { year: null, text: "No year." },
  { year: 1969, text: "" },
  { year: -44, text: "Caesar <b>assassinated</b>." },
  { year: 5000, text: "Too far ahead." },
  { year: -20000, text: "Too far back." },
  { year: "1066.4", text: "Hastings." }
] });
let events = [];
check("parseEvents survives null and non-object elements", !throws(() => { events = F.parseEvents(feed, 1 << 20, 300, -10000, 3000); }));
check("parseEvents keeps valid events and skips bad ones", events.map((e) => e.year).join(",") === "1969,-44,1066", events);
check("parseEvents sanitises event text", events.length > 1 && events[1].text.indexOf("<") < 0, events[1]);
check("parseEvents caps the number of events", F.parseEvents(feed, 1 << 20, 2, -10000, 3000).length === 2);
check("parseEvents with no events array is empty", F.parseEvents('{"other":1}', 100, 300, -10000, 3000).length === 0);
check("parseEvents over the byte cap throws", throws(() => F.parseEvents(feed, 50, 300, -10000, 3000)));

const cmd = F.cappedCurl(PREFIX + "01/05", 1000, 15, ["-A", "ua"]);
check("cappedCurl: caps at cap+1 bytes", cmd.indexOf("1001") > 0, cmd);
check("cappedCurl: https only, no redirects", cmd.indexOf("=https") > 0 && cmd[cmd.indexOf("--max-redirs") + 1] === "0" && !cmd.some((a) => /^-[A-Za-z]*L/.test(a) || /^--location/.test(a)), cmd);
check("cappedCurl: url is passed after --", cmd[cmd.length - 2] === "--" && cmd[cmd.length - 1] === PREFIX + "01/05");
check("cappedCurl: outer timeout exceeds curl's", cmd[3] === "20" && cmd[cmd.indexOf("--max-time") + 1] === "15", cmd);
const zero = F.cappedCurl(PREFIX, 10, 0);
check("cappedCurl: a zero budget still has a deadline", zero[zero.indexOf("--max-time") + 1] === "1" && zero[3] === "6", zero);

check("nextFactIndex: no events is -1", F.nextFactIndex(0, 3, Math.random) === -1);
check("nextFactIndex: one event is 0", F.nextFactIndex(1, 0, Math.random) === 0);
const seq = [0.1, 0.1, 0.1, 0.9];
let k = 0;
const scripted = () => seq[k++];
check("nextFactIndex: never repeats the current fact", F.nextFactIndex(4, 0, scripted) === 3 && k === 4, k);
let repeats = 0;
for (let i = 0, cur = 0; i < 2000; i++) { const n = F.nextFactIndex(3, cur, Math.random); if (n === cur || n < 0 || n > 2) repeats++; cur = n; }
check("nextFactIndex: 2,000 random picks stay in range and never repeat", repeats === 0, repeats);

check("barSafe removes markup characters", !/[<>&]/.test(F.barSafe("<b>x</b> & y")));
check("barSafe removes newlines", F.barSafe("a\nb").indexOf("\n") < 0);
check("barSafe caps at 200 characters", F.barSafe("x".repeat(500)).length === 200);
check("barSafe of null is empty", F.barSafe(null) === "");

console.log(failed === 0 ? "\nall logic checks passed" : "\n" + failed + " logic check(s) failed");
process.exit(failed === 0 ? 0 : 1);
