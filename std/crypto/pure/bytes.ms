import { Buffer } from "std/core/buffer";
import { ByteInput } from "std/core/buffer/bytes";

/** An owned copy of the bytes an operation reads: a string is its UTF-8 bytes. */
export function bytesOf<D extends ByteInput>(data: D): Buffer {
	if (typeof data == "string") return Buffer.fromString(data, "utf8");
	const owned = new Array<uint8>(0);
	for (const b of data) owned.push(b);
	return owned as Buffer;
}
