/** The DER element reader X.509 parsing walks: one identifier byte, a definite length, the content's range. */

export const derTagBoolean: int32 = 1;
export const derTagInteger: int32 = 2;
export const derTagBitString: int32 = 3;
export const derTagOctetString: int32 = 4;
export const derTagNull: int32 = 5;
export const derTagObjectIdentifier: int32 = 6;
export const derTagSequence: int32 = 16;
export const derTagSet: int32 = 17;
export const derTagUtcTime: int32 = 23;
export const derTagGeneralizedTime: int32 = 24;

export const derClassUniversal: int32 = 0;
export const derClassContextSpecific: int32 = 2;

/** One element: `identifier` is the whole identifier byte, `start` and `end` bound its content. */
export struct DerElement {
	identifier: int32;
	start: int32;
	end: int32;
}

export function tagNumber(this element: DerElement): int32 {
	return element.identifier & 0x1f;
}

export function tagClass(this element: DerElement): int32 {
	return element.identifier >> 6;
}

export function constructed(this element: DerElement): boolean {
	return (element.identifier & 0x20) != 0;
}

export function contentSize(this element: DerElement): int32 {
	return element.end - element.start;
}

/**
 * The element whose identifier is at `index`, or null when its header or content runs past `limit`,
 * its length is indefinite or wider than four bytes, or its tag needs the multi-byte form.
 */
export function derElementAt(
	bytes: Readonly<uint8[]>,
	index: int32,
	limit: int32,
): DerElement | null {
	if (index < 0 || limit > bytes.length || index + 2 > limit) return null;
	const identifier = bytes[index] as int32;
	if ((identifier & 0x1f) == 0x1f) return null;
	const sizeByte = bytes[index + 1] as int32;
	let at = index + 2;
	if ((sizeByte >> 7) == 0) {
		if (sizeByte > limit - at) return null;
		return { identifier, start: at, end: at + sizeByte };
	}
	const lengthSize = sizeByte & 0x7f;
	if (lengthSize == 0 || lengthSize > 4 || at + lengthSize > limit) return null;
	let length: int64 = 0;
	for (let i = 0; i < lengthSize; i++) {
		length = (length << 8) | (bytes[at + i] as int64);
	}
	at += lengthSize;
	const room = (limit - at) as int64;
	if (length > room) return null;
	return { identifier, start: at, end: at + (length as int32) };
}

test "a short-form element reports its identifier and content range" {
	const bytes: uint8[] = [0x30, 0x03, 0x02, 0x01, 0x05];
	const outer = derElementAt(bytes, 0, 5);
	assert outer != null;
	const element = outer as DerElement;
	assert element.tagNumber() == derTagSequence && element.constructed();
	assert element.start == 2 && element.end == 5;
	const inner = derElementAt(bytes, element.start, element.end) as DerElement;
	assert inner.tagNumber() == derTagInteger && inner.contentSize() == 1 && bytes[inner.start] == 5;
}

test "a long-form length is read big-endian" {
	const bytes: uint8[] = new Array<uint8>(4 + 300);
	bytes[0] = 0x04;
	bytes[1] = 0x82;
	bytes[2] = 0x01;
	bytes[3] = 0x2c;
	const element = derElementAt(bytes, 0, bytes.length as int32) as DerElement;
	assert element.start == 4 && element.end == 304;
}

test "a header or content past the limit, an indefinite length and a wide length are refused" {
	assert derElementAt([0x30], 0, 1) == null;
	assert derElementAt([0x30, 0x05, 0x00], 0, 3) == null;
	assert derElementAt([0x30, 0x80, 0x00, 0x00], 0, 4) == null;
	assert derElementAt([0x04, 0x85, 0, 0, 0, 0, 1, 0], 0, 8) == null;
	assert derElementAt([0x04, 0x82, 0x01], 0, 3) == null;
	assert derElementAt([0x1f, 0x01, 0x00], 0, 3) == null;
	assert derElementAt([0x30, 0x02, 0x05, 0x00], 0, 3) == null;
}
