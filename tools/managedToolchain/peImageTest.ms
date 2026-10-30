import {
	PeImport,
	PeInfo,
	PeSymbol,
	PeSymbolKind,
	parsePe,
} from "./peImage";

// Every image is a PE32+ file with two sections: `.text` (zeros) and a data
// section holding the import and export tables, so an RVA never equals its
// file offset. File offsets of the first table items are kept in BuiltImage
// for the cases that damage them.
const MACHINE_AMD64: uint16 = 0x8664;
const MACHINE_ARM64: uint16 = 0xaa64;
const DATA_RVA: uint32 = 0x2000;
const DATA_RAW: int32 = 0x600;
const E_LFANEW_AT: int32 = 0x3c;
const SIGNATURE_AT: int32 = 0x80;
const MACHINE_AT: int32 = 0x84;
const SECTION_COUNT_AT: int32 = 0x86;
const OPTIONAL_SIZE_AT: int32 = 0x94;
const CHARACTERISTICS_AT: int32 = 0x96;
const MAGIC_AT: int32 = 0x98;
const SUBSYSTEM_AT: int32 = 0xdc;
const DIRECTORY_COUNT_AT: int32 = 0x104;
const EXPORT_DIRECTORY_AT: int32 = 0x108;
const IMPORT_DIRECTORY_AT: int32 = 0x110;
const SECTIONS_AT: int32 = 0x188;
const DATA_SECTION_AT: int32 = 0x1b0;
const SECTION_VIRTUAL_SIZE: int32 = 8;
const SECTION_RAW_SIZE: int32 = 16;
const SECTION_RAW_POINTER: int32 = 20;
const UNMAPPED_RVA: uint64 = 0x9000;
const BIT_31: uint64 = 0x80000000;
const ORDINAL_FLAG: uint64 = 9223372036854775808;

let cases: int32 = 0;

struct ImageSpec {
	machine: uint16;
	characteristics: uint16;
	subsystem: uint16;
	imports: PeImport[];
	exports: string[];
	lookupTables: boolean;
	dataRva: uint32;
	trailer: Vec<uint8>;
}

struct BuiltImage {
	bytes: Vec<uint8>;
	dllName: int32;
	hintName: int32;
	thunks: int32;
	descriptors: int32;
	exportDirectory: int32;
	nameTable: int32;
	ordinalTable: int32;
	exportName: int32;
	trailer: int32;
}

function pass(): void {
	cases += 1;
}

function expect(condition: boolean, what: string): void {
	if (!condition) { throw new Error(what); }
}

function parsed(name: string, data: Readonly<Span<uint8>>): PeInfo {
	const result = parsePe(data);
	if (!result.ok) { throw new Error(`${name}: refused: ${result.error}`); }
	return result.value;
}

function parsedImage(name: string, image: BuiltImage): PeInfo {
	return parsed(name, image.bytes);
}

function refused(
	name: string,
	data: Readonly<Span<uint8>>,
	needle: string,
): void {
	const result = parsePe(data);
	if (result.ok) { throw new Error(`${name}: accepted`); }
	if (result.error.indexOf(needle) < 0) {
		throw new Error(`${name}: error '${result.error}' lacks '${needle}'`);
	}
	pass();
}

function nameSymbol(name: string): PeSymbol {
	return { kind: PeSymbolKind.Name, name: name, ordinal: 0 };
}

function ordinalSymbol(ordinal: uint16): PeSymbol {
	return { kind: PeSymbolKind.Ordinal, name: "", ordinal: ordinal };
}

function sameSymbols(left: PeSymbol[], right: PeSymbol[]): boolean {
	if (left.length != right.length) { return false; }
	for (let i = 0; i < left.length; i++) {
		if (left[i].kind != right[i].kind) { return false; }
		if (left[i].name != right[i].name) { return false; }
		if (left[i].ordinal != right[i].ordinal) { return false; }
	}
	return true;
}

function sameImports(left: PeImport[], right: PeImport[]): boolean {
	if (left.length != right.length) { return false; }
	for (let i = 0; i < left.length; i++) {
		if (left[i].dll != right[i].dll) { return false; }
		if (!sameSymbols(left[i].symbols, right[i].symbols)) { return false; }
	}
	return true;
}

function sameStrings(left: string[], right: string[]): boolean {
	if (left.length != right.length) { return false; }
	for (let i = 0; i < left.length; i++) {
		if (left[i] != right[i]) { return false; }
	}
	return true;
}

function sameInfo(left: PeInfo, right: PeInfo): boolean {
	return left.machine == right.machine &&
		left.subsystem == right.subsystem &&
		left.characteristics == right.characteristics &&
		sameImports(left.imports, right.imports) &&
		sameStrings(left.exports, right.exports);
}

function putLittle(ref out: Vec<uint8>, value: uint64, width: int32): void {
	let rest = value;
	for (let i = 0; i < width; i++) {
		out.push((rest % 256) as uint8);
		rest = rest / 256;
	}
}

