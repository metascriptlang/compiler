// Every std/compress result that is bytes is a Buffer: a 256-byte payload with every byte value
// survives each format and the ZIP archive, and the compressed lengths count bytes.
//
// @skip-js: std/compress has no JS surface
// @skip-raiser: the raiser std/compress carries only the string-typed zip submodule
// @stdout: payload 256
// @stdout: gzip stored 279 1f8b true
// @stdout: zlib stored 267 78 true
// @stdout: raw stored 261 true
// @stdout: gzip repeated true true
// @stdout: stream 260 true
// @stdout: zip 2 504b0304 256 true hello
// @exit: 0

import { Buffer } from "std/core/buffer";
import { rawString } from "std/core/buffer/bytes";
import { CompressError } from "std/compress/errors";
import { gzip, deflate, deflateRaw, createDeflate, deflateFeed, deflateFinish, CompressFormat } from "std/compress/deflate";
import { gunzip, inflate, inflateRaw, createInflate, inflateFeed, inflateFinish } from "std/compress/inflate";
import { newZipWriter, zipAdd, zipFinalize, closeZipWriter, openZip, zipCount, zipExtractByName, closeZip } from "std/compress/zip";

function need<T>(result: Result<T, CompressError>, what: string): T {
	if (!result.ok) throw new Error(what + " failed");
	return result.value;
}

function hex(buf: Buffer, n: number): string {
	return buf.toStringEncoded("hex", 0, n);
}

let allBytes = "";
for (let i = 0; i < 256; i++) allBytes += (i < 16 ? "0" : "") + i.toString(16);
const payload = Buffer.fromString(allBytes, "hex");
console.log("payload", payload.length);

const stored: Buffer = need(gzip(payload, 0), "gzip");
console.log("gzip stored", stored.length, hex(stored, 2), Buffer.compare(need(gunzip(stored), "gunzip"), payload) == 0);
const zlibStored: Buffer = need(deflate(payload, 0), "deflate");
console.log("zlib stored", zlibStored.length, hex(zlibStored, 1), Buffer.compare(need(inflate(zlibStored), "inflate"), payload) == 0);
const rawStored: Buffer = need(deflateRaw(payload, 0), "deflateRaw");
console.log("raw stored", rawStored.length, Buffer.compare(need(inflateRaw(rawStored), "inflateRaw"), payload) == 0);

const repeated = Buffer.fromString("ab".repeat(5000), "utf8");
const packed: Buffer = need(gzip(repeated, 9), "gzip");
console.log("gzip repeated", packed.length < 100, Buffer.compare(need(gunzip(rawString(packed)), "gunzip string"), repeated) == 0);

const enc = createDeflate(CompressFormat.Zlib, 6);
const dec = createInflate(CompressFormat.Zlib);
const parts: Buffer[] = [];
parts.push(need(deflateFeed(enc, payload), "deflateFeed"));
parts.push(need(deflateFeed(enc, "tail"), "deflateFeed"));
parts.push(need(deflateFinish(enc), "deflateFinish"));
const streamed = Buffer.concatList(parts);
const out: Buffer[] = [];
out.push(need(inflateFeed(dec, streamed), "inflateFeed"));
out.push(need(inflateFinish(dec), "inflateFinish"));
const plain = Buffer.concatList(out);
console.log("stream", plain.length, Buffer.compare(plain, Buffer.concat(payload, Buffer.fromString("tail", "utf8"))) == 0);

const w = need(newZipWriter(), "newZipWriter");
need(zipAdd(w, "bin", payload, 0), "zipAdd");
need(zipAdd(w, "text", "hello", 6), "zipAdd");
const archive: Buffer = need(zipFinalize(w), "zipFinalize");
closeZipWriter(w);
const r = need(openZip(archive), "openZip");
const bin: Buffer = need(zipExtractByName(r, "bin"), "extract bin");
const text: Buffer = need(zipExtractByName(r, "text"), "extract text");
console.log("zip", zipCount(r), hex(archive, 4), bin.length, Buffer.compare(bin, payload) == 0, text.asString());
closeZip(r);
