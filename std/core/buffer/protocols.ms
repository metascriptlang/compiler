import { Buffer } from "./type";

export interface BufferJson {
	type: string;
	data: number[];
}

const hexDigits = "0123456789abcdef";

function numbersOf(bytes: Readonly<Span<uint8>>): number[] {
	const data: number[] = [];
	for (let i = 0; i < bytes.length; i++) data.push(bytes[i]);
	return data;
}

function inspectOf(bytes: Readonly<Span<uint8>>): string {
	const shown = bytes.length < 50 ? bytes.length : 50;
	let out = "<Buffer ";
	for (let i = 0; i < shown; i++) {
		if (i > 0) out += " ";
		out += hexDigits.charAt(bytes[i] >> 4) + hexDigits.charAt(bytes[i] & 15);
	}
	const rest = bytes.length - shown;
	if (rest > 0) out += " ... " + rest.toString() + (rest == 1 ? " more byte" : " more bytes");
	return out + ">";
}

export function toJSON(this b: Buffer): BufferJson {
	return { type: "Buffer", data: numbersOf(b) };
}

export function inspect(this b: Buffer): string {
	return inspectOf(b);
}
