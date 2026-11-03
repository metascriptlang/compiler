import {
	MOUNT_POINT_TAG,
	parseReparseTarget,
	SYMLINK_TAG,
} from "./reparseTarget";

let cases: int32 = 0;

function put16(data: Buffer, at: int32, value: int32): void {
	data[at] = (value & 255) as uint8;
	data[at + 1] = ((value >> 8) & 255) as uint8;
}

function put32(data: Buffer, at: int32, value: uint32): void {
	for (let i: int32 = 0; i < 4; i += 1) {
		data[at + i] = ((value >> ((i * 8) as uint32)) & 255) as uint8;
	}
}

function recordOf(tag: uint32, flags: uint32, name: uint8[]): Buffer {
	const start: int32 = tag == SYMLINK_TAG ? 20 : 16;
	const data = Buffer.alloc(start + name.length);
	put32(data, 0, tag);
	put16(data, 4, data.length - 8);
	put16(data, 10, name.length);
	if (tag == SYMLINK_TAG) { put32(data, 16, flags); }
	for (let i: int32 = 0; i < name.length; i += 1) {
		data[start + i] = name[i];
	}
	return data;
}

function expectTarget(
	data: Readonly<Span<uint8>>,
	tag: uint32,
	flags: uint32,
	name: uint8[],
): void {
	const parsed = parseReparseTarget(data);
	if (!parsed.ok) { throw new Error(parsed.error); }
	const found = parsed.value;
	if (found.tag != tag || found.flags != flags ||
		found.nameUtf16Le.length != name.length) {
		throw new Error("reparse metadata differs");
	}
	for (let i: int32 = 0; i < name.length; i += 1) {
		if (found.nameUtf16Le[i] != name[i]) {
			throw new Error("stored target bytes differ");
		}
	}
	cases += 1;
}

function expectRefusal(data: Buffer, fragment: string): void {
	const result = parseReparseTarget(data);
	if (result.ok || result.error.indexOf(fragment) < 0) {
		throw new Error("expected reparse refusal: " + fragment);
	}
	cases += 1;
}

function run(): void {
	const name: uint8[] = [108, 0, 105, 0, 98, 0];
	const flagValues: uint32[] = [0, 1, 3, 4294967295];
	for (const flags of flagValues) {
		expectTarget(recordOf(SYMLINK_TAG, flags, name), SYMLINK_TAG, flags, name);
	}
	expectTarget(recordOf(MOUNT_POINT_TAG, 0, name), MOUNT_POINT_TAG, 0, name);
	for (const units of [
		[233, 0, 45, 78], [61, 216, 128, 222], [0, 0], [0, 216],
	]) {
		const raw: uint8[] = [];
		for (const unit of units) { raw.push(unit as uint8); }
		expectTarget(recordOf(SYMLINK_TAG, 1, raw), SYMLINK_TAG, 1, raw);
	}
	const offset = recordOf(SYMLINK_TAG, 1, [120, 0, 108, 0, 105, 0, 98, 0]);
	put16(offset, 8, 2);
	put16(offset, 10, 6);
	expectTarget(offset, SYMLINK_TAG, 1, name);
	const trailing = recordOf(MOUNT_POINT_TAG, 0, name);
	trailing.push(255);
	trailing.push(255);
	expectTarget(trailing, MOUNT_POINT_TAG, 0, name);
	const surrounded: uint8[] = [255, 255];
	const inner = recordOf(SYMLINK_TAG, 1, name);
	for (const byte of inner) { surrounded.push(byte); }
	surrounded.push(255);
	expectTarget(surrounded[2..(2 + inner.length)], SYMLINK_TAG, 1, name);
	const original = recordOf(SYMLINK_TAG, 1, name);
	const copied = parseReparseTarget(original);
	if (!copied.ok) { throw new Error(copied.error); }
	original[20] = 0;
	if (copied.value.nameUtf16Le[0] != 108) {
		throw new Error("target aliases the input buffer");
	}
	cases += 1;
	for (let size: int32 = 0; size < 8; size += 1) {
		expectRefusal(Buffer.alloc(size), "truncated header");
	}
	expectRefusal(Buffer.alloc(16385), "exceeds maximum");
	const oversized = recordOf(SYMLINK_TAG, 1, name);
	put16(oversized, 4, 65535);
	expectRefusal(oversized, "payload exceeds returned bytes");
	const unknown = recordOf(MOUNT_POINT_TAG, 0, name);
	put32(unknown, 0, 42);
	expectRefusal(unknown, "unsupported reparse tag");
	for (const tag of [SYMLINK_TAG, MOUNT_POINT_TAG]) {
		const short = recordOf(tag, 0, name);
		put16(short, 4, tag == SYMLINK_TAG ? 11 : 7);
		expectRefusal(short, "missing path buffer");
		expectRefusal(recordOf(tag, 0, []), "empty substitute name");
		const oddOffset = recordOf(tag, 0, name);
		put16(oddOffset, 8, 1);
		expectRefusal(oddOffset, "unaligned UTF-16");
		const oddLength = recordOf(tag, 0, name);
		put16(oddLength, 10, 5);
		expectRefusal(oddLength, "unaligned UTF-16");
		const beyond = recordOf(tag, 0, name);
		put16(beyond, 8, 65534);
		expectRefusal(beyond, "substitute name out of bounds");
		const truncated = recordOf(tag, 0, name);
		put16(truncated, 10, 8);
		expectRefusal(truncated, "substitute name out of bounds");
	}
	console.log("reparse targets: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
