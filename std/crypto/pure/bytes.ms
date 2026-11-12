import { Buffer } from "std/core/buffer";
import { ByteInput } from "std/core/buffer/bytes";
import { wipeBytes } from "./secret";

when (!js) {
	/** The bytes a kernel reads in place: any view of the caller's bytes. */
	export type InputBytes = Readonly<Span<uint8>>;
	/** Where a kernel writes bytes: on C any view, a Buffer's included, on JavaScript an array. */
	export type OutputBytes = Span<uint8>;
	/** A kernel's fresh result: on C the Buffer the API returns, on JavaScript an array. */
	export type OutputArray = Buffer;

	export function outputArray(size: number): OutputArray {
		return new Buffer(size);
	}

	/** A kernel's result as the Buffer the API returns: on C the result itself. */
	@inline
	export function outputBuffer(bytes: OutputArray): Buffer {
		return bytes;
	}
} else {
	export type InputBytes = Readonly<Span<uint8>>;
	export type OutputBytes = uint8[];
	export type OutputArray = uint8[];

	export function outputArray(size: number): OutputArray {
		return new Array<uint8>(size);
	}

	/** A kernel's result as the Buffer the API returns: on JavaScript a copy of the array. */
	export function outputBuffer(bytes: OutputArray): Buffer {
		return Buffer.from(bytes);
	}
}

/** An owned copy of the bytes an operation reads: a string is its UTF-8 bytes. */
export function bytesOf<D extends ByteInput>(data: D): uint8[] {
	return typeof data == "string" ? ownedBytes(data.asBytes()) : ownedBytes(data);
}

function ownedBytes(bytes: Readonly<Span<uint8>>): uint8[] {
	const owned = new Array<uint8>(bytes.length);
	for (let i = 0; i < bytes.length; i++) owned[i] = bytes[i];
	return owned;
}

/** Clears the copy bytesOf made of `data`: it is the operation's own, so a secret in it must not outlive the call. */
export function wipeIfCopied<D extends ByteInput>(data: D, bytes: uint8[]): void {
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
