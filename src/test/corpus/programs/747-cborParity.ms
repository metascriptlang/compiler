// @stdout: cbor parity ok

// Pins the CBOR encode/decode surface as it behaves on the C backend,
// including the paths that route through the Buffer scratch slots
// (msBufferAllocUnsafe/WriteDoubleBE in encoder, bitsToDouble in decoder).
// The js backend must match once std/core/buffer/index.jms lands.

import { encode, decode, CborKind } from "std/serialize/cbor";
import { cborInt, cborFloat, cborText, cborBytes, cborArray, cborTextMap, cborBool, cborNull } from "std/serialize/cbor/builder";
import { asNumber, asString, asBoolean, asInt64, at, length, getDynamicField } from "std/serialize/cbor/accessors";

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function roundInt(n: int64): boolean {
	const r = decode(encode(cborInt(n)));
	return r.ok && asNumber(r.value) === n;
}

function main(): void {
	let ok = true;

	// integer boundaries where the CBOR head encoding switches width.
	const bounds: int64[] = [0, 23, 24, 255, 256, 65535, 65536, 2147483647, -1, -1000];
	for (const n of bounds) {
		ok = check("int" + n, roundInt(n)) && ok;
	}

	// float64 round-trip is bit-exact through the scratch slot.
	const rPi = decode(encode(cborFloat(3.14159)));
	ok = check("floatPi", rPi.ok && asNumber(rPi.value) === 3.14159) && ok;
	const rTenth = decode(encode(cborFloat(0.1)));
	ok = check("floatTenth", rTenth.ok && asNumber(rTenth.value) === 0.1) && ok;

	// int64 accessor keeps the wide value.
	const rWide = decode(encode(cborInt(2000000000)));
	ok = check("int64acc", rWide.ok && asInt64(rWide.value) === 2000000000) && ok;

	// text with a multibyte char.
	const rTxt = decode(encode(cborText("héllo")));
	ok = check("text", rTxt.ok && asString(rTxt.value) === "héllo") && ok;

	// bytes payload survives the Buffer representation on both targets.
	const rByt = decode(encode(cborBytes(Buffer.fromArray([1, 2, 255]))));
	let bLen = -1;
	let bLast = -1;
	if (rByt.ok && rByt.value.kind === CborKind.Bytes) {
		const bb = rByt.value.bytesVal;
		bLen = bb.byteLength() as int32;
		bLast = bb.byteAt(2);
	}
	ok = check("bytes", bLen === 3 && bLast === 255) && ok;

	// heterogeneous array.
	const rArr = decode(encode(cborArray([cborInt(1), cborText("a"), cborBool(true)])));
	ok = check("array", rArr.ok && length(rArr.value) === 3 &&
		asNumber(at(rArr.value, 0)) === 1 && asString(at(rArr.value, 1)) === "a") && ok;
	ok = check("bool", rArr.ok && asBoolean(at(rArr.value, 2)) === true) && ok;

	// text-keyed map.
	const rMap = decode(encode(cborTextMap(["x", "y"], [cborInt(10), cborInt(20)])));
	ok = check("map", rMap.ok && length(rMap.value) === 2 &&
		asNumber(getDynamicField(rMap.value, "y")) === 20) && ok;

	// null survives the round-trip.
	const rNull = decode(encode(cborNull()));
	ok = check("null", rNull.ok) && ok;

	// a reserved break byte must produce an error, not a crash.
	const rBad = decode(Buffer.fromArray([0xff]));
	ok = check("badInput", !rBad.ok) && ok;

	if (!ok) { console.log("cbor parity FAILED"); return; }
	console.log("cbor parity ok");
}

main();
