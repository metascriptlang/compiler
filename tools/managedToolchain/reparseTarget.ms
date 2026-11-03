export const SYMLINK_TAG: uint32 = 0xa000000c;
export const MOUNT_POINT_TAG: uint32 = 0xa0000003;

const HEADER_SIZE: int64 = 8;
const MAXIMUM_BUFFER_SIZE: int64 = 16384;

export struct ReparseTarget {
	tag: uint32;
	flags: uint32;
	nameUtf16Le: uint8[];
}

function u16At(data: Readonly<Span<uint8>>, at: int64): int64 {
	return (data[at] as int64) | ((data[at + 1] as int64) << 8);
}

function u32At(data: Readonly<Span<uint8>>, at: int64): uint32 {
	return (data[at] as uint32) | ((data[at + 1] as uint32) << 8) |
		((data[at + 2] as uint32) << 16) |
		((data[at + 3] as uint32) << 24);
}

export function parseReparseTarget(
	data: Readonly<Span<uint8>>,
): Result<ReparseTarget, string> {
	if (data.length > MAXIMUM_BUFFER_SIZE) {
		return Result.err("reparse buffer exceeds maximum size");
	}
	if (data.length < HEADER_SIZE) {
		return Result.err("reparse data has a truncated header");
	}
	const wholeSize = HEADER_SIZE + u16At(data, 4);
	if (wholeSize > data.length) {
		return Result.err("reparse payload exceeds returned bytes");
	}
	const tag = u32At(data, 0);
	let pathStart: int64 = 16;
	if (tag == SYMLINK_TAG) {
		pathStart = 20;
	} else if (tag != MOUNT_POINT_TAG) {
		return Result.err("unsupported reparse tag: " + String(tag));
	}
	if (pathStart > wholeSize) {
		return Result.err("reparse data has a missing path buffer");
	}
	const nameOffset = u16At(data, 8);
	const nameLength = u16At(data, 10);
	if (nameLength == 0) {
		return Result.err("reparse data has an empty substitute name");
	}
	if ((nameOffset & 1) != 0 || (nameLength & 1) != 0) {
		return Result.err("reparse data has unaligned UTF-16 substitute name");
	}
	const start = pathStart + nameOffset;
	const end = start + nameLength;
	if (start < pathStart || end < start || end > wholeSize) {
		return Result.err("reparse substitute name out of bounds");
	}
	const name: uint8[] = [];
	for (let at = start; at < end; at += 1) { name.push(data[at]); }
	const flags: uint32 = tag == SYMLINK_TAG ? u32At(data, 16) : 0;
	return Result.ok({ tag, flags, nameUtf16Le: name });
}
