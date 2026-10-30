import {
	ElfSegment, parseElfProgramTable,
} from "./elfProgramTable";

const X64: uint16 = 62;
const AARCH64: uint16 = 183;
const ET_EXEC: uint16 = 2;
const ET_DYN: uint16 = 3;
const PT_LOAD: uint32 = 1;
const PT_DYNAMIC: uint32 = 2;
const PT_INTERP: uint32 = 3;
const PT_NOTE: uint32 = 4;
const MAX64: uint64 = 0xffffffffffffffff;
const HIGH_BIT: uint64 = 0x8000000000000000;
const PATTERN_A: uint64 = 0x0123456789abcdef;
const PATTERN_B: uint64 = 0xfedcba9876543210;
const MAX_INT64: uint64 = 0x7fffffffffffffff;
const ABOVE_UINT32: uint64 = 0x100000000;
const UNREAD: uint64 = 0x1122334455667788;
const BASE_SIZE: int32 = 120;

let cases: int32 = 0;

function put(bytes: Buffer, at: int32, width: int32, value: uint64): void {
	for (let i: int32 = 0; i < width; i += 1) {
		bytes[at + i] = ((value >> ((i * 8) as uint64)) & 255) as uint8;
	}
}

function seg(
	kind: uint32,
	offset: uint64,
	virtualAddress: uint64,
	fileSize: uint64,
): ElfSegment {
	return { kind, offset, virtualAddress, fileSize };
}

function image(
	kind: uint16,
	machine: uint16,
	osAbi: uint8,
	segments: ElfSegment[],
): Buffer {
	const bytes = Buffer.alloc(64 + 56 * segments.length);
	put(bytes, 0, 4, 0x464c457f);
	bytes[4] = 2;
	bytes[5] = 1;
	bytes[6] = 1;
	bytes[7] = osAbi;
	put(bytes, 16, 2, kind as uint64);
	put(bytes, 18, 2, machine as uint64);
	put(bytes, 20, 4, 1);
	put(bytes, 32, 8, 64);
	put(bytes, 52, 2, 64);
	put(bytes, 54, 2, 56);
	put(bytes, 56, 2, segments.length as uint64);
	for (let i: int32 = 0; i < segments.length; i += 1) {
		const at = 64 + 56 * i;
		put(bytes, at, 4, segments[i].kind as uint64);
		put(bytes, at + 4, 4, 5);
		put(bytes, at + 8, 8, segments[i].offset);
		put(bytes, at + 16, 8, segments[i].virtualAddress);
		put(bytes, at + 24, 8, UNREAD);
		put(bytes, at + 32, 8, segments[i].fileSize);
		put(bytes, at + 40, 8, 0x99);
		put(bytes, at + 48, 8, 0x1000);
	}
	return bytes;
}

function base(): Buffer {
	return image(ET_EXEC, X64, 0, [seg(PT_LOAD, 0, 0x400000, 0x1000)]);
}

function patched(
	data: Buffer,
	at: int32,
	width: int32,
	value: uint64,
): Buffer {
	const copy = Buffer.copy(data);
	put(copy, at, width, value);
	return copy;
}

function expectTable(
	what: string,
	data: Readonly<Span<uint8>>,
	kind: uint16,
	machine: uint16,
	osAbi: uint8,
	expected: ElfSegment[],
): void {
	const parsed = parseElfProgramTable(data);
	if (!parsed.ok) { throw new Error(what + " refused: " + parsed.error); }
	const table = parsed.value;
	if (table.kind != kind || table.machine != machine ||
		table.osAbi != osAbi) {
		throw new Error(what + " header identity changed");
	}
	if (table.segments.length != expected.length) {
		throw new Error(what + " segment count changed");
	}
	for (let i: int32 = 0; i < expected.length; i += 1) {
		const actual = table.segments[i];
		if (actual.kind != expected[i].kind ||
			actual.offset != expected[i].offset ||
			actual.virtualAddress != expected[i].virtualAddress ||
			actual.fileSize != expected[i].fileSize) {
			throw new Error(what + " segment " + String(i) + " changed");
		}
	}
	cases += 1;
}

