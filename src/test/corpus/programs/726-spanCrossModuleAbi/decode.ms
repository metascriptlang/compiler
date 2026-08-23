export function parse(bytes: Span<uint8>): string {
	return bytes.length.toString() + ":" + bytes[0].toString() + "," + bytes[bytes.length - 1].toString();
}
