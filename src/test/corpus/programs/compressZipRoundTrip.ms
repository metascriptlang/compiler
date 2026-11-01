// Parity program — std/compress/zip carries the same reader and writer API on C and Raiser.
// Axes: a stored and a deflated entry, a directory entry, an empty file, lookup by index and
// by name, a missing name, an out-of-range index, a large entry that deflates.
//
// @skip-js: std/compress has no JS surface
// @stdout: 4|a.txt 5 false|d/ 0 true|e.txt 0 false|big.bin 65536 false|hello|hello|2|-1|miss|bad|65536 120
// @exit: 0

import { newZipWriter, zipAdd, zipFinalize, closeZipWriter, openZip, zipCount, zipEntries, zipFindByName, zipExtract, zipExtractByName, closeZip } from "std/compress/zip";

const w = try newZipWriter() catch null;
zipAdd(w!, "a.txt", "hello", 0);
zipAdd(w!, "d/", "");
zipAdd(w!, "e.txt", "");
zipAdd(w!, "big.bin", "x".repeat(65536), 9);
const archive = try zipFinalize(w!) catch null;
closeZipWriter(w!);

const r = try openZip(archive!) catch null;
const lines: string[] = [`${zipCount(r!)}`];
for (const e of zipEntries(r!)) lines.push(`${e.name} ${e.size} ${e.isDir}`);

const byIndex = try zipExtract(r!, 0) catch null;
const byName = try zipExtractByName(r!, "a.txt") catch null;
lines.push(byIndex!.toString());
lines.push(byName!.toString());
lines.push(`${zipFindByName(r!, "e.txt")}`);
lines.push(`${zipFindByName(r!, "nope")}`);
const missing = try zipExtractByName(r!, "nope") catch null;
lines.push(missing == null ? "miss" : "found");
const bad = try zipExtract(r!, 99) catch null;
lines.push(bad == null ? "bad" : "ok");
const big = try zipExtractByName(r!, "big.bin") catch null;
const bigText = big!.toString();
lines.push(`${bigText.length} ${bigText.charCodeAt(65535)}`);
closeZip(r!);

console.log(lines.join("|"));
