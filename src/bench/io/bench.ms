// Run one binary at a time: a parallel job moves every number. The fs rows time the page cache, not the disk.
// std/fs is synchronous only and has no file handle, so the node twin uses node's Sync calls and appendFileSync.

import { Buffer } from "std/core/buffer";
import { readFile, readFileBytes, writeFile, writeFileBytes, appendFile, fileSize, readDirNames, mkdir, removeAll, join } from "std/fs";
import { IoError } from "std/io/errors";
import { tmpDir } from "std/os";
import { bench } from "../harness";

let sink: number = 0;

function must<T>(result: Result<T, IoError>): T {
	if (!result.ok) throw new Error("fs call failed");
	return result.value;
}

function bytesOf(count: int32): Buffer {
	const buf = Buffer.alloc(count);
	for (let i = 0; i < count; i++) buf.set(i, (i * 31 + 7) & 255);
	return buf;
}

const b4k = bytesOf(4096);
const b64k = bytesOf(65536);
const b512k = bytesOf(524288);
const b1m = bytesOf(1048576);
const target = Buffer.alloc(65536);
const scan = Buffer.alloc(1048576);
for (let i = 0; i < 16; i++) scan.set(1048560 + i, i + 1);
const needle = scan.slice(1048560, 1048576);

const text = "plain ascii text, héllo wörld — ünïcode ✓ ".repeat(24000);
const textBuf = Buffer.fromString(text, "utf8");
const textBytes = textBuf.byteLength();
const b64Text = b1m.toBase64();
const hexText = b1m.toHex();

bench("alloc 1 KB", 0, () => { sink += Buffer.alloc(1024).byteLength(); });
bench("alloc 1 MB", 1048576, () => { sink += Buffer.alloc(1048576).byteLength(); });
bench("from string utf8 1 MB", textBytes, () => { sink += Buffer.fromString(text, "utf8").byteLength(); });
bench("toString utf8 1 MB", textBytes, () => { sink += textBuf.toString().length; });
bench("base64 encode 1 MB", 1048576, () => { sink += b1m.toBase64().length; });
bench("base64 decode 1 MB", 1048576, () => { sink += Buffer.fromString(b64Text, "base64").byteLength(); });
bench("hex encode 1 MB", 1048576, () => { sink += b1m.toHex().length; });
bench("hex decode 1 MB", 1048576, () => { sink += Buffer.fromString(hexText, "hex").byteLength(); });
bench("concat 2x512 KB", 1048576, () => { sink += Buffer.concat(b512k, b512k).byteLength(); });
bench("slice copy 64 KB", 65536, () => { sink += b1m.slice(4096, 4096 + 65536).byteLength(); });
bench("copyTo 64 KB", 65536, () => { sink += b64k.copyTo(target, 0, 0, 65536); });
bench("indexOf byte 1 MB", 1048576, () => { sink += scan.indexOf(1, 0); });
bench("indexOf 16 B needle 1 MB", 1048576, () => { sink += scan.indexOfBuffer(needle, 0); });

const dir = join(tmpDir(), "msbench-io-ms-" + Date.now().toString());
must(removeAll(dir));
must(mkdir(dir));
const small = join(dir, "small.bin");
const large = join(dir, "large.bin");
const textFile = join(dir, "text.txt");
const log = join(dir, "append.log");
const listed = join(dir, "listed");
must(mkdir(listed));
for (let i = 0; i < 32; i++) must(writeFile(join(listed, "entry" + i.toString()), "x"));
must(writeFile(textFile, text));
const line = "0123456789abcdef".repeat(4);

bench("fs write+read 4 KB", 4096, () => {
	must(writeFileBytes(small, b4k));
	sink += must(readFileBytes(small)).byteLength();
});
bench("fs write+read 1 MB", 1048576, () => {
	must(writeFileBytes(large, b1m));
	sink += must(readFileBytes(large)).byteLength();
});
bench("fs readFile utf8 1 MB", textBytes, () => { sink += must(readFile(textFile)).length; });
bench("fs stat size", 0, () => { sink += fileSize(large); });
bench("fs readdir 32 entries", 0, () => { sink += must(readDirNames(listed)).length; });
bench("fs append 100x64 B", 0, () => {
	must(writeFile(log, ""));
	for (let i = 0; i < 100; i++) must(appendFile(log, line));
	sink += fileSize(log);
});

must(removeAll(dir));
if (sink < 0) console.log("unreachable", sink);