function setLittle(
	ref out: Vec<uint8>,
	at: int32,
	width: int32,
	value: uint64,
): void {
	let rest = value;
	for (let i = 0; i < width; i++) {
		out[at + i] = (rest % 256) as uint8;
		rest = rest / 256;
	}
}

function putText(ref out: Vec<uint8>, text: string): void {
	for (const byte of text.asBytes()) { out.push(byte); }
	out.push(0);
}

function patch(
	bytes: Vec<uint8>,
	at: int32,
	width: int32,
	value: uint64,
): Vec<uint8> {
	let copy = bytes;
	setLittle(copy, at, width, value);
	return copy;
}

function rvaIn(spec: ImageSpec, offset: int32): uint64 {
	return (spec.dataRva as uint64) + (offset as uint64);
}

// The RVA of a file offset of a default-layout image.
function rvaOf(file: int32): uint64 {
	return (DATA_RVA as uint64) + ((file - DATA_RAW) as uint64);
}

function putThunk(
	ref body: Vec<uint8>,
	spec: ImageSpec,
	symbol: PeSymbol,
	hintOffset: int32,
): void {
	if (symbol.kind == PeSymbolKind.Ordinal) {
		putLittle(body, ORDINAL_FLAG + (symbol.ordinal as uint64), 8);
		return;
	}
	putLittle(body, rvaIn(spec, hintOffset), 8);
}

function buildImage(spec: ImageSpec): BuiltImage {
	let body: Vec<uint8> = [];

	const dllOffsets: int32[] = [];
	for (const entry of spec.imports) {
		dllOffsets.push(body.length as int32);
		putText(body, entry.dll);
	}

	const hintOffsets: int32[] = [];
	for (const entry of spec.imports) {
		for (const symbol of entry.symbols) {
			hintOffsets.push(body.length as int32);
			if (symbol.kind == PeSymbolKind.Name) {
				putLittle(body, 0x0102, 2);
				putText(body, symbol.name);
			}
		}
	}

	// With lookup tables the address table is a decoy that names an unmapped
	// RVA, so a reader that prefers it fails; without them the address table
	// carries the thunks.
	const thunkOffsets: int32[] = [];
	const addressOffsets: int32[] = [];
	let flat = 0;
	for (const entry of spec.imports) {
		const first = body.length as int32;
		thunkOffsets.push(first);
		for (const symbol of entry.symbols) {
			putThunk(body, spec, symbol, hintOffsets[flat]);
			flat += 1;
		}
		putLittle(body, 0, 8);
		if (spec.lookupTables) {
			addressOffsets.push(body.length as int32);
			putLittle(body, UNMAPPED_RVA, 8);
			putLittle(body, 0, 8);
		} else {
			addressOffsets.push(first);
		}
	}

	let exportName = 0;
	let nameTable = 0;
	let ordinalTable = 0;
	let exportDirectory = 0;
	if (spec.exports.length > 0) {
		const dllName = body.length as int32;
		putText(body, "fixture.dll");
		const stringOffsets: int32[] = [];
		for (const name of spec.exports) {
			stringOffsets.push(body.length as int32);
			putText(body, name);
		}
		exportName = stringOffsets[0];
		const addressTable = body.length as int32;
		for (let i: int32 = 0; i <= spec.exports.length; i += 1) {
			putLittle(body, (0x1000 + i * 4) as uint64, 4);
		}
		ordinalTable = body.length as int32;
		for (let i: int32 = 0; i < spec.exports.length; i += 1) {
			putLittle(body, ((i + 1) % spec.exports.length) as uint64, 2);
		}
		nameTable = body.length as int32;
		for (const offset of stringOffsets) {
			putLittle(body, rvaIn(spec, offset), 4);
		}
		exportDirectory = body.length as int32;
		putLittle(body, 0, 4);
		putLittle(body, 0, 4);
		putLittle(body, 0, 2);
		putLittle(body, 0, 2);
		putLittle(body, rvaIn(spec, dllName), 4);
		putLittle(body, 1, 4);
		putLittle(body, (spec.exports.length + 1) as uint64, 4);
		putLittle(body, spec.exports.length as uint64, 4);
		putLittle(body, rvaIn(spec, addressTable), 4);
		putLittle(body, rvaIn(spec, nameTable), 4);
		putLittle(body, rvaIn(spec, ordinalTable), 4);
	}

	let descriptors = 0;
	if (spec.imports.length > 0) {
		descriptors = body.length as int32;
		for (let i = 0; i < spec.imports.length; i++) {
			putLittle(body, spec.lookupTables ? rvaIn(spec, thunkOffsets[i]) : 0, 4);
			putLittle(body, 0, 4);
			putLittle(body, 0, 4);
			putLittle(body, rvaIn(spec, dllOffsets[i]), 4);
			putLittle(body, rvaIn(spec, addressOffsets[i]), 4);
		}
		for (let i = 0; i < 5; i++) { putLittle(body, 0, 4); }
	}

	const trailer = body.length as int32;
	for (const byte of spec.trailer) { body.push(byte); }

	let bytes: Vec<uint8> = [];
	for (let i = 0; i < DATA_RAW; i++) { bytes.push(0); }
	setLittle(bytes, 0, 2, 0x5a4d);
	setLittle(bytes, E_LFANEW_AT, 4, 0x80);
	setLittle(bytes, SIGNATURE_AT, 4, 0x4550);
	setLittle(bytes, MACHINE_AT, 2, spec.machine as uint64);
	setLittle(bytes, SECTION_COUNT_AT, 2, 2);
	setLittle(bytes, OPTIONAL_SIZE_AT, 2, 240);
	setLittle(bytes, CHARACTERISTICS_AT, 2, spec.characteristics as uint64);
	setLittle(bytes, MAGIC_AT, 2, 0x20b);
	setLittle(bytes, SUBSYSTEM_AT, 2, spec.subsystem as uint64);
	setLittle(bytes, DIRECTORY_COUNT_AT, 4, 16);
	if (spec.exports.length > 0) {
		setLittle(bytes, EXPORT_DIRECTORY_AT, 4, rvaIn(spec, exportDirectory));
		setLittle(bytes, EXPORT_DIRECTORY_AT + 4, 4, 40);
	}
	if (spec.imports.length > 0) {
		setLittle(bytes, IMPORT_DIRECTORY_AT, 4, rvaIn(spec, descriptors));
		const size = ((spec.imports.length + 1) * 20) as uint64;
		setLittle(bytes, IMPORT_DIRECTORY_AT + 4, 4, size);
	}
	setLittle(bytes, SECTIONS_AT + SECTION_VIRTUAL_SIZE, 4, 0x200);
	setLittle(bytes, SECTIONS_AT + 12, 4, 0x1000);
	setLittle(bytes, SECTIONS_AT + SECTION_RAW_SIZE, 4, 0x200);
	setLittle(bytes, SECTIONS_AT + SECTION_RAW_POINTER, 4, 0x400);
	const data = DATA_SECTION_AT;
	const bodyBytes = body.length as uint64;
	setLittle(bytes, data + SECTION_VIRTUAL_SIZE, 4, bodyBytes);
	setLittle(bytes, data + 12, 4, spec.dataRva as uint64);
	setLittle(bytes, data + SECTION_RAW_SIZE, 4, bodyBytes);
	setLittle(bytes, data + SECTION_RAW_POINTER, 4, DATA_RAW as uint64);
	for (const byte of body) { bytes.push(byte); }

	const hasImports = spec.imports.length > 0;
	return {
		bytes: bytes,
		dllName: hasImports ? DATA_RAW + dllOffsets[0] : 0,
		hintName: hintOffsets.length > 0 ? DATA_RAW + hintOffsets[0] : 0,
		thunks: hasImports ? DATA_RAW + thunkOffsets[0] : 0,
		descriptors: DATA_RAW + descriptors,
		exportDirectory: DATA_RAW + exportDirectory,
		nameTable: DATA_RAW + nameTable,
		ordinalTable: DATA_RAW + ordinalTable,
		exportName: DATA_RAW + exportName,
		trailer: DATA_RAW + trailer,
	};
}

