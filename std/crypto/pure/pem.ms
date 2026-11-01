import { Buffer } from "std/core/buffer";

/** One PEM block: its label (`PRIVATE KEY`, `RSA PUBLIC KEY`, ...) and the DER inside. */
export interface PemBlock {
	label: string;
	der: Buffer;
}

/** The first block of `text`, or null when there is none, it is not closed or its body is not canonical base64. */
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

/** The block in the canonical form `mbedtls` writes: 64-column lines and a final newline. */
export function pemEncode(label: string, der: Readonly<uint8[]>): string {
	const body = (der as Buffer).encodeBase64();
	const lines: string[] = [`-----BEGIN ${label}-----`];
	for (let at = 0; at < body.length; at += 64) lines.push(body.slice(at, at + 64));
	lines.push(`-----END ${label}-----`);
	return lines.join("\n") + "\n";
}
