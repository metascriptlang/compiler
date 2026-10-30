// Parity program — one-shot deflate/inflate round-trip at sizes around the 64 KiB queue
// steps and at 1 MiB, with Buffer input (every byte value) and string input, in all three formats.
//
// @skip-js: std/compress has no JS surface
// @xfail(raiser): std/compress resolves only its zip submodule on Raiser
// @stdout: ok 36 corrupt 6
// @exit: 0

import { Buffer } from "std/core/buffer";
import { gzip, deflate, deflateRaw } from "std/compress/deflate";
import { gunzip, inflate, inflateRaw } from "std/compress/inflate";

function bytesOf(n: number): Buffer {
	const b = Buffer.alloc(n);
	let x: int64 = 12345;
	for (let i = 0; i < n; i++) {
		x = (x * 1103515245 + 12345) % 2147483648;
		b[i] = (i % 7 == 0 ? (x >> 16) % 256 : 97 + (i % 5)) as uint8;
	}
	return b;
}

function same(a: Buffer, b: Buffer): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
	return true;
}

const sizes = [0, 1, 65535, 65536, 65537, 1048576];
let ok = 0;
for (const n of sizes) {
	const data = bytesOf(n);
	const text = "abcdefghij".repeat(n / 10 + 1).slice(0, n);
	const asText = Buffer.fromString(text, "utf8");
	const g = gunzip(try gzip(data) catch Buffer.alloc(0));
	const z = inflate(try deflate(data) catch Buffer.alloc(0));
	const r = inflateRaw(try deflateRaw(data) catch Buffer.alloc(0));
	const gs = gunzip(try gzip(text) catch Buffer.alloc(0));
	const zs = inflate(try deflate(text) catch Buffer.alloc(0));
	const rs = inflateRaw(try deflateRaw(text) catch Buffer.alloc(0));
	if (g.ok && same(g.value, data)) ok++;
	if (z.ok && same(z.value, data)) ok++;
	if (r.ok && same(r.value, data)) ok++;
	if (gs.ok && same(gs.value, asText)) ok++;
	if (zs.ok && same(zs.value, asText)) ok++;
	if (rs.ok && same(rs.value, asText)) ok++;
}
let corrupt = 0;
const packed = try gzip(bytesOf(1000)) catch Buffer.alloc(0);
if (!gunzip(packed.slice(0, packed.length - 4)).ok) corrupt++;
if (!gunzip(Buffer.fromString("not a gzip stream", "utf8")).ok) corrupt++;
const invalidBlock = Buffer.alloc(4);
for (let i = 0; i < 4; i++) invalidBlock[i] = 255;
if (!inflateRaw(invalidBlock).ok) corrupt++;
if (!gunzip(Buffer.alloc(0)).ok) corrupt++;
if (!inflate("").ok) corrupt++;
if (!inflateRaw(Buffer.alloc(0)).ok) corrupt++;
console.log(`ok ${ok} corrupt ${corrupt}`);
