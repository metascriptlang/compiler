// @stdout: untyped Array
// @stdout: typed Array 3
// @stdout: array Array 3
// @stdout: short false
// @exit: 0
// note: cbor decode reads a Readonly<Span<uint8>>, so a Buffer, a uint8[] and a Uint8Array subarray decode in place; the subarray starts one byte into its buffer and stops one byte before its end.

import { Buffer } from "std/core/buffer";
import { CborKind, CborValue, decode, cborUntyped } from "std/serialize/cbor";

function itemCount(v: CborValue): number {
	if (v.kind == CborKind.Array) return v.items.length;
	return -1;
}

const enc: uint8[] = [0x83, 0x01, 0x62, 0x68, 0x69, 0x43, 0x07, 0x08, 0x09];
const viaFn = cborUntyped.parseValue(Buffer.fromArray([0x82, 0x05, 0x06]));
console.log(viaFn.ok ? `untyped ${viaFn.value.kind}` : `untyped err ${viaFn.error}`);

const u = new Uint8Array(enc.length + 2);
u[0] = 0xff;
u[enc.length + 1] = 0x00;
for (let i = 0; i < enc.length; i++) u[i + 1] = enc[i];
const typed = decode(u.subarray(1, enc.length + 1));
console.log(typed.ok ? `typed ${typed.value.kind} ${itemCount(typed.value)}` : `typed err ${typed.error}`);

const plain = decode(enc);
console.log(plain.ok ? `array ${plain.value.kind} ${itemCount(plain.value)}` : `array err ${plain.error}`);

console.log(`short ${decode(u.subarray(1, 4)).ok}`);