function standardImports(): PeImport[] {
	return [
		{
			dll: "KERNEL32.dll",
			symbols: [nameSymbol("ExitProcess"), nameSymbol("GetStdHandle")],
		},
		{
			dll: "ws2_32.dll",
			symbols: [ordinalSymbol(115), nameSymbol("WSAStartup")],
		},
	];
}

function standardExports(): string[] {
	return ["zeta", "alpha", "mid"];
}

function standardSpec(): ImageSpec {
	return {
		machine: MACHINE_AMD64,
		characteristics: 0x22,
		subsystem: 3,
		imports: standardImports(),
		exports: standardExports(),
		lookupTables: false,
		dataRva: DATA_RVA,
		trailer: [],
	};
}

function standardImage(): BuiltImage {
	return buildImage(standardSpec());
}

function withTrailer(trailer: Vec<uint8>): BuiltImage {
	let spec = standardSpec();
	spec.trailer = trailer;
	return buildImage(spec);
}

function expectTables(
	name: string,
	info: PeInfo,
	wantImports: PeImport[],
	wantExports: string[],
): void {
	expect(sameImports(info.imports, wantImports), `${name}: imports differ`);
	expect(sameStrings(info.exports, wantExports), `${name}: exports differ`);
}

function amd64ImageIsRead(): void {
	const info = parsedImage("standard", standardImage());
	expect(info.machine == MACHINE_AMD64, "standard machine");
	expect(info.subsystem == 3, "standard subsystem");
	expect(info.characteristics == 0x22, "standard characteristics");
	expectTables("standard", info, standardImports(), standardExports());
	pass();
}

function arm64ImageIsRead(): void {
	let spec = standardSpec();
	spec.machine = MACHINE_ARM64;
	const info = parsedImage("arm64", buildImage(spec));
	expect(info.machine == 0xaa64, "arm64 machine");
	expectTables("arm64", info, standardImports(), standardExports());
	pass();
}

