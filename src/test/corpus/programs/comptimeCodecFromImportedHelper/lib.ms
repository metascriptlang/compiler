import { encodeHex, decodeHex, encodeBase64, decodeBase64 } from "std/core/encoding";

function bytesOf(text: string): uint8[] {
	const b: uint8[] = [];
	for (let i = 0; i < text.byteLength; i = i + 1) b.push(text.byteAt(i) as uint8);
	return b;
}

export function codecLine(text: string): string {
	const hex = bytesOf(text).encodeHex();
	const b64 = bytesOf(text).encodeBase64();
	return `[${hex}] [${b64}] [${hex.decodeHex().asString()}] [${b64.decodeBase64().asString()}]`;
}
