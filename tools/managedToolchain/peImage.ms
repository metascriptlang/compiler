export enum PeSymbolKind {
	Name,
	Ordinal,
}

export struct PeSymbol {
	kind: PeSymbolKind;
	name: string;
	ordinal: uint16;
}

export struct PeImport {
	dll: string;
	symbols: PeSymbol[];
}

export struct PeInfo {
	machine: uint16;
	subsystem: uint16;
	characteristics: uint16;
	imports: PeImport[];
	exports: string[];
}

struct Section {
	virtualSize: int64;
	virtualAddress: int64;
	rawSize: int64;
	rawPointer: int64;
}

// File offsets [at, end) with one continuous RVA-to-file mapping.
struct Backed {
	at: int64;
	end: int64;
}

struct Directory {
	rva: int64;
	size: int64;
}

const DOS_NEW_HEADER_AT: int64 = 0x3c;
const PE_SIGNATURE: uint32 = 0x4550;
const PE_SIGNATURE_BYTES: int64 = 4;
const COFF_HEADER_BYTES: int64 = 20;
const PE32_MAGIC: uint16 = 0x10b;
const PE32_PLUS_MAGIC: uint16 = 0x20b;
const OPTIONAL_FIXED_BYTES: int64 = 112;
const OPTIONAL_SUBSYSTEM_AT: int64 = 68;
const OPTIONAL_DIRECTORY_COUNT_AT: int64 = 108;
const DIRECTORY_ENTRY_BYTES: int64 = 8;
const EXPORT_DIRECTORY_INDEX: int64 = 0;
const IMPORT_DIRECTORY_INDEX: int64 = 1;
const SECTION_HEADER_BYTES: int64 = 40;
const EXPORT_TABLE_BYTES: int64 = 40;
const IMPORT_DESCRIPTOR_BYTES: int64 = 20;
const THUNK_BYTES: int64 = 8;
const NAME_POINTER_BYTES: int64 = 4;
const HINT_BYTES: int64 = 2;
const ASCII_LIMIT: uint8 = 0x80;

const BYTE_1: uint32 = 256;
const BYTE_2: uint32 = 65536;
const BYTE_3: uint32 = 16777216;
const ORDINAL_FLAG: uint32 = 0x80000000;
const ORDINAL_VALUE_MASK: uint32 = 0xffff;
const ORDINAL_RESERVED_LOW: uint32 = 0xffff0000;
const ORDINAL_RESERVED_HIGH: uint32 = 0x7fffffff;

// Header reads use the file end; RVA reads use a proved file-backed range.
function fits(at: int64, size: int64, end: int64): boolean {
	return at >= 0 && size >= 0 && at <= end && size <= end - at;
}

function u16At(
	data: Readonly<Span<uint8>>,
	at: int64,
	end: int64,
	what: string,
): Result<uint16, string> {
	if (!fits(at, 2, end)) {
		return Result.err(
			`${what}: 2 bytes at offset ${at} pass the readable end ${end}`,
		);
	}
	const low = data[at] as uint32;
	const high = data[at + 1] as uint32;
	return Result.ok((low + high * BYTE_1) as uint16);
}

function u32At(
	data: Readonly<Span<uint8>>,
	at: int64,
	end: int64,
	what: string,
): Result<uint32, string> {
	if (!fits(at, 4, end)) {
		return Result.err(
			`${what}: 4 bytes at offset ${at} pass the readable end ${end}`,
		);
	}
	const b0 = data[at] as uint32;
	const b1 = data[at + 1] as uint32;
	const b2 = data[at + 2] as uint32;
	const b3 = data[at + 3] as uint32;
	return Result.ok(b0 + b1 * BYTE_1 + b2 * BYTE_2 + b3 * BYTE_3);
}

function fileBackedSize(this section: Section): int64 {
	return section.virtualSize < section.rawSize ?
		section.virtualSize : section.rawSize;
}