function dllCharacteristicsAreRead(): void {
	let spec = standardSpec();
	spec.characteristics = 0x2022;
	const info = parsedImage("dll", buildImage(spec));
	expect(info.characteristics == 0x2022, "dll characteristics");
	expect((info.characteristics & 0x2000) != 0, "dll bit");
	pass();
}

function guiSubsystemIsRead(): void {
	let spec = standardSpec();
	spec.subsystem = 2;
	expect(parsedImage("gui", buildImage(spec)).subsystem == 2, "gui");
	pass();
}

function anyMachineIsAccepted(): void {
	let spec = standardSpec();
	spec.machine = 0x14c;
	const info = parsedImage("i386 machine", buildImage(spec));
	expect(info.machine == 0x14c, "machine is reported, not policed");
	pass();
}

function sixteenBitFieldsKeepTheirHighBits(): void {
	let spec = standardSpec();
	spec.machine = 0xffff;
	spec.characteristics = 0xffff;
	spec.subsystem = 0xff03;
	const info = parsedImage("wide fields", buildImage(spec));
	expect(info.machine == 0xffff, "machine truncated");
	expect(info.characteristics == 0xffff, "characteristics truncated");
	expect(info.subsystem == 0xff03, "subsystem truncated");
	pass();
}

function zeroDirectoriesGiveNoTables(): void {
	const good = standardImage().bytes;
	const none = parsed("no directories", patch(good, DIRECTORY_COUNT_AT, 4, 0));
	expectTables("no directories", none, [], []);
	expect(none.machine == MACHINE_AMD64, "no directories machine");
	pass();
}

function directoriesWithZeroRvaGiveNoTables(): void {
	let bytes = standardImage().bytes;
	setLittle(bytes, EXPORT_DIRECTORY_AT, 8, 0);
	setLittle(bytes, IMPORT_DIRECTORY_AT, 8, 0);
	expectTables("zero RVAs", parsed("zero RVAs", bytes), [], []);
	pass();
}

function onlyTheExportDirectoryIsPresent(): void {
	const good = standardImage().bytes;
	const info = parsed("one directory", patch(good, DIRECTORY_COUNT_AT, 4, 1));
	expectTables("one directory", info, [], standardExports());
	pass();
}

function exportsWithoutImports(): void {
	let spec = standardSpec();
	spec.imports = [];
	const info = parsedImage("exports only", buildImage(spec));
	expectTables("exports only", info, [], standardExports());
	pass();
}

function importsWithoutExports(): void {
	let spec = standardSpec();
	spec.exports = [];
	const info = parsedImage("imports only", buildImage(spec));
	expectTables("imports only", info, standardImports(), []);
	pass();
}

function noSectionsAndNoDirectoriesIsAnEmptyImage(): void {
	let bytes = standardImage().bytes;
	setLittle(bytes, SECTION_COUNT_AT, 2, 0);
	setLittle(bytes, DIRECTORY_COUNT_AT, 4, 0);
	const info = parsed("minimal", bytes);
	expectTables("minimal", info, [], []);
	pass();
}

function ordinalOnlyImportsKeepEveryOrdinal(): void {
	let spec = standardSpec();
	spec.imports = [
		{
			dll: "a.dll",
			symbols: [ordinalSymbol(1), ordinalSymbol(65535), ordinalSymbol(0)],
		},
	];
	const info = parsedImage("ordinals", buildImage(spec));
	expectTables("ordinals", info, spec.imports, standardExports());
	const symbols = info.imports[0].symbols;
	expect(symbols[1].ordinal == 65535, "ordinal 65535 truncated");
	expect(symbols[1].name == "", "ordinal import has a name");
	pass();
}

function namedImportsKeepCaseAndPunctuation(): void {
	let spec = standardSpec();
	spec.imports = [
		{
			dll: "api-ms-win-CRT-stdio-l1-1-0.DLL",
			symbols: [nameSymbol("_Z3fooPKc"), nameSymbol("a.b$c@8")],
		},
	];
	const info = parsedImage("raw names", buildImage(spec));
	expectTables("raw names", info, spec.imports, standardExports());
	expect(info.imports[0].symbols[0].ordinal == 0, "name symbol ordinal");
	pass();
}

function lookupTablesWinOverTheAddressTable(): void {
	let spec = standardSpec();
	spec.lookupTables = true;
	const info = parsedImage("lookup", buildImage(spec));
	expectTables("lookup", info, standardImports(), standardExports());
	pass();
}

function missingAddressTableIsNotNeededWithLookupTables(): void {
	let spec = standardSpec();
	spec.lookupTables = true;
	const image = buildImage(spec);
	let bytes = image.bytes;
	setLittle(bytes, image.descriptors + 16, 4, 0);
	const info = parsed("no address table", bytes);
	expectTables("no address table", info, standardImports(), standardExports());
	pass();
}

function duplicateDescriptorsAreKeptInOrder(): void {
	let spec = standardSpec();
	spec.imports = [
		{ dll: "KERNEL32.dll", symbols: [nameSymbol("ExitProcess")] },
		{ dll: "kernel32.DLL", symbols: [nameSymbol("ExitProcess")] },
		{ dll: "KERNEL32.dll", symbols: [ordinalSymbol(7)] },
	];
	const info = parsedImage("duplicates", buildImage(spec));
	expectTables("duplicates", info, spec.imports, standardExports());
	expect(info.imports.length == 3, "duplicate descriptors merged");
	pass();
}

