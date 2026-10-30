const HEADER_SIZE: uint64 = 64;
const SEGMENT_SIZE: uint64 = 56;
const EXTENDED_COUNT: uint64 = 0xffff;
const CLASS_64: uint8 = 2;
const LITTLE_ENDIAN: uint8 = 1;
const CURRENT_VERSION: uint64 = 1;

export struct ElfSegment {
	kind: uint32;
	offset: uint64;
	virtualAddress: uint64;
	fileSize: uint64;
}

export struct ElfProgramTable {
	kind: uint16;
	machine: uint16;
	osAbi: uint8;
	segments: ElfSegment[];
}

function readUnsigned(
	data: Readonly<Span<uint8>>,
	at: int64,
	width: int32,
): uint64 {
	let value: uint64 = 0;
	for (let i: int32 = width - 1; i >= 0; i -= 1) {
		value = (value << (8 as uint64)) | (data[at + i] as uint64);
	}
	return value;
}

function checkHeader(data: Readonly<Span<uint8>>): Result<void, string> {
	if ((data.length as uint64) < HEADER_SIZE) {
		return Result.err(
			"ELF header is truncated: " + String(data.length) + " bytes",
		);
	}
	if (data[0] != 0x7f || data[1] != 0x45 ||
		data[2] != 0x4c || data[3] != 0x46) {
		return Result.err("not an ELF file: bad magic");
	}
	if (data[4] != CLASS_64) {
		return Result.err("not ELFCLASS64: class " + String(data[4]));
	}
	if (data[5] != LITTLE_ENDIAN) {
		return Result.err("not little endian: data encoding " + String(data[5]));
	}
	if ((data[6] as uint64) != CURRENT_VERSION) {
		return Result.err("unsupported ELF ident version " + String(data[6]));
	}
	const version = readUnsigned(data, 20, 4);
	if (version != CURRENT_VERSION) {
		return Result.err("unsupported ELF version " + String(version));
	}
	const headerSize = readUnsigned(data, 52, 2);
	if (headerSize != HEADER_SIZE) {
		return Result.err("invalid ELF header size " + String(headerSize));
	}
	return Result.ok(null);
}

export function parseElfProgramTable(
	data: Readonly<Span<uint8>>,
): Result<ElfProgramTable, string> {
	const header = checkHeader(data);
	if (!header.ok) { return Result.err(header.error); }
	const count = readUnsigned(data, 56, 2);
	if (count == 0) { return Result.err("ELF has no program headers"); }
	if (count == EXTENDED_COUNT) {
		return Result.err("extended program header count is not supported");
	}
	const entrySize = readUnsigned(data, 54, 2);
	if (entrySize != SEGMENT_SIZE) {
		return Result.err(
			"invalid program header entry size " + String(entrySize),
		);
	}
	const start = readUnsigned(data, 32, 8);
	if (start < HEADER_SIZE) {
		return Result.err(
			"program header table offset " + String(start) +
			" is inside the ELF header",
		);
	}
	const size = data.length as uint64;
	if (start > size || count * SEGMENT_SIZE > size - start) {
		return Result.err(
			"program header table of " + String(count) + " entries at offset " +
			String(start) + " runs past the end of the " + String(size) +
			"-byte input",
		);
	}
	const segments: ElfSegment[] = [];
	let at = start as int64;
	for (let i: int32 = 0; i < (count as int32); i += 1) {
		segments.push({
			kind: readUnsigned(data, at, 4) as uint32,
			offset: readUnsigned(data, at + 8, 8),
			virtualAddress: readUnsigned(data, at + 16, 8),
			fileSize: readUnsigned(data, at + 32, 8),
		});
		at += SEGMENT_SIZE as int64;
	}
	return Result.ok({
		kind: readUnsigned(data, 16, 2) as uint16,
		machine: readUnsigned(data, 18, 2) as uint16,
		osAbi: data[7],
		segments: segments,
	});
}