// Both address spaces must meet: a virtual tail or a raw file gap ends the
// readable range, even when the other address space remains contiguous.
function contiguousEnd(
	sections: Section[],
	first: Section,
	backedSize: int64,
	length: int64,
): int64 {
	let end = first.rawPointer + backedSize;
	if (backedSize != first.virtualSize) { return end; }
	let virtualEnd = first.virtualAddress + backedSize;
	for (let step: int32 = 1; step < sections.length; step += 1) {
		let extended = false;
		for (let index: int32 = 0; index < sections.length; index += 1) {
			const next = sections[index];
			if (next.virtualAddress != virtualEnd || next.rawPointer != end) {
				continue;
			}
			const size = next.fileBackedSize();
			if (size == 0) { continue; }
			if (!fits(next.rawPointer, size, length)) { return end; }
			end += size;
			virtualEnd += size;
			if (size != next.virtualSize) { return end; }
			extended = true;
			break;
		}
		if (!extended) { break; }
	}
	return end;
}

function mapRva(
	data: Readonly<Span<uint8>>,
	sections: Section[],
	rva: int64,
	what: string,
): Result<Backed, string> {
	for (let i: int32 = 0; i < sections.length; i += 1) {
		const section = sections[i];
		const start = section.virtualAddress;
		if (rva < start || rva >= start + section.virtualSize) { continue; }
		const backedSize = section.fileBackedSize();
		if (rva - start >= backedSize) {
			return Result.err(
				`${what}: RVA ${rva} is in section ${i} but past its ` +
				`${backedSize} file-backed bytes`,
			);
		}
		if (!fits(section.rawPointer, backedSize, data.length as int64)) {
			return Result.err(
				`${what}: section ${i} raw data (${backedSize} bytes at ` +
				`offset ${section.rawPointer}) passes the end of the file`,
			);
		}
		return Result.ok({
			at: section.rawPointer + (rva - start),
			end: contiguousEnd(sections, section, backedSize, data.length),
		});
	}
	return Result.err(`${what}: RVA ${rva} is in no section`);
}

// NUL-terminated ASCII, copied out; the terminator must be inside `backed`.
function asciiAt(
	data: Readonly<Span<uint8>>,
	backed: Backed,
	what: string,
): Result<string, string> {
	let cursor = backed.at;
	while (cursor < backed.end) {
		const byte = data[cursor];
		if (byte == 0) {
			if (cursor == backed.at) { return Result.ok(""); }
			return Result.ok(data[backed.at..cursor].asString());
		}
		if (byte >= ASCII_LIMIT) {
			return Result.err(
				`${what}: byte ${cursor - backed.at} of the text is not ASCII`,
			);
		}
		cursor += 1;
	}
	return Result.err(`${what}: no NUL before the end of the section data`);
}

function directoryAt(
	data: Readonly<Span<uint8>>,
	optional: int64,
	optionalEnd: int64,
	count: int64,
	index: int64,
	what: string,
): Result<Directory, string> {
	if (index >= count) { return Result.ok({ rva: 0, size: 0 }); }
	const at = optional + OPTIONAL_FIXED_BYTES + index * DIRECTORY_ENTRY_BYTES;
	const rva = try u32At(data, at, optionalEnd, `${what} directory RVA`);
	const size = try u32At(data, at + 4, optionalEnd, `${what} directory size`);
	return Result.ok({ rva: rva as int64, size: size as int64 });
}

function readExports(
	data: Readonly<Span<uint8>>,
	sections: Section[],
	directory: Directory,
): Result<string[], string> {
	const names: string[] = [];
	if (directory.rva == 0) { return Result.ok(names); }
	const table = try mapRva(data, sections, directory.rva, "export directory");
	if (!fits(table.at, directory.size, data.length as int64)) {
		return Result.err(
			`export directory: ${directory.size} bytes at offset ${table.at} ` +
			`pass the end of the file`,
		);
	}
	if (!fits(table.at, EXPORT_TABLE_BYTES, table.end)) {
		return Result.err(
			`export directory: the ${EXPORT_TABLE_BYTES} byte table is cut off ` +
			`by the end of the section data`,
		);
	}
	const count = try u32At(data, table.at + 24, table.end, "export name count");
	const pointers = try u32At(
		data,
		table.at + 32,
		table.end,
		"export names RVA",
	);
	if (count == 0) { return Result.ok(names); }
	const pointerTable = try mapRva(
		data,
		sections,
		pointers as int64,
		"export name table",
	);
	const tableBytes = (count as int64) * NAME_POINTER_BYTES;
	if (!fits(pointerTable.at, tableBytes, pointerTable.end)) {
		return Result.err(
			`export name table: ${count} names do not fit in the section data`,
		);
	}
	for (let i: int64 = 0; i < (count as int64); i++) {
		const nameRva = try u32At(
			data,
			pointerTable.at + i * NAME_POINTER_BYTES,
			pointerTable.end,
			"export name pointer",
		);
		const label = `export name ${i}`;
		const text = try mapRva(data, sections, nameRva as int64, label);
		const name = try asciiAt(data, text, label);
		names.push(name);
	}
	return Result.ok(names);
}