function descriptorWithoutSymbolsIsKept(): void {
	let spec = standardSpec();
	spec.imports = [{ dll: "empty.dll", symbols: [] }];
	const info = parsedImage("empty table", buildImage(spec));
	expectTables("empty table", info, spec.imports, standardExports());
	pass();
}

function duplicateExportsKeepTheNameTableOrder(): void {
	let spec = standardSpec();
	spec.exports = ["dup", "Dup", "dup", "a"];
	const info = parsedImage("export order", buildImage(spec));
	expect(sameStrings(info.exports, spec.exports), "export order");
	pass();
}

function exportTableWithoutNames(): void {
	const image = standardImage();
	const info = parsed(
		"no names",
		patch(image.bytes, image.exportDirectory + 24, 4, 0),
	);
	expectTables("no names", info, standardImports(), []);
	pass();
}

function sectionAboveTwoGibibytesIsMapped(): void {
	let spec = standardSpec();
	spec.dataRva = 0x90000000;
	const info = parsedImage("high RVA", buildImage(spec));
	expectTables("high RVA", info, standardImports(), standardExports());
	pass();
}

function virtualSizeBeyondRawDataKeepsTheBackedPrefix(): void {
	const image = standardImage();
	const size = (image.bytes.length - DATA_RAW + 0x1000) as uint64;
	const bytes = patch(
		image.bytes,
		DATA_SECTION_AT + SECTION_VIRTUAL_SIZE,
		4,
		size,
	);
	const info = parsed("virtual tail", bytes);
	expectTables("virtual tail", info, standardImports(), standardExports());
	pass();
}

function viewOffsetsAreRelativeToTheView(): void {
	const good = standardImage().bytes;
	let host: Vec<uint8> = [];
	for (let i = 0; i < 17; i++) { host.push(0xaa); }
	for (const byte of good) { host.push(byte); }
	for (let i = 0; i < 32; i++) { host.push(0xbb); }
	const inside = parsed("view", host[17..17 + good.length]);
	expect(sameInfo(inside, parsed("whole", good)), "view differs from whole");
	pass();
}

function bytesPastTheViewAreNotRead(): void {
	const good = standardImage().bytes;
	let host: Vec<uint8> = [];
	for (const byte of good) { host.push(byte); }
	for (let i = 0; i < 32; i++) { host.push(0); }
	refused(
		"view ends early",
		host[0..good.length - 1],
		"passes the end of the file",
	);
	const longer = parsed("longer view", host[0..good.length + 8]);
	expect(longer.imports.length == 2, "a view with trailing bytes differs");
}

function resultsOutliveTheirInput(): void {
	let live = standardImage().bytes;
	const info = parsed("owned", live);
	for (let i = 0; i < live.length; i++) { live[i] = 0; }
	expectTables("owned", info, standardImports(), standardExports());
	pass();
}

function everyProperPrefixIsRefused(): void {
	const good = standardImage().bytes;
	expect(parsePe(good).ok, "whole image refused");
	for (let n = 0; n < good.length; n++) {
		if (parsePe(good[0..n]).ok) {
			throw new Error(`prefix of ${n} bytes was accepted`);
		}
	}
	pass();
}

function refusedPatch(
	name: string,
	bytes: Vec<uint8>,
	at: int32,
	width: int32,
	value: uint64,
	needle: string,
): void {
	refused(name, patch(bytes, at, width, value), needle);
}

function headerDamageIsRefused(): void {
	const good = standardImage().bytes;
	const length = good.length;
	const single: Vec<uint8> = [0x4d];
	const lfanew = E_LFANEW_AT;
	refused("empty buffer", Buffer.alloc(0), "no MZ");
	refused("one byte", single, "no MZ");
	refusedPatch("ZM", good, 0, 2, 0x4d5a, "no MZ");
	refused("MZ only", good[0..2], "e_lfanew");
	refused("short DOS header", good[0..0x3f], "e_lfanew");
	refusedPatch(
		"e_lfanew past end",
		good,
		lfanew,
		4,
		0xffffffff,
		"PE signature",
	);
	const atEnd = (length - 2) as uint64;
	refusedPatch("e_lfanew at end", good, lfanew, 4, atEnd, "PE signature");
	refusedPatch(
		"PE signature",
		good,
		SIGNATURE_AT,
		4,
		0x4546,
		"no PE signature",
	);
	refusedPatch("e_lfanew off by one", good, lfanew, 4, 0x81, "no PE signature");
	refused("no COFF header", good[0..MACHINE_AT], "COFF");
	refused("short COFF header", good[0..MACHINE_AT + 10], "COFF");
	refusedPatch("PE32", good, MAGIC_AT, 2, 0x10b, "PE32 image");
	refusedPatch("ROM magic", good, MAGIC_AT, 2, 0x107, "is not PE32+");
	refusedPatch("zero magic", good, MAGIC_AT, 2, 0, "is not PE32+");
	const magic = "optional header magic";
	refusedPatch("no optional header", good, OPTIONAL_SIZE_AT, 2, 0, magic);
	refusedPatch("one byte optional", good, OPTIONAL_SIZE_AT, 2, 1, magic);
	refusedPatch(
		"short optional",
		good,
		OPTIONAL_SIZE_AT,
		2,
		100,
		"directory count",
	);
	refusedPatch(
		"optional past end",
		good,
		OPTIONAL_SIZE_AT,
		2,
		0xffff,
		"optional header: 65535",
	);
	refusedPatch(
		"directories 2^32-1",
		good,
		DIRECTORY_COUNT_AT,
		4,
		0xffffffff,
		"do not fit",
	);
	refusedPatch("directories 17", good, DIRECTORY_COUNT_AT, 4, 17, "do not fit");
	refusedPatch(
		"sections 65535",
		good,
		SECTION_COUNT_AT,
		2,
		0xffff,
		"section table",
	);
	refused("cut section table", good[0..DATA_SECTION_AT + 39], "section table");
}