function expectSegments(
	what: string,
	data: Buffer,
	expected: ElfSegment[],
): void {
	expectTable(what, data, ET_EXEC, X64, 0, expected);
}

function expectRefusal(
	what: string,
	data: Readonly<Span<uint8>>,
	fragment: string,
): void {
	const parsed = parseElfProgramTable(data);
	if (parsed.ok) { throw new Error("accepted " + what); }
	if (parsed.error.indexOf(fragment) < 0) {
		throw new Error(what + " refused differently: " + parsed.error);
	}
	cases += 1;
}

function checkMachinesTypesAndAbis(): void {
	const loadAndInterp = [
		seg(PT_LOAD, 0, 0x400000, 0x1000),
		seg(PT_INTERP, 0x238, 0x400238, 0x1c),
		seg(PT_DYNAMIC, 0x2000, 0x402000, 0x1d0),
	];
	expectTable(
		"x86_64 executable",
		image(ET_EXEC, X64, 0, loadAndInterp),
		ET_EXEC, X64, 0, loadAndInterp,
	);
	expectTable(
		"aarch64 shared object",
		image(ET_DYN, AARCH64, 0, loadAndInterp),
		ET_DYN, AARCH64, 0, loadAndInterp,
	);
	expectTable(
		"FreeBSD OS/ABI",
		image(ET_DYN, X64, 9, loadAndInterp),
		ET_DYN, X64, 9, loadAndInterp,
	);
	expectTable(
		"GNU OS/ABI on aarch64",
		image(ET_EXEC, AARCH64, 3, loadAndInterp),
		ET_EXEC, AARCH64, 3, loadAndInterp,
	);
	expectTable(
		"unlisted machine, core file, OS/ABI 255",
		image(4, 8, 255, loadAndInterp),
		4, 8, 255, loadAndInterp,
	);
	expectTable(
		"unlisted type and machine at their widest",
		image(0xffff, 0xffff, 0, loadAndInterp),
		0xffff, 0xffff, 0, loadAndInterp,
	);
	expectTable(
		"relocatable none machine",
		image(1, 0, 0, loadAndInterp),
		1, 0, 0, loadAndInterp,
	);
}

function checkSegmentOrderAndKinds(): void {
	expectSegments("segments stay in table order", image(
		ET_EXEC, X64, 0,
		[seg(PT_NOTE, 3, 2, 1), seg(PT_LOAD, 9, 8, 7), seg(PT_INTERP, 6, 5, 4)],
	), [seg(PT_NOTE, 3, 2, 1), seg(PT_LOAD, 9, 8, 7), seg(PT_INTERP, 6, 5, 4)]);
	const duplicates = [
		seg(PT_LOAD, 0x10, 0x20, 0x30),
		seg(PT_LOAD, 0x10, 0x20, 0x30),
		seg(PT_NOTE, 0x10, 0x20, 0x30),
		seg(PT_LOAD, 0x10, 0x20, 0x30),
	];
	expectSegments(
		"duplicate segments are kept",
		image(ET_EXEC, X64, 0, duplicates),
		duplicates,
	);
	const unknown = [
		seg(0, 1, 2, 3),
		seg(0x6474e551, 4, 5, 6),
		seg(0x70000000, 7, 8, 9),
		seg(0x7fffffff, 10, 11, 12),
		seg(0xffffffff, 13, 14, 15),
	];
	expectSegments(
		"unknown segment kinds are recorded",
		image(ET_EXEC, X64, 0, unknown),
		unknown,
	);
	const empty = [seg(0, 0, 0, 0)];
	expectSegments(
		"all-zero segment",
		image(ET_EXEC, X64, 0, empty),
		empty,
	);
}