function readThunks(
	data: Readonly<Span<uint8>>,
	sections: Section[],
	rva: int64,
	dll: string,
): Result<PeSymbol[], string> {
	const symbols: PeSymbol[] = [];
	const table = try mapRva(data, sections, rva, `${dll} thunk table`);
	let cursor = table.at;
	while (true) {
		if (!fits(cursor, THUNK_BYTES, table.end)) {
			return Result.err(
				`${dll} thunk table: incomplete thunk or no null thunk before ` +
				`the end of the section data`,
			);
		}
		const low = try u32At(data, cursor, table.end, `${dll} thunk`);
		const high = try u32At(data, cursor + 4, table.end, `${dll} thunk`);
		if (low == 0 && high == 0) { break; }
		if ((high & ORDINAL_FLAG) != 0) {
			if ((low & ORDINAL_RESERVED_LOW) != 0 ||
				(high & ORDINAL_RESERVED_HIGH) != 0) {
				return Result.err(
					`${dll} thunk ${symbols.length}: ordinal entry has reserved ` +
					`bits set`,
				);
			}
			symbols.push({
				kind: PeSymbolKind.Ordinal,
				name: "",
				ordinal: (low & ORDINAL_VALUE_MASK) as uint16,
			});
		} else {
			if (high != 0) {
				return Result.err(
					`${dll} thunk ${symbols.length}: name entry has reserved bits ` +
					`set above its 32 bit RVA`,
				);
			}
			const label = `${dll} import name ${symbols.length}`;
			const entry = try mapRva(data, sections, low as int64, label);
			if (!fits(entry.at, HINT_BYTES, entry.end)) {
				return Result.err(
					`${label}: hint is cut off by the end of the section data`,
				);
			}
			const text: Backed = { at: entry.at + HINT_BYTES, end: entry.end };
			const name = try asciiAt(data, text, label);
			symbols.push({ kind: PeSymbolKind.Name, name, ordinal: 0 });
		}
		cursor += THUNK_BYTES;
	}
	return Result.ok(symbols);
}

function readImports(
	data: Readonly<Span<uint8>>,
	sections: Section[],
	directory: Directory,
): Result<PeImport[], string> {
	const found: PeImport[] = [];
	if (directory.rva == 0) { return Result.ok(found); }
	const table = try mapRva(data, sections, directory.rva, "import directory");
	if (!fits(table.at, directory.size, data.length as int64)) {
		return Result.err(
			`import directory: ${directory.size} bytes at offset ${table.at} ` +
			`pass the end of the file`,
		);
	}
	let cursor = table.at;
	let index: int32 = 0;
	while (true) {
		if (!fits(cursor, IMPORT_DESCRIPTOR_BYTES, table.end)) {
			return Result.err(
				`import directory: no terminating descriptor before the end of ` +
				`the section data (descriptor ${index} at offset ${cursor})`,
			);
		}
		const label = `import descriptor ${index}`;
		const lookup = try u32At(data, cursor, table.end, label);
		const stamp = try u32At(data, cursor + 4, table.end, label);
		const forwarder = try u32At(data, cursor + 8, table.end, label);
		const nameRva = try u32At(data, cursor + 12, table.end, label);
		const address = try u32At(data, cursor + 16, table.end, label);
		if (lookup == 0 && stamp == 0 && forwarder == 0 && nameRva == 0 &&
			address == 0) {
			break;
		}
		const nameLabel = `${label} DLL name`;
		const nameAt = try mapRva(data, sections, nameRva as int64, nameLabel);
		const dll = try asciiAt(data, nameAt, nameLabel);
		const thunkRva = lookup != 0 ? lookup : address;
		const symbols = try readThunks(data, sections, thunkRva as int64, dll);
		found.push({ dll, symbols });
		cursor += IMPORT_DESCRIPTOR_BYTES;
		index += 1;
	}
	return Result.ok(found);
}