function sectionDamageIsRefused(): void {
	const good = standardImage().bytes;
	const rawSize = DATA_SECTION_AT + SECTION_RAW_SIZE;
	const rawPointer = DATA_SECTION_AT + SECTION_RAW_POINTER;
	const virtualSize = DATA_SECTION_AT + SECTION_VIRTUAL_SIZE;
	const past = "passes the end of the file";
	refusedPatch("raw pointer past end", good, rawPointer, 4, 0xffffffff, past);
	const wrapped = patch(good, rawPointer, 4, 0xfffffff0);
	refusedPatch("pointer plus size", wrapped, rawSize, 4, 0x100, past);
	refused("cut data section", good[0..good.length - 1], past);
	refusedPatch("short raw data", good, rawSize, 4, 0x10, "file-backed bytes");
	refusedPatch("no raw data", good, rawSize, 4, 0, "file-backed bytes");
	refusedPatch(
		"short virtual size",
		good,
		virtualSize,
		4,
		0x10,
		"in no section",
	);
	refusedPatch("no sections", good, SECTION_COUNT_AT, 2, 0, "in no section");
	const unmapped = "in no section";
	refusedPatch(
		"export RVA",
		good,
		EXPORT_DIRECTORY_AT,
		4,
		UNMAPPED_RVA,
		unmapped,
	);
	refusedPatch(
		"import RVA",
		good,
		IMPORT_DIRECTORY_AT,
		4,
		UNMAPPED_RVA,
		unmapped,
	);
	const exportSize = "export directory: 4294967295 bytes";
	const importSize = "import directory: 4294967295 bytes";
	refusedPatch(
		"export size",
		good,
		EXPORT_DIRECTORY_AT + 4,
		4,
		0xffffffff,
		exportSize,
	);
	refusedPatch(
		"import size",
		good,
		IMPORT_DIRECTORY_AT + 4,
		4,
		0xffffffff,
		importSize,
	);
}

function importTableDamageIsRefused(): void {
	let noExports = standardSpec();
	noExports.exports = [];
	const last = buildImage(noExports);
	const bodyBytes = (last.bytes.length - DATA_RAW) as uint64;
	const rawSize = DATA_SECTION_AT + SECTION_RAW_SIZE;
	const virtualSize = DATA_SECTION_AT + SECTION_VIRTUAL_SIZE;
	const terminator = "terminating descriptor";
	const noTerminator = patch(last.bytes, rawSize, 4, bodyBytes - 20);
	const half = patch(last.bytes, rawSize, 4, bodyBytes - 10);
	refusedPatch(
		"no terminator",
		noTerminator,
		virtualSize,
		4,
		bodyBytes - 20,
		terminator,
	);
	refusedPatch(
		"half terminator",
		half,
		virtualSize,
		4,
		bodyBytes - 10,
		terminator,
	);

	const image = standardImage();
	const good = image.bytes;
	const nameAt = image.descriptors + 12;
	const tableAt = image.descriptors + 16;
	const dllLabel = "import descriptor 0 DLL name";
	refusedPatch("DLL name RVA", good, nameAt, 4, UNMAPPED_RVA, dllLabel);
	refusedPatch("DLL name RVA zero", good, nameAt, 4, 0, "in no section");
	refusedPatch("DLL name text", good, image.dllName, 1, 0xe9, "not ASCII");
	refusedPatch(
		"import name text",
		good,
		image.hintName + 2,
		1,
		0xe9,
		"not ASCII",
	);
	refusedPatch(
		"address table RVA",
		good,
		tableAt,
		4,
		UNMAPPED_RVA,
		"KERNEL32.dll thunk table",
	);

	let lookup = standardSpec();
	lookup.lookupTables = true;
	const withLookup = buildImage(lookup);
	const lookupAt = withLookup.descriptors;
	refusedPatch(
		"lookup RVA",
		withLookup.bytes,
		lookupAt,
		4,
		UNMAPPED_RVA,
		"in no section",
	);
}