function checkUint64FieldsStayExact(): void {
	const wide = [
		seg(PT_LOAD, HIGH_BIT, MAX64, MAX64),
		seg(PT_LOAD, PATTERN_A, PATTERN_B, HIGH_BIT + 1),
		seg(0xffffffff, MAX64, 0, HIGH_BIT),
		seg(PT_NOTE, MAX_INT64, HIGH_BIT - 1, ABOVE_UINT32),
	];
	expectSegments(
		"high-bit and maximal uint64 fields",
		image(ET_EXEC, X64, 0, wide),
		wide,
	);
	const outside = [seg(PT_NOTE, 0x10000000, 0, 0x7fffffff)];
	expectSegments(
		"segment bytes beyond the input are metadata only",
		image(ET_EXEC, X64, 0, outside),
		outside,
	);
	const wrapping = [seg(PT_NOTE, MAX64, 0, MAX64)];
	expectSegments(
		"segment offset plus size wrapping is metadata only",
		image(ET_EXEC, X64, 0, wrapping),
		wrapping,
	);
	const data = base();
	put(data, 64 + 4, 4, 0xffffffff);
	for (const at of [64 + 24, 64 + 40, 64 + 48]) {
		put(data, at, 8, MAX64);
	}
	expectSegments(
		"flags, physical address, memory size and alignment are not read",
		data,
		[seg(PT_LOAD, 0, 0x400000, 0x1000)],
	);
}

function checkTableLocation(): void {
	const two = image(ET_EXEC, X64, 0, [
		seg(PT_LOAD, 1, 2, 3),
		seg(PT_NOTE, 4, 5, 6),
	]);
	const atEnd = patched(patched(two, 32, 8, 120), 56, 2, 1);
	expectSegments("table ending exactly at the input end", atEnd, [
		seg(PT_NOTE, 4, 5, 6),
	]);
	expectSegments(
		"bytes after the table are ignored",
		Buffer.concat(base(), Buffer.alloc(40)),
		[seg(PT_LOAD, 0, 0x400000, 0x1000)],
	);
	const trailing = Buffer.concat(two, Buffer.alloc(40));
	expectSegments(
		"table past the first slot with bytes after it",
		patched(patched(trailing, 32, 8, 120), 56, 2, 1),
		[seg(PT_NOTE, 4, 5, 6)],
	);
	const wide: ElfSegment[] = [];
	for (let i: int32 = 0; i < 65534; i += 1) {
		wide.push(seg(i as uint32, (i as uint64) * 3, i as uint64, 7));
	}
	expectSegments(
		"largest non-extended count",
		image(ET_EXEC, X64, 0, wide),
		wide,
	);
}

function checkSpanContracts(): void {
	const data = base();
	const expected = [seg(PT_LOAD, 0, 0x400000, 0x1000)];
	expectTable("exact span", data[0..BASE_SIZE], ET_EXEC, X64, 0, expected);
	const framed = Buffer.concat(
		Buffer.concat(Buffer.alloc(16), data),
		Buffer.alloc(9),
	);
	expectTable(
		"span inside a larger buffer",
		framed[16..16 + BASE_SIZE],
		ET_EXEC, X64, 0, expected,
	);
	expectRefusal(
		"span one byte short of the table",
		framed[16..16 + BASE_SIZE - 1],
		"runs past the end",
	);
	expectRefusal(
		"span that starts before the header",
		framed[0..BASE_SIZE],
		"bad magic",
	);
	const longer = Buffer.concat(data, Buffer.alloc(8));
	expectTable(
		"span shorter than its buffer",
		longer[0..BASE_SIZE],
		ET_EXEC, X64, 0, expected,
	);
}

function checkOwnership(): void {
	const data = base();
	const snapshot = Buffer.copy(data);
	const first = parseElfProgramTable(data);
	const second = parseElfProgramTable(data);
	if (!first.ok || !second.ok) { throw new Error("base image refused"); }
	if (Buffer.compare(data, snapshot) != 0) {
		throw new Error("parsing changed the input");
	}
	cases += 1;
	put(data, 64 + 8, 8, MAX64);
	put(data, 16, 2, 0xffff);
	put(data, 7, 1, 77);
	if (first.value.segments[0].offset != 0 || first.value.kind != ET_EXEC ||
		first.value.osAbi != 0) {
		throw new Error("result still follows the input bytes");
	}
	cases += 1;
	first.value.segments.push(seg(PT_NOTE, 1, 1, 1));
	if (second.value.segments.length != 1) {
		throw new Error("two results share one segment array");
	}
	cases += 1;
}