export function parsePe(data: Readonly<Span<uint8>>): Result<PeInfo, string> {
	const length = data.length as int64;
	if (length < 2 || data[0] != 0x4d || data[1] != 0x5a) {
		return Result.err("not a PE image: no MZ signature");
	}
	const newHeader = try u32At(
		data,
		DOS_NEW_HEADER_AT,
		length,
		"DOS header e_lfanew",
	);
	const signatureAt = newHeader as int64;
	const signature = try u32At(data, signatureAt, length, "PE signature");
	if (signature != PE_SIGNATURE) {
		return Result.err(`no PE signature at offset ${signatureAt}`);
	}

	const coff = signatureAt + PE_SIGNATURE_BYTES;
	const machine = try u16At(data, coff, length, "COFF machine");
	const sectionCount = try u16At(data, coff + 2, length, "COFF section count");
	const optionalSize = try u16At(data, coff + 16, length, "COFF optional size");
	const characteristics = try u16At(
		data,
		coff + 18,
		length,
		"COFF characteristics",
	);

	const optional = coff + COFF_HEADER_BYTES;
	const optionalEnd = optional + (optionalSize as int64);
	if (!fits(optional, optionalSize as int64, length)) {
		return Result.err(
			`optional header: ${optionalSize} bytes at offset ${optional} pass ` +
			`the end of the file`,
		);
	}
	const magic = try u16At(data, optional, optionalEnd, "optional header magic");
	if (magic == PE32_MAGIC) {
		return Result.err("optional header: PE32 image, only PE32+ is supported");
	}
	if (magic != PE32_PLUS_MAGIC) {
		return Result.err(`optional header: magic ${magic} is not PE32+ (0x20b)`);
	}
	const subsystem = try u16At(
		data,
		optional + OPTIONAL_SUBSYSTEM_AT,
		optionalEnd,
		"optional header subsystem",
	);
	const directoryCount = try u32At(
		data,
		optional + OPTIONAL_DIRECTORY_COUNT_AT,
		optionalEnd,
		"optional header directory count",
	);
	const directories = directoryCount as int64;
	const directoryBytes = OPTIONAL_FIXED_BYTES +
		directories * DIRECTORY_ENTRY_BYTES;
	if (directoryBytes > (optionalSize as int64)) {
		return Result.err(
			`optional header: ${directoryCount} data directories do not fit in ` +
			`its ${optionalSize} bytes`,
		);
	}

	const sectionsAt = optionalEnd;
	const tableBytes = (sectionCount as int64) * SECTION_HEADER_BYTES;
	if (!fits(sectionsAt, tableBytes, length)) {
		return Result.err(
			`section table: ${sectionCount} headers at offset ${sectionsAt} ` +
			`pass the end of the file`,
		);
	}
	const sections: Section[] = [];
	for (let i: int64 = 0; i < (sectionCount as int64); i++) {
		const at = sectionsAt + i * SECTION_HEADER_BYTES;
		const virtualSize = try u32At(data, at + 8, length, "section virtual size");
		const virtualAddress = try u32At(data, at + 12, length, "section address");
		const rawSize = try u32At(data, at + 16, length, "section raw size");
		const rawPointer = try u32At(data, at + 20, length, "section raw pointer");
		sections.push({
			virtualSize: virtualSize as int64,
			virtualAddress: virtualAddress as int64,
			rawSize: rawSize as int64,
			rawPointer: rawPointer as int64,
		});
	}

	const exportDirectory = try directoryAt(
		data,
		optional,
		optionalEnd,
		directories,
		EXPORT_DIRECTORY_INDEX,
		"export",
	);
	const importDirectory = try directoryAt(
		data,
		optional,
		optionalEnd,
		directories,
		IMPORT_DIRECTORY_INDEX,
		"import",
	);
	const exported = try readExports(data, sections, exportDirectory);
	const imported = try readImports(data, sections, importDirectory);
	const info: PeInfo = {
		machine,
		subsystem,
		characteristics,
		imports: imported,
		exports: exported,
	};
	return Result.ok(info);
}