function thunkDamageIsRefused(): void {
	const image = standardImage();
	const good = image.bytes;
	const nameLabel = "KERNEL32.dll import name 0";
	refusedPatch("name RVA", good, image.thunks, 4, 0x70000, nameLabel);
	const wide = rvaOf(image.hintName) + BIT_31;
	refusedPatch("name RVA bit 31", good, image.thunks, 4, wide, "in no section");
	refusedPatch(
		"name high dword",
		good,
		image.thunks + 4,
		4,
		1,
		"reserved bits",
	);

	let ordinals = standardSpec();
	ordinals.imports = [{ dll: "a.dll", symbols: [ordinalSymbol(5)] }];
	const ordinal = buildImage(ordinals);
	const reserved = "reserved bits";
	refusedPatch(
		"ordinal bit 16",
		ordinal.bytes,
		ordinal.thunks,
		4,
		0x10005,
		reserved,
	);
	refusedPatch(
		"ordinal bit 32",
		ordinal.bytes,
		ordinal.thunks + 4,
		4,
		0x80000001,
		reserved,
	);

	const hintOnly = withTrailer([0x01]);
	const hintRva = rvaOf(hintOnly.trailer);
	refusedPatch(
		"cut hint",
		hintOnly.bytes,
		hintOnly.thunks,
		4,
		hintRva,
		"hint is cut off",
	);
	const unterminated = withTrailer([0x01, 0x00, 0x61, 0x62]);
	const nameRva = rvaOf(unterminated.trailer);
	refusedPatch(
		"name without NUL",
		unterminated.bytes,
		unterminated.thunks,
		4,
		nameRva,
		"no NUL",
	);

	const ordinalEntry = withTrailer([5, 0, 0, 0, 0, 0, 0, 0x80]);
	const tableRva = rvaOf(ordinalEntry.trailer);
	const ordinalAt = ordinalEntry.descriptors + 16;
	refusedPatch(
		"no null thunk",
		ordinalEntry.bytes,
		ordinalAt,
		4,
		tableRva,
		"thunk table",
	);
	const partial = withTrailer([5, 0, 0, 0, 0]);
	const partialAt = partial.descriptors + 16;
	refusedPatch(
		"incomplete thunk",
		partial.bytes,
		partialAt,
		4,
		rvaOf(partial.trailer),
		"thunk table",
	);

	const text = withTrailer([0x61, 0x62, 0x63, 0x64, 0x65, 0x66]);
	const textAt = text.descriptors + 12;
	refusedPatch(
		"DLL name without NUL",
		text.bytes,
		textAt,
		4,
		rvaOf(text.trailer),
		"no NUL",
	);
}

function exportTableDamageIsRefused(): void {
	const image = standardImage();
	const good = image.bytes;
	const countAt = image.exportDirectory + 24;
	const pointersAt = image.exportDirectory + 32;
	refusedPatch("count 2^32-1", good, countAt, 4, 0xffffffff, "do not fit");
	refusedPatch("count past pointers", good, countAt, 4, 4, "export name 3");
	refusedPatch(
		"pointer table RVA",
		good,
		pointersAt,
		4,
		UNMAPPED_RVA,
		"export name table",
	);
	refusedPatch(
		"pointer RVA",
		good,
		image.nameTable,
		4,
		UNMAPPED_RVA,
		"export name 0",
	);
	refusedPatch("name text", good, image.exportName, 1, 0xff, "not ASCII");

	const cut = withTrailer([
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	]);
	const header = patch(cut.bytes, EXPORT_DIRECTORY_AT, 4, rvaOf(cut.trailer));
	const sizeAt = EXPORT_DIRECTORY_AT + 4;
	refusedPatch("cut export table", header, sizeAt, 4, 0, "table is cut off");

	const text = withTrailer([0x61, 0x62, 0x63]);
	const textRva = rvaOf(text.trailer);
	refusedPatch(
		"name without NUL",
		text.bytes,
		text.nameTable,
		4,
		textRva,
		"export name 0",
	);
}

function setTextAt(ref bytes: Vec<uint8>, at: int32, text: string): void {
	let cursor = at;
	for (const byte of text.asBytes()) {
		bytes[cursor] = byte;
		cursor += 1;
	}
	bytes[cursor] = 0;
}

