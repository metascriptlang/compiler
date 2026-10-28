// Parity program — std/compress binds its runtime and miniz translation units through
// `@include` / `@compile` and round-trips through every format.
// Axes: gzip, zlib and raw deflate one-shot; a ZIP archive written then read back; each
// submodule imported directly as well as through std/compress.
//
// @skip-js: std/compress has no JS surface
// @xfail(raiser): std/compress resolves only its zip submodule on Raiser
// @stdout: gzip abcabcabc|zlib abcabcabc|raw abcabcabc|zip 2 one two
// @exit: 0

import { Buffer } from "std/core/buffer";
import { gzip, gunzip, deflate, inflate } from "std/compress";
import { deflateRaw } from "std/compress/deflate";
import { inflateRaw } from "std/compress/inflate";
import { newZipWriter, zipAdd, zipFinalize, closeZipWriter, openZip, zipCount, zipExtractByName, closeZip } from "std/compress/zip";

const text = "abcabcabc";
const g = try gunzip(try gzip(text) catch Buffer.alloc(0)) catch Buffer.fromString("gzip failed", "utf8");
const z = try inflate(try deflate(text) catch Buffer.alloc(0)) catch Buffer.fromString("zlib failed", "utf8");
const r = try inflateRaw(try deflateRaw(text) catch Buffer.alloc(0)) catch Buffer.fromString("raw failed", "utf8");

const w = try newZipWriter() catch null;
const addOne = zipAdd(w!, "one.txt", "one");
const addTwo = zipAdd(w!, "two.txt", "two");
const archive = try zipFinalize(w!) catch Buffer.alloc(0);
closeZipWriter(w!);
const reader = try openZip(archive) catch null;
const one = try zipExtractByName(reader!, "one.txt") catch Buffer.fromString("missing", "utf8");
const two = try zipExtractByName(reader!, "two.txt") catch Buffer.fromString("missing", "utf8");
const count = zipCount(reader!);
closeZip(reader!);

console.log(`gzip ${g.asString()}|zlib ${z.asString()}|raw ${r.asString()}|zip ${count} ${one.asString()} ${two.asString()}`);