function checkIdentityRefusals(): void {
	const data = base();
	expectRefusal("empty input", Buffer.alloc(0), "truncated");
	expectRefusal("63-byte input", data[0..63], "truncated");
	for (let at: int32 = 0; at < 4; at += 1) {
		expectRefusal(
			"bad magic byte " + String(at),
			patched(data, at, 1, 0x7e),
			"bad magic",
		);
	}
	expectRefusal("ELFCLASS32", patched(data, 4, 1, 1), "ELFCLASS64");
	expectRefusal("ELFCLASSNONE", patched(data, 4, 1, 0), "ELFCLASS64");
	expectRefusal("unknown class", patched(data, 4, 1, 3), "ELFCLASS64");
	expectRefusal("big endian", patched(data, 5, 1, 2), "little endian");
	expectRefusal("no data encoding", patched(data, 5, 1, 0), "little endian");
	expectRefusal("ident version 0", patched(data, 6, 1, 0), "ident version");
	expectRefusal("ident version 2", patched(data, 6, 1, 2), "ident version");
	expectRefusal("e_version 0", patched(data, 20, 4, 0), "ELF version");
	expectRefusal("e_version 2", patched(data, 20, 4, 2), "ELF version");
	expectRefusal(
		"e_version high byte",
		patched(data, 20, 4, 0x01000000),
		"ELF version",
	);
	expectRefusal("header size 0", patched(data, 52, 2, 0), "header size");
	expectRefusal("ELF32 header size", patched(data, 52, 2, 52), "header size");
	expectRefusal("header size 65", patched(data, 52, 2, 65), "header size");
}

function checkTruncationSweeps(): void {
	const data = base();
	for (let length: int32 = 0; length < 64; length += 1) {
		if (parseElfProgramTable(data[0..length]).ok) {
			throw new Error("accepted a header prefix of " + String(length));
		}
	}
	cases += 1;
	for (let length: int32 = 64; length < BASE_SIZE; length += 1) {
		if (parseElfProgramTable(data[0..length]).ok) {
			throw new Error("accepted a table prefix of " + String(length));
		}
	}
	cases += 1;
}

function checkCountAndEntrySizeRefusals(): void {
	const data = base();
	expectRefusal("no program headers", patched(data, 56, 2, 0), "no program");
	expectRefusal(
		"extended program header count",
		patched(data, 56, 2, 0xffff),
		"extended program header count",
	);
	for (const size of [0, 1, 32, 55, 57, 64, 0xffff]) {
		expectRefusal(
			"entry size " + String(size),
			patched(data, 54, 2, size as uint64),
			"entry size",
		);
	}
	expectRefusal(
		"two entries in a one-entry file",
		patched(data, 56, 2, 2),
		"runs past the end",
	);
	expectRefusal(
		"65534 entries in a one-entry file",
		patched(data, 56, 2, 65534),
		"runs past the end",
	);
}

function checkTableOffsetRefusals(): void {
	const data = base();
	const size = BASE_SIZE as uint64;
	for (const offset of [0, 8, 32, 52, 56, 63]) {
		expectRefusal(
			"table offset " + String(offset),
			patched(data, 32, 8, offset as uint64),
			"inside the ELF header",
		);
	}
	const beyond: uint64[] = [
		size - 55, size, size + 1, 0x100000040, HIGH_BIT - 1, HIGH_BIT,
		HIGH_BIT + 64, MAX64 - 55, MAX64 - 63, MAX64,
	];
	for (const offset of beyond) {
		expectRefusal(
			"table offset " + String(offset),
			patched(data, 32, 8, offset),
			"runs past the end",
		);
	}
}

function run(): void {
	checkMachinesTypesAndAbis();
	checkSegmentOrderAndKinds();
	checkUint64FieldsStayExact();
	checkTableLocation();
	checkSpanContracts();
	checkOwnership();
	checkIdentityRefusals();
	checkTruncationSweeps();
	checkCountAndEntrySizeRefusals();
	checkTableOffsetRefusals();
	console.log("ELF program tables: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
