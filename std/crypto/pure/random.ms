/** Random bytes for the portable code: the OS CSPRNG on C, `crypto.getRandomValues` on JS. */

when (js) {
	@emit(`function msPureRandom(size) {
	const out = new Uint8Array(size);
	for (let at = 0; at < size; at += 65536) globalThis.crypto.getRandomValues(out.subarray(at, Math.min(at + 65536, size)));
	return Array.from(out);
}`);

	extern function pureRandom(size: int32): uint8[] from "msPureRandom(#)";
}

when (c) {
	@include("runtime/crypto/randomFill.h");
	extern function osRandomFill(buf: Ptr<uint8>, len: int64): int32 from "ms_random_fill";
}

export function randomOctets(size: int32): uint8[] {
	when (js) {
		return pureRandom(size);
	} else when (c) {
		const bytes = new Array<uint8>(size);
		const target = (bytes as Span<uint8>) as Ptr<uint8>;
		if (size > 0 && osRandomFill(target, size as int64) != 0) throw new Error("randomOctets: the OS random source failed");
		return bytes;
	} else {
		throw new Error("randomOctets: this target has no random source for the portable code");
	}
}

export function randomInto(dst: uint8[], size: int32): void {
	when (c) {
		const target = (dst as Span<uint8>) as Ptr<uint8>;
		if (size > 0 && osRandomFill(target, size as int64) != 0) throw new Error("randomInto: the OS random source failed");
	} else {
		const bytes = randomOctets(size);
		for (let i: int32 = 0; i < size; i++) dst[i] = bytes[i];
	}
}
