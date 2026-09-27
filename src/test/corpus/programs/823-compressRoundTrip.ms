// Parity program — std/compress binds its runtime and miniz translation units through
// `@include` / `@compile` and round-trips through every format.
// Axes: gzip, zlib and raw deflate one-shot; a ZIP archive written then read back; each
// submodule imported directly as well as through std/compress.
//
// @skip-js: std/compress has no JS surface
// @xfail(raiser): std/compress resolves only its zip submodule on Raiser
// @stdout: gzip abcabcabc|zlib abcabcabc|raw abcabcabc|zip 2 one two
// @exit: 0

import { gzip, gunzip, deflate, inflate } from "std/compress";
import { deflateRaw } from "std/compress/deflate";
import { inflateRaw } from "std/compress/inflate";
import { newZipWriter, zipAdd, zipFinalize, closeZipWriter, openZip, zipCount, zipExtractByName, closeZip } from "std/compress/zip";

const text = "abcabcabc";
const g = try gunzip(try gzip(text) catch "") catch "gzip failed";
const z = try inflate(try deflate(text) catch "") catch "zlib failed";
const r = try inflateRaw(try deflateRaw(text) catch "") catch "raw failed";

const w = try newZipWriter() catch null;
const addOne = zipAdd(w!, "one.txt", "one");
const addTwo = zipAdd(w!, "two.txt", "two");
const archive = try zipFinalize(w!) catch "";
closeZipWriter(w!);
const reader = try openZip(archive) catch null;
const one = try zipExtractByName(reader!, "one.txt") catch "missing";
const two = try zipExtractByName(reader!, "two.txt") catch "missing";
const count = zipCount(reader!);
closeZip(reader!);

console.log(`gzip ${g}|zlib ${z}|raw ${r}|zip ${count} ${one} ${two}`);
