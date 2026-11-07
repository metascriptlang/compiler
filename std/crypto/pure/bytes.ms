import { Buffer } from "std/core/buffer";
import { ByteInput } from "std/core/buffer/bytes";
import { wipeBytes } from "./secret";

when (!js) {
	/** The bytes a kernel reads in place: on C any view of the caller's bytes, on JavaScript an array. */
	export type InputBytes = Readonly<Span<uint8>>;
} else {
	export type InputBytes = Readonly<uint8[]>;
}

/** An owned copy of the bytes an operation reads: a string is its UTF-8 bytes. */
export function bytesOf<D extends ByteInput>(data: D): Buffer {
	if (typeof data == "string") return Buffer.fromString(data, "utf8");
	const owned = new Array<uint8>(0);
	for (const b of data) owned.push(b);
	return owned as Buffer;
}

/** Clears the copy bytesOf made of `data`: it is the operation's own, so a secret in it must not outlive the call. */
export function wipeIfCopied<D extends ByteInput>(data: D, bytes: Buffer): void {
	wipeBytes(bytes);
}

test "wipeIfCopied clears the copy and leaves a caller's buffer alone" {
	const caller = Buffer.fromString("caller key", "utf8");
	const copy = bytesOf(caller);
	wipeIfCopied(caller, copy);
	assert caller.length == 10 && caller[0] == 99 && caller[9] == 121;
	let combined = 0;
	for (const byte of copy) combined |= byte as int32;
	assert copy.length == 10 && combined == 0;
}
