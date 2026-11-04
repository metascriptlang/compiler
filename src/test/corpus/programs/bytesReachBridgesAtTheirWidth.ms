// Parity program — a uint8[] built by any route reaches a byte bridge as the bytes it holds, and the
// bytes a bridge returns read back unchanged. On the Raiser each route must arrive as a uint8 array the
// bridge reads where the VM keeps it; a route that built another element width stops the run.
//
// @stdout: routes hi hi hi hi hi hi hi hi hi
// @stdout: raw hi hi hi 0
// @stdout: digest ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 32 same=true
// @stdout: text bytes 3 61,c3,a9 back=aé
// @exit: 0

import { rawString } from "std/core/buffer/bytes";
import { digestSync } from "std/crypto";

function copied<T>(xs: T[]): T[] {
	const out: T[] = [];
	for (const x of xs) out.push(x);
	return out;
}

function hex(bytes: Readonly<uint8[]>): string {
	let out = "";
	for (const b of bytes) out += b.toString(16).padStart(2, "0");
	return out;
}

const lit: uint8[] = [104, 105];
const pushed: uint8[] = [];
pushed.push(104);
pushed.push(105);
const alloc = Buffer.alloc(2);
alloc[0] = 104;
alloc[1] = 105;
const wide: uint8[] = [0, 104, 105, 0];
const sliced = wide.slice(1, 3);
const mapped = lit.map((x: uint8): uint8 => x);
const head: uint8[] = [104];
const tail: uint8[] = [105];
const joined = head.concat(tail);
const generic = copied(lit);
const decoded = Buffer.fromString("6869", "hex");
const filled = Buffer.allocUnsafe(2);
filled[0] = 104;
filled[1] = 105;

console.log(`routes ${lit.asString()} ${pushed.asString()} ${alloc.asString()} ${sliced.asString()} ${mapped.asString()} ${joined.asString()} ${generic.asString()} ${decoded.asString()} ${filled.asString()}`);

const none: uint8[] = [];
console.log(`raw ${rawString(lit)} ${rawString(mapped)} ${rawString(decoded)} ${rawString(none).length}`);

const abc: uint8[] = [97, 98, 99];
const ofText = digestSync("sha256", "abc");
const ofBytes = digestSync("sha256", abc);
if (ofText.ok && ofBytes.ok) {
	console.log(`digest ${hex(ofText.value)} ${ofText.value.length} same=${hex(ofText.value) == hex(ofBytes.value)}`);
} else {
	console.log("digest err");
}

const text = "aé";
const bytes = copied(text.asBytes().slice(0));
const shown: string[] = [];
for (const b of bytes) shown.push(b.toString(16));
console.log(`text bytes ${bytes.length} ${shown.join(",")} back=${bytes.asString()}`);
