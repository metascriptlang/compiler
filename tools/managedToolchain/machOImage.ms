import { wellFormedString } from "std/core/string/bytes";
import { wellFormedPrefix } from "std/core/string/utf8Repair";

export struct MachOBuildVersion {
	platform: uint32;
	minimumVersion: uint32;
}

export struct MachOSection {
	segment: string;
	name: string;
}

export struct MachOInfo {
	cpuType: uint32;
	fileType: uint32;
	commands: uint32[];
	dylibs: string[];
	build: MachOBuildVersion | null;
	sections: MachOSection[];
	installName: string | null;
	dylinker: string | null;
}

const MAGIC: uint32 = 0xfeedfacf;
const ID_DYLIB: uint32 = 0xd;
const LOAD_DYLINKER: uint32 = 0xe;
const BUILD_VERSION: uint32 = 0x32;
const SEGMENT_64: uint32 = 0x19;
const NAMED_COMMANDS: uint32[] = [
	0xc, ID_DYLIB, LOAD_DYLINKER, 0x20, 0x80000018, 0x8000001f, 0x80000023,
];

function read32(data: Readonly<Span<uint8>>, at: int64): uint32 {
	let value: uint32 = 0;
	for (let i: int32 = 3; i >= 0; i -= 1) {
		value = (value << 8) | (data[at + i] as uint32);
	}
	return value;
}

function libraryName(
	data: Readonly<Span<uint8>>, cursor: int64, size: int64, minimum: int64,
): Result<string, string> {
	if (size < minimum) { return Result.err("short library name command"); }
	const offset = read32(data, cursor + 8) as int64;
	if (offset < minimum || offset >= size) {
		return Result.err("library name offset extends outside its command");
	}
	const start = cursor + offset;
	let stop = start;
	while (stop < cursor + size && data[stop] != 0) { stop += 1; }
	if (stop == cursor + size) {
		return Result.err("library name has no NUL inside its command");
	}
	const text = data[start..stop];
	if (wellFormedPrefix(text, 0, false) != text.length) {
		return Result.err("library name is not UTF-8");
	}
	return Result.ok(wellFormedString(text));
}

function sectionName(
	data: Readonly<Span<uint8>>, start: int64,
): Result<string, string> {
	let stop = start;
	while (stop < start + 16 && data[stop] != 0) {
		if (data[stop] >= 0x80) { return Result.err("section name is not ASCII"); }
		stop += 1;
	}
	return Result.ok(data[start..stop].asString());
}

export function parseMachO(
	data: Readonly<Span<uint8>>,
): Result<MachOInfo, string> {
	if (data.length < 32 || read32(data, 0) != MAGIC) {
		return Result.err("not a little-endian 64-bit Mach-O file");
	}
	const cpuType = read32(data, 4);
	const fileType = read32(data, 12);
	const count = read32(data, 16) as int64;
	const commandBytes = read32(data, 20) as int64;
	if (commandBytes > data.length - 32 || count > commandBytes / 8) {
		return Result.err("Mach-O command table extends past its bounds");
	}
	const end = 32 + commandBytes;
	const commands: uint32[] = [];
	const dylibs: string[] = [];
	const sections: MachOSection[] = [];
	let build: MachOBuildVersion | null = null;
	let installName: string | null = null;
	let dylinker: string | null = null;
	let cursor: int64 = 32;
	for (let i: int64 = 0; i < count; i += 1) {
		const context = "Mach-O command " + String(i) + ": ";
		if (end - cursor < 8) {
			return Result.err(context + "truncated load command");
		}
		const kind = read32(data, cursor);
		const size = read32(data, cursor + 4) as int64;
		if (size < 8 || size % 8 != 0 || size > end - cursor) {
			return Result.err(context + "invalid command size " + String(size));
		}
		commands.push(kind);
		if (NAMED_COMMANDS.indexOf(kind) >= 0) {
			const minimum: int64 = kind == LOAD_DYLINKER ? 12 : 24;
			const name = libraryName(data, cursor, size, minimum);
			if (!name.ok) { return Result.err(context + name.error); }
			if (kind == ID_DYLIB) {
				if (installName != null) {
					return Result.err(context + "duplicate LC_ID_DYLIB");
				}
				installName = name.value;
			} else if (kind == LOAD_DYLINKER) {
				if (dylinker != null) {
					return Result.err(context + "duplicate LC_LOAD_DYLINKER");
				}
				dylinker = name.value;
			} else {
				dylibs.push(name.value);
			}
		} else if (kind == BUILD_VERSION) {
			if (size < 24 || build != null) {
				return Result.err(context + "short or duplicate build version");
			}
			const tools = read32(data, cursor + 20) as int64;
			if (24 + 8 * tools != size) {
				return Result.err(context + "build tools do not fit their command");
			}
			build = {
				platform: read32(data, cursor + 8),
				minimumVersion: read32(data, cursor + 12),
			};
		} else if (kind == SEGMENT_64) {
			if (size < 72) { return Result.err(context + "short segment command"); }
			const sectionCount = read32(data, cursor + 64) as int64;
			if (sectionCount > (size - 72) / 80) {
				return Result.err(context + "section table exceeds segment command");
			}
			for (let index: int64 = 0; index < sectionCount; index += 1) {
				const at = cursor + 72 + index * 80;
				const segment = sectionName(data, at + 16);
				if (!segment.ok) { return Result.err(context + segment.error); }
				const name = sectionName(data, at);
				if (!name.ok) { return Result.err(context + name.error); }
				sections.push({ segment: segment.value, name: name.value });
			}
		}
		cursor += size;
	}
	if (cursor != end) {
		return Result.err("Mach-O load commands do not cover sizeofcmds");
	}
	return Result.ok({
		cpuType, fileType, commands, dylibs, build, sections, installName, dylinker,
	});
}
