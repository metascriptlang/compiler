// @skip-js: std/compress and std/net are .cms modules, C backend only
// @skip-raiser: the raiser carries only the string-typed zip submodule and no std/net
// @serial
// @stdout: gzip abc abc abc abc abc
// @stdout: deflate abc abc abc
// @stdout: stream abc
// @stdout: zip 4 abc abc abc abc
// @stdout: net 3 3 3 3 abcabcabcabc
// @stdout: nonblock 3 2 abcbc
// @stdout: async 3 3 abcabc
// @exit: 0

import { Buffer } from "std/core/buffer";
import { CompressError } from "std/compress/errors";
import { createDeflate, deflate, deflateFeed, deflateFinish, deflateRaw, gzip, CompressFormat } from "std/compress/deflate";
import { gunzip, inflate, inflateRaw } from "std/compress/inflate";
import { closeZip, closeZipWriter, newZipWriter, openZip, zipAdd, zipCount, zipExtractByName, zipFinalize } from "std/compress/zip";
import { accept, bind, close, connect, createSocket, listen, recv, send, sendAsync, sendNonBlock } from "std/net";

function need<T>(result: Result<T, CompressError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

function text(b: Buffer): string {
	return b.asString();
}

function viaSpan(s: Readonly<Span<uint8>>): Buffer {
	return need(gzip(s));
}

const abc: uint8[] = [97, 98, 99];
const wide = new Uint8Array(5);
wide[1] = 97;
wide[2] = 98;
wide[3] = 99;
const abcView = wide.subarray(1, 4);
const abcBuffer = Buffer.fromString("abc", "utf8");
const either: string | uint8[] = abc.length > 0 ? abc : "abc";

console.log("gzip", text(need(gunzip(need(gzip("abc"))))), text(need(gunzip(need(gzip(abc, 9))))), text(need(gunzip(need(gzip(abcView))))),
	text(need(gunzip(viaSpan(abcView)))), text(need(gunzip(need(gzip(either))))));
const zlibbed = need(deflate(abcBuffer));
const zlibCopy = new Uint8Array(zlibbed.length);
for (let i = 0; i < zlibbed.length; i++) zlibCopy[i] = zlibbed[i];
const raw = need(deflateRaw(abcView, 1));
console.log("deflate", text(need(inflate(zlibbed))), text(need(inflate(zlibCopy))), text(need(inflateRaw(raw))));

const stream = createDeflate(CompressFormat.Gzip);
const parts: uint8[] = [];
for (const b of need(deflateFeed(stream, "a"))) parts.push(b);
for (const b of need(deflateFeed(stream, abcView.subarray(1, 2)))) parts.push(b);
for (const b of need(deflateFeed(stream, [99] as uint8[]))) parts.push(b);
for (const b of need(deflateFinish(stream))) parts.push(b);
console.log("stream", text(need(gunzip(parts))));

const writer = need(newZipWriter());
need(zipAdd(writer, "s", "abc"));
need(zipAdd(writer, "a", abc, 0));
need(zipAdd(writer, "v", abcView));
need(zipAdd(writer, "b", abcBuffer));
const archive = need(zipFinalize(writer));
closeZipWriter(writer);
const wideArchive = new Uint8Array(archive.length + 2);
for (let i = 0; i < archive.length; i++) wideArchive[i + 1] = archive[i];
const reader = need(openZip(wideArchive.subarray(1, archive.length + 1)));
console.log("zip", zipCount(reader), text(need(zipExtractByName(reader, "s"))), text(need(zipExtractByName(reader, "a"))),
	text(need(zipExtractByName(reader, "v"))), text(need(zipExtractByName(reader, "b"))));
closeZip(reader);

function listenOnFreePort(): int32[] {
	let port = (20000 + Date.now() % 20000) as int32;
	while (true) {
		const fd = createSocket();
		if (bind(fd, "127.0.0.1", port) >= 0 && listen(fd, 4) >= 0) return [fd, port];
		close(fd);
		port = port + 1;
	}
}

function pair(): int32[] {
	const lp = listenOnFreePort();
	const client = createSocket();
	connect(client, "127.0.0.1", lp[1]);
	const peer = accept(lp[0]);
	close(lp[0]);
	return [peer, client];
}

function recvAll(fd: int32, want: int32): string {
	let got = "";
	while (got.length < want) {
		const chunk = recv(fd, 64);
		if (chunk.length == 0) break;
		got += text(chunk);
	}
	return got;
}

const p = pair();
console.log("net", send(p[0], "abc"), send(p[0], abc), send(p[0], abcView), send(p[0], either), recvAll(p[1], 12));
console.log("nonblock", sendNonBlock(p[0], abcBuffer, 0), sendNonBlock(p[0], abcView, 1), recvAll(p[1], 5));
console.log("async", await sendAsync(p[0], abcView), await sendAsync(p[0], "abc"), recvAll(p[1], 6));
close(p[0]);
close(p[1]);
