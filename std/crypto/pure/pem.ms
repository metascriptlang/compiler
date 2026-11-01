import { Buffer } from "std/core/buffer";

export interface PemBlock {
	label: string;
	der: Buffer;
}

export function pemDecode(text: string): PemBlock | null {
	const begin = text.indexOf("-----BEGIN ");
	if (begin < 0) return null;
	const labelStart = begin + 11;
	const labelEnd = text.indexOf("-----", labelStart);
	if (labelEnd < 0) return null;
	const label = text.slice(labelStart, labelEnd);
	const bodyStart = labelEnd + 5;
	const footer = `-----END ${label}-----`;
	const bodyEnd = text.indexOf(footer, bodyStart);
	if (bodyEnd < 0) return null;
	const body = text.slice(bodyStart, bodyEnd).replace(/[ \t\r\n]/g, "");
	if (body.length == 0) return null;
	const der = body.decodeBase64();
	if (der.length == 0) return null;
	return { label, der: der as Buffer };
}

export function pemEncode(label: string, der: Readonly<uint8[]>): string {
	const body = (der as Buffer).encodeBase64();
	const lines: string[] = [`-----BEGIN ${label}-----`];
	for (let at = 0; at < body.length; at += 64) lines.push(body.slice(at, at + 64));
	lines.push(`-----END ${label}-----`);
	return lines.join("\n") + "\n";
}
