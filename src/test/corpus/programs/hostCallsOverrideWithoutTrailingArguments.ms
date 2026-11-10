// Host JavaScript calls a method of a class over a host class the way it calls the host's own member,
// leaving trailing arguments out: Buffer's `subarray(begin)` keeps the bytes to the end, as Node's
// does, and a user class over Uint8Array applies the defaults it declares.
//
// @stdout: llo
// @stdout: tail 3 2
// @exit: 0

import { Buffer } from "std/core/buffer";

class Bytes extends Uint8Array {
	span(from: number = 2, to: number = this.length): number {
		return to - from;
	}
}

when (js) {
	extern function hostSubarray(b: Buffer, begin: number): Buffer from "#.subarray(#)";
	extern function hostSpan(b: Bytes): number from "#.span()";
	extern function hostSpanFrom(b: Bytes, from: number): number from "#.span(#)";
} else {
	function hostSubarray(b: Buffer, begin: number): Buffer { return b.subarray(begin); }
	function hostSpan(b: Bytes): number { return b.span(); }
	function hostSpanFrom(b: Bytes, from: number): number { return b.span(from); }
}

console.log(hostSubarray(Buffer.fromString("hello", "utf8"), 2).toString());
const bytes = new Bytes(5);
console.log(`tail ${hostSpan(bytes)} ${hostSpanFrom(bytes, 3)}`);
