import { Buffer } from "std/core/buffer";
import { Bytes } from "std/core/buffer/bytes";

/** The bytes an operation reads: a string is its UTF-8 bytes, a byte array is itself. */
export function bytesOf(data: Bytes): Buffer {
	if (typeof data == "string") return Buffer.fromString(data, "utf8");
	return data as Buffer;
}
