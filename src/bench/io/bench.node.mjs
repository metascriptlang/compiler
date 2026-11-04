// std/fs is synchronous only and has no file handle, so each fs row uses node's Sync call, and the append row reopens
// the file per write with appendFileSync as std's appendFile does. std's slice copies, so this arm copies the
// subarray; node's own slice is a view.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { bench } from "../harness.mjs";

let sink = 0;

function bytesOf(count) {
	const buf = Buffer.alloc(count);
	for (let i = 0; i < count; i++) buf[i] = (i * 31 + 7) & 255;
	return buf;
}

const b4k = bytesOf(4096);
const b64k = bytesOf(65536);
const b512k = bytesOf(524288);
const b1m = bytesOf(1048576);
const target = Buffer.alloc(65536);
const scan = Buffer.alloc(1048576);
for (let i = 0; i < 16; i++) scan[1048560 + i] = i + 1;
const needle = Buffer.from(scan.subarray(1048560, 1048576));

const text = "plain ascii text, héllo wörld — ünïcode ✓ ".repeat(24000);
const textBuf = Buffer.from(text, "utf8");
const textBytes = textBuf.length;
const b64Text = b1m.toString("base64");
const hexText = b1m.toString("hex");

bench("alloc 1 KB", 0, () => { sink += Buffer.alloc(1024).length; });
bench("alloc 1 MB", 1048576, () => { sink += Buffer.alloc(1048576).length; });
bench("from string utf8 1 MB", textBytes, () => { sink += Buffer.from(text, "utf8").length; });
bench("toString utf8 1 MB", textBytes, () => { sink += textBuf.toString().length; });
bench("base64 encode 1 MB", 1048576, () => { sink += b1m.toString("base64").length; });
bench("base64 decode 1 MB", 1048576, () => { sink += Buffer.from(b64Text, "base64").length; });
bench("hex encode 1 MB", 1048576, () => { sink += b1m.toString("hex").length; });
bench("hex decode 1 MB", 1048576, () => { sink += Buffer.from(hexText, "hex").length; });
bench("concat 2x512 KB", 1048576, () => { sink += Buffer.concat([b512k, b512k]).length; });
bench("slice copy 64 KB", 65536, () => { sink += Buffer.from(b1m.subarray(4096, 4096 + 65536)).length; });
bench("copyTo 64 KB", 65536, () => { sink += b64k.copy(target, 0, 0, 65536); });
bench("indexOf byte 1 MB", 1048576, () => { sink += scan.indexOf(1, 0); });
bench("indexOf 16 B needle 1 MB", 1048576, () => { sink += scan.indexOf(needle, 0); });

const dir = path.join(os.tmpdir(), "msbench-io-node-" + process.pid);
fs.rmSync(dir, { recursive: true, force: true });
fs.mkdirSync(dir);
const small = path.join(dir, "small.bin");
const large = path.join(dir, "large.bin");
const textFile = path.join(dir, "text.txt");
const log = path.join(dir, "append.log");
const listed = path.join(dir, "listed");
fs.mkdirSync(listed);
for (let i = 0; i < 32; i++) fs.writeFileSync(path.join(listed, "entry" + i), "x");
fs.writeFileSync(textFile, text);
const line = "0123456789abcdef".repeat(4);

bench("fs write+read 4 KB", 4096, () => {
	fs.writeFileSync(small, b4k);
	sink += fs.readFileSync(small).length;
});
bench("fs write+read 1 MB", 1048576, () => {
	fs.writeFileSync(large, b1m);
	sink += fs.readFileSync(large).length;
});
bench("fs readFile utf8 1 MB", textBytes, () => { sink += fs.readFileSync(textFile, "utf8").length; });
bench("fs stat size", 0, () => { sink += fs.statSync(large).size; });
bench("fs readdir 32 entries", 0, () => { sink += fs.readdirSync(listed).length; });
bench("fs append 100x64 B", 0, () => {
	fs.writeFileSync(log, "");
	for (let i = 0; i < 100; i++) fs.appendFileSync(log, line);
	sink += fs.statSync(log).size;
});

fs.rmSync(dir, { recursive: true, force: true });
if (sink < 0) console.log("unreachable", sink);
