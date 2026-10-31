// Parity program — gunzip over members built by hand with Python's zlib: optional header fields
// (FEXTRA, FNAME, FCOMMENT, FHCRC), trailer CRC32 and ISIZE checks, truncation, concatenated
// members, zero padding and trailing garbage.
// Axes: one-shot gunzip of each blob, and the same blobs through the streaming API in 3-byte chunks.
//
// @skip-js: std/compress has no JS surface
// @xfail(raiser): std/compress resolves only its zip submodule on Raiser
// @stdout: extra ok|all ok|plain ok|two ok first second|zeros ok|badcrc checksum|badsize length|badhcrc checksum|trunc truncated|garbage trailing|stream extra ok|stream all ok|stream two ok first second|stream badcrc checksum|stream trunc truncated|stream garbage trailing|zlib ok hello zlib|zlib badadler checksum
// @exit: 0

import { Buffer } from "std/core/buffer";
import { gunzip, inflate, createInflate, inflateFeed, inflateFinish, CompressError, CompressErrorKind } from "std/compress/inflate";

function hex(s: string): Buffer {
	return Buffer.fromString(s, "hex");
}

const member = "cb48cdc9c95748afca2c50c84dcd4d4a2d2ad651c8c010e30200df67002c27000000";
const blobs = new Map<string, string>();
blobs.set("extra", "1f8b080400000000000307004142030078797a" + member);
blobs.set("all", "1f8b081e00000000000307004142030078797a612e747874006e6f746500ec58" + member);
blobs.set("plain", "1f8b08000000000000" + "03" + member);
blobs.set("two", "1f8b08000000000000034bcb2c2a2e510000fc7af11c060000001f8b08000000000000032b4e4dcecf4b010069111fb606000000");
blobs.set("zeros", "1f8b08000000000000" + "03" + member + "00000000");
blobs.set("badcrc", "1f8b0800000000000003cb48cdc9c95748afca2c50c84dcd4d4a2d2ad651c8c010e302007856341227000000");
blobs.set("badsize", "1f8b0800000000000003cb48cdc9c95748afca2c50c84dcd4d4a2d2ad651c8c010e30200df67002c05000000");
blobs.set("badhcrc", "1f8b080a0000000000036f002334" + member);
blobs.set("trunc", "1f8b0800000000000003cb48cdc9c95748afca2c50c84dcd4d4a2d2ad651c8c010e30200df6700");
blobs.set("garbage", "1f8b08000000000000" + "03" + member + "6a756e6b");

function kindName(e: CompressError): string {
	if (e.kind == CompressErrorKind.Truncated) return "truncated";
	if (e.kind == CompressErrorKind.ChecksumMismatch) return "checksum";
	if (e.kind == CompressErrorKind.LengthMismatch) return "length";
	if (e.kind == CompressErrorKind.TrailingGarbage) return "trailing";
	return "invalid";
}

function show(r: Result<Buffer, CompressError>): string {
	if (r.ok) return "ok" + (r.value.length == 39 ? "" : " " + r.value.toString().trim());
	return kindName(r.error);
}

const lines: string[] = [];
for (const name of ["extra", "all", "plain", "two", "zeros", "badcrc", "badsize", "badhcrc", "trunc", "garbage"]) {
	lines.push(name + " " + show(gunzip(hex(blobs.get(name)!))));
}

function streamed(name: string): string {
	const data = hex(blobs.get(name)!);
	const s = createInflate();
	const collected: number[] = [];
	for (let i = 0; i < data.length; i += 3) {
		const r = inflateFeed(s, data.slice(i, Math.min(i + 3, data.length)));
		if (!r.ok) return kindName(r.error);
		for (let j = 0; j < r.value.length; j++) collected.push(r.value[j]);
	}
	const end = inflateFinish(s);
	if (!end.ok) return kindName(end.error);
	for (let j = 0; j < end.value.length; j++) collected.push(end.value[j]);
	const out = Buffer.alloc(collected.length);
	for (let j = 0; j < collected.length; j++) out[j] = collected[j] as uint8;
	return show(Result.ok(out));
}
for (const name of ["extra", "all", "two", "badcrc", "trunc", "garbage"]) {
	lines.push("stream " + name + " " + streamed(name));
}
lines.push("zlib " + show(inflate(hex("789ccb48cdc9c957a8cac94c0200159503e6"))));
lines.push("zlib badadler " + show(inflate(hex("789ccb48cdc9c957a8cac94c0200159503e7"))));
console.log(lines.join("|"));
