import { Buffer } from "std/core/buffer";
import { Bytes } from "std/core/buffer/bytes";
import { wipeBytes } from "./secret";

/** An owned copy of the bytes an operation reads: a string is its UTF-8 bytes. */
export function bytesOf<D extends ByteInput>(data: D): Buffer {
	if (typeof data == "string") return Buffer.fromString(data, "utf8");
	const owned = new Array<uint8>(0);
	for (const b of data) owned.push(b);
	return owned as Buffer;
}

/** Clears `bytes` when bytesOf made it from a string: that UTF-8 copy is the operation's own, so a secret in it must not outlive the call. */
export function wipeIfCopied(data: Bytes, bytes: Buffer): void {
	if (typeof data == "string") wipeBytes(bytes);
}

test "wipeIfCopied clears a string's copy and leaves a caller's buffer alone" {
	const caller = Buffer.fromString("caller key", "utf8");
	wipeIfCopied(caller, bytesOf(caller));
	assert caller.length == 10 && caller[0] == 99 && caller[9] == 121;
	const copy = bytesOf("secret");
	wipeIfCopied("secret", copy);
	let combined = 0;
	for (const byte of copy) combined |= byte as int32;
	assert copy.length == 6 && combined == 0;
}