function crossSectionImage(kind: int32): Vec<uint8> {
	let bytes = standardImage().bytes;
	while (bytes.length < DATA_RAW + 0x2000) { bytes.push(0); }
	for (let i: int32 = DATA_RAW; i < bytes.length; i += 1) { bytes[i] = 0; }
	setLittle(bytes, EXPORT_DIRECTORY_AT, 8, 0);
	setLittle(bytes, SECTION_COUNT_AT, 2, 3);
	setLittle(bytes, DATA_SECTION_AT + SECTION_VIRTUAL_SIZE, 4, 0x1000);
	setLittle(bytes, DATA_SECTION_AT + SECTION_RAW_SIZE, 4, 0x1000);
	const next = DATA_SECTION_AT + 40;
	setLittle(bytes, next + SECTION_VIRTUAL_SIZE, 4, 0x1000);
	setLittle(bytes, next + 12, 4, 0x3000);
	setLittle(bytes, next + SECTION_RAW_SIZE, 4, 0x1000);
	setLittle(bytes, next + SECTION_RAW_POINTER, 4,
		(DATA_RAW + 0x1000) as uint64);
	const descriptorRva: uint64 = kind == 0 ? 0x2ff8 : 0x3080;
	const nameRva: uint64 = kind == 1 ? 0x2ff8 : 0x3020;
	const thunkRva: uint64 = kind == 2 ? 0x2ff8 : 0x3040;
	const descriptor = DATA_RAW + (descriptorRva as int32) - 0x2000;
	setLittle(bytes, IMPORT_DIRECTORY_AT, 4, descriptorRva);
	setLittle(bytes, IMPORT_DIRECTORY_AT + 4, 4, 40);
	setLittle(bytes, descriptor, 4, thunkRva);
	setLittle(bytes, descriptor + 12, 4, nameRva);
	setLittle(bytes, descriptor + 16, 4, thunkRva);
	setTextAt(bytes, DATA_RAW + (nameRva as int32) - 0x2000, "KERNEL32.dll");
	setLittle(bytes, DATA_RAW + (thunkRva as int32) - 0x2000, 8, 0x3060);
	setLittle(bytes, DATA_RAW + 0x1060, 2, 0x0102);
	setTextAt(bytes, DATA_RAW + 0x1062, "ExitProcess");
	return bytes;
}

function crossSectionTablesAndTextAreRead(): void {
	const imports: PeImport[] = [
		{ dll: "KERNEL32.dll", symbols: [nameSymbol("ExitProcess")] },
	];
	for (const kind of [0, 1, 2]) {
		const info = parsed("contiguous sections " + String(kind),
			crossSectionImage(kind));
		expectTables("contiguous sections", info, imports, []);
		pass();
	}
	let empty = crossSectionImage(0);
	const next = DATA_SECTION_AT + 40;
	for (let i: int32 = 0; i < 40; i += 1) {
		empty[next + 40 + i] = empty[next + i];
	}
	setLittle(empty, SECTION_COUNT_AT, 2, 4);
	setLittle(empty, next + SECTION_VIRTUAL_SIZE, 4, 0);
	setLittle(empty, next + SECTION_RAW_SIZE, 4, 0);
	expectTables("empty section at adjacency boundary", parsed("empty section",
		empty), imports, []);
	pass();
	const descriptor = crossSectionImage(0);
	refused("virtual gap after descriptor prefix",
		patch(descriptor, DATA_SECTION_AT + 40 + 12, 4, 0x3001),
		"terminating descriptor");
	refused("raw gap after descriptor prefix",
		patch(descriptor, DATA_SECTION_AT + 40 + SECTION_RAW_POINTER, 4,
			(DATA_RAW + 0x1001) as uint64), "terminating descriptor");
}

function aliasesAndOrdinalOnlyExportsKeepNames(): void {
	const image = standardImage();
	let bytes = image.bytes;
	setLittle(bytes, image.ordinalTable, 2, 2);
	setLittle(bytes, image.ordinalTable + 2, 2, 0);
	setLittle(bytes, image.ordinalTable + 4, 2, 2);
	const info = parsed("aliases and ordinal-only exports", bytes);
	expectTables("export associations", info, standardImports(),
		standardExports());
	pass();
}

function run(): void {
	crossSectionTablesAndTextAreRead();
	aliasesAndOrdinalOnlyExportsKeepNames();
	amd64ImageIsRead();
	arm64ImageIsRead();
	dllCharacteristicsAreRead();
	guiSubsystemIsRead();
	anyMachineIsAccepted();
	sixteenBitFieldsKeepTheirHighBits();
	zeroDirectoriesGiveNoTables();
	directoriesWithZeroRvaGiveNoTables();
	onlyTheExportDirectoryIsPresent();
	exportsWithoutImports();
	importsWithoutExports();
	noSectionsAndNoDirectoriesIsAnEmptyImage();
	ordinalOnlyImportsKeepEveryOrdinal();
	namedImportsKeepCaseAndPunctuation();
	lookupTablesWinOverTheAddressTable();
	missingAddressTableIsNotNeededWithLookupTables();
	duplicateDescriptorsAreKeptInOrder();
	descriptorWithoutSymbolsIsKept();
	duplicateExportsKeepTheNameTableOrder();
	exportTableWithoutNames();
	sectionAboveTwoGibibytesIsMapped();
	virtualSizeBeyondRawDataKeepsTheBackedPrefix();
	viewOffsetsAreRelativeToTheView();
	bytesPastTheViewAreNotRead();
	resultsOutliveTheirInput();
	everyProperPrefixIsRefused();
	headerDamageIsRefused();
	sectionDamageIsRefused();
	importTableDamageIsRefused();
	thunkDamageIsRefused();
	exportTableDamageIsRefused();
	console.log(`PE images: ${cases} cases OK`);
}

when (!testBuild) { run(); }
