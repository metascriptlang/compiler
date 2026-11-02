/** The slice of DER that key files use: definite lengths only, read strictly and written minimally. */

export const tagInteger: int32 = 0x02;
export const tagBitString: int32 = 0x03;
export const tagOctetString: int32 = 0x04;
export const tagNull: int32 = 0x05;
export const tagOid: int32 = 0x06;
export const tagSequence: int32 = 0x30;

export interface DerItem {
	tag: int32;
	body: int32;
	end: int32;
}

export function derItem(buf: Readonly<uint8[]>, at: int32, limit: int32): DerItem | null {
	if (at + 2 > limit) return null;
	const tag = buf[at] as int32;
	let length = buf[at + 1] as int32;
	let body = at + 2;
	if (length >= 0x80) {
		const count = length - 0x80;
		if (count == 0 || count > 3 || body + count > limit) return null;
		length = 0;
		for (let i = 0; i < count; i++) length = length * 256 + (buf[body + i] as int32);
		if (length < 0x80) return null;
		body += count;
	}
	if (body + length > limit) return null;
	return { tag, body, end: body + length };
}

export function derChildren(buf: Readonly<uint8[]>, item: DerItem): DerItem[] | null {
	const out: DerItem[] = [];
	let at = item.body;
	while (at < item.end) {
		const child = derItem(buf, at, item.end);
		if (child == null) return null;
		out.push(child);
		at = child.end;
	}
	return out;
}

export function derRoot(buf: Readonly<uint8[]>, tag: int32): DerItem | null {
	const root = derItem(buf, 0, buf.length as int32);
	if (root == null || root.tag != tag || root.end != buf.length) return null;
	return root;
}

export function derBody(buf: Readonly<uint8[]>, item: DerItem): uint8[] {
	const out: uint8[] = [];
	for (let i = item.body; i < item.end; i++) out.push(buf[i]);
	return out;
}

export function derUnsigned(buf: Readonly<uint8[]>, item: DerItem): uint8[] | null {
	if (item.tag != tagInteger || item.end == item.body) return null;
	if ((buf[item.body] & 0x80) != 0) return null;
	let from = item.body;
	while (from + 1 < item.end && buf[from] == 0) from += 1;
	const out: uint8[] = [];
	for (let i = from; i < item.end; i++) out.push(buf[i]);
	return out;
}

export function derSame(buf: Readonly<uint8[]>, item: DerItem, expected: Readonly<uint8[]>): boolean {
	if (item.end - item.body != expected.length) return false;
	for (let i = 0; i < expected.length; i++) {
		if (buf[item.body + i] != expected[i]) return false;
	}
	return true;
}

export function derTlv(tag: int32, body: Readonly<uint8[]>): uint8[] {
	const out: uint8[] = [tag as uint8];
	const length = body.length as int32;
	if (length < 0x80) {
		out.push(length as uint8);
	} else if (length < 0x100) {
		out.push(0x81);
		out.push(length as uint8);
	} else {
		out.push(0x82);
		out.push((length >> 8) as uint8);
		out.push((length & 0xff) as uint8);
	}
	for (let i = 0; i < length; i++) out.push(body[i]);
	return out;
}

export function derJoin(parts: Readonly<uint8[]>[]): uint8[] {
	const out: uint8[] = [];
	for (const part of parts) {
		for (let i = 0; i < part.length; i++) out.push(part[i]);
	}
	return out;
}

export function derSequence(parts: Readonly<uint8[]>[]): uint8[] {
	return derTlv(tagSequence, derJoin(parts));
}

export function derUnsignedInteger(value: Readonly<uint8[]>): uint8[] {
	let from = 0;
	while (from + 1 < value.length && value[from] == 0) from += 1;
	const body: uint8[] = [];
	if (value.length == 0 || (value[from] & 0x80) != 0) body.push(0);
	for (let i = from; i < value.length; i++) body.push(value[i]);
	return derTlv(tagInteger, body);
}

export function derSmallInteger(value: int32): uint8[] {
	return derUnsignedInteger([value as uint8]);
}

export function derOctets(value: Readonly<uint8[]>): uint8[] {
	return derTlv(tagOctetString, value);
}

export function derBits(value: Readonly<uint8[]>): uint8[] {
	return derTlv(tagBitString, derJoin([[0], value]));
}

export function derOidOf(encoded: Readonly<uint8[]>): uint8[] {
	return derTlv(tagOid, encoded);
}

// A function, not a const: a module const handed to a callee is not spawn-safe, a fresh array per call is.
export function oidRsaEncryption(): uint8[] {
	return [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01];
}
export function oidEcPublicKey(): uint8[] {
	return [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01];
}
export const oidP256: Readonly<uint8[]> = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07];
export const oidP384: Readonly<uint8[]> = [0x2b, 0x81, 0x04, 0x00, 0x22];
