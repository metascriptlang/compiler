import { MachOInfo, parseMachO } from "./machOImage";

const ARM64: uint32 = 0x100000c;
const X64: uint32 = 0x1000007;
const MAIN: uint32 = 0x80000028;
const BUILD: uint32 = 0x32;
const SEGMENT: uint32 = 0x19;
const LOAD: uint32 = 0xc;
const ID: uint32 = 0xd;
const DYLD: uint32 = 0xe;

let cases: int32 = 0;

function put(data: Buffer, at: int32, value: uint32): void {
	for (let i: int32 = 0; i < 4; i += 1) {
		data[at + i] = ((value >> ((i * 8) as uint32)) & 255) as uint8;
	}
}

function command(kind: uint32, size: int32): Buffer {
	const result = Buffer.alloc(size);
	put(result, 0, kind);
	put(result, 4, size as uint32);
	return result;
}

function image(cpu: uint32, commands: Buffer[], fileType: uint32 = 2): Buffer {
	let total: int32 = 0;
	for (const item of commands) { total += item.length as int32; }
	const data = Buffer.alloc(32 + total);
	put(data, 0, 0xfeedfacf);
	put(data, 4, cpu);
	put(data, 12, fileType);
	put(data, 16, commands.length as uint32);
	put(data, 20, total as uint32);
	let cursor: int32 = 32;
	for (const item of commands) {
		for (const byte of item) {
			data[cursor] = byte;
			cursor += 1;
		}
	}
	return data;
}

function named(kind: uint32, text: string): Buffer {
	const start: int32 = kind == DYLD ? 12 : 24;
	const encoded = Buffer.fromString(text, "utf8");
	let size = start + (encoded.length as int32) + 1;
	while (size % 8 != 0) { size += 1; }
	const data = command(kind, size);
	put(data, 8, start as uint32);
	for (let i: int32 = 0; i < encoded.length; i += 1) {
		data[start + i] = encoded[i];
	}
	return data;
}

function build(tools: uint32 = 0): Buffer {
	const data = command(BUILD, 24 + 8 * (tools as int32));
	put(data, 8, 1);
	put(data, 12, 0xb0000);
	put(data, 16, 0xb0100);
	put(data, 20, tools);
	return data;
}

function fixedName(data: Buffer, at: int32, text: string): void {
	const encoded = text.asBytes();
	for (let i: int32 = 0; i < encoded.length; i += 1) {
		data[at + i] = encoded[i];
	}
}

function segment(): Buffer {
	const data = command(SEGMENT, 152);
	put(data, 64, 1);
	fixedName(data, 72, "__unwind_info");
	fixedName(data, 88, "__TEXT");
	return data;
}

function accepted(data: Readonly<Span<uint8>>): MachOInfo {
	const result = parseMachO(data);
	if (!result.ok) { throw new Error(result.error); }
	cases += 1;
	return result.value;
}

function refused(data: Readonly<Span<uint8>>, fragment: string): void {
	const result = parseMachO(data);
	if (result.ok || result.error.indexOf(fragment) < 0) {
		throw new Error("expected Mach-O refusal containing " + fragment);
	}
	cases += 1;
}

function expect(condition: boolean, what: string): void {
	if (!condition) { throw new Error(what); }
}

function run(): void {
	for (const cpu of [ARM64, X64]) {
		const standard = image(cpu, [build(), command(MAIN, 24),
			named(DYLD, "/usr/lib/dyld"), named(LOAD, "/usr/lib/libSystem.B.dylib"),
			segment(), command(0x1d, 16)]);
		const info = accepted(standard);
		expect(info.cpuType == cpu && info.fileType == 2, "header identity");
		expect(info.commands.length == 6 && info.commands[1] == MAIN,
			"command order");
		expect(info.dylibs.length == 1 &&
			info.dylibs[0] == "/usr/lib/libSystem.B.dylib", "library spelling");
		expect(info.dylinker == "/usr/lib/dyld" && info.installName == null,
			"loader and install name");
		if (info.build == null) { throw new Error("missing build version"); }
		expect(info.build.platform == 1 && info.build.minimumVersion == 0xb0000,
			"build fields");
		expect(info.sections.length == 1 &&
			info.sections[0].segment == "__TEXT" &&
			info.sections[0].name == "__unwind_info", "section identity");
		const empty = accepted(image(cpu, []));
		expect(empty.commands.length == 0 && empty.build == null, "empty table");
		for (const at of [16, 20, 36]) {
			const bad = Buffer.copy(standard);
			put(bad, at, 0xffffffff);
			refused(bad, at == 36 ? "command size" : "command table");
		}
		for (const size of [0, 4, 12, 0x1000]) {
			const bad = Buffer.copy(standard);
			put(bad, 36, size as uint32);
			refused(bad, "command size");
		}
		const partial = Buffer.concat(standard, Buffer.alloc(8));
		put(partial, 20, (standard.length - 24) as uint32);
		refused(partial, "cover sizeofcmds");
		let allRejected = true;
		for (let length: int32 = 0; length < standard.length; length += 1) {
			if (parseMachO(standard[0..length]).ok) { allRejected = false; }
		}
		expect(allRejected, "proper prefix was accepted");
		cases += 1;
	}
	const unknown = accepted(image(0x81234567, [command(0xeeeeeeee, 8)], 6));
	expect(unknown.cpuType == 0x81234567 && unknown.fileType == 6 &&
		unknown.commands[0] == 0xeeeeeeee, "raw unsigned metadata");
	const libs: Buffer[] = [];
	for (const kind of [LOAD, 0x20, 0x80000018, 0x8000001f, 0x80000023]) {
		libs.push(named(kind as uint32, "/é日本🚀.dylib"));
	}
	const names = accepted(image(ARM64, libs));
	expect(names.dylibs.length == 5 && names.dylibs[4] == "/é日本🚀.dylib",
		"UTF-8 libraries or supported command kinds");
	const identity = accepted(image(X64, [named(ID, "@rpath/libtest.dylib")], 6));
	expect(identity.installName == "@rpath/libtest.dylib", "install name");
	const tools = accepted(image(X64, [build(1)]));
	expect(tools.build != null, "build tools rejected");
	const exact = segment();
	fixedName(exact, 72, "abcdefghijklmnop");
	expect(accepted(image(X64, [exact])).sections[0].name ==
		"abcdefghijklmnop", "full-width section name");
	const data = image(X64, [named(LOAD, "original"), segment()]);
	const host = Buffer.concat(Buffer.alloc(9), Buffer.concat(data,
		Buffer.alloc(7)));
	const view = accepted(host[9..9 + data.length]);
	data[0] = 0;
	for (let i: int32 = 9; i < host.length; i += 1) { host[i] = 0; }
	expect(view.dylibs[0] == "original" &&
		view.sections[0].name == "__unwind_info", "result aliases input");
	refused(Buffer.alloc(0), "64-bit");
	refused(Buffer.alloc(31), "64-bit");
	for (const magic of [0xcffaedfe, 0xcafebabe, 0xfeedface, 0]) {
		const bad = image(X64, []);
		put(bad, 0, magic as uint32);
		refused(bad, "64-bit");
	}
	for (const kind of [ID, DYLD, BUILD]) {
		const item = kind == BUILD ? build() : named(kind, "name");
		refused(image(X64, [item, item]), "duplicate");
	}
	for (const offset of [0, 8, 23, 32, 0xffffffff]) {
		const bad = named(LOAD, "abc");
		put(bad, 8, offset as uint32);
		refused(image(X64, [bad]), "library name");
	}
	const unterminated = named(LOAD, "abc");
	for (let i: int32 = 24; i < unterminated.length; i += 1) {
		unterminated[i] = 97;
	}
	refused(image(X64, [unterminated]), "library name");
	const malformed = named(LOAD, "ab");
	malformed[24] = 0xc3;
	malformed[25] = 0x28;
	refused(image(X64, [malformed]), "UTF-8");
	refused(image(X64, [command(LOAD, 16)]), "library name");
	const badTools = build();
	put(badTools, 20, 0xffffffff);
	refused(image(X64, [badTools]), "build tools");
	refused(image(X64, [command(BUILD, 16)]), "build version");
	refused(image(X64, [command(SEGMENT, 64)]), "segment");
	const badSections = segment();
	put(badSections, 64, 2);
	refused(image(X64, [badSections, command(0x1234, 88)]), "section table");
	put(badSections, 64, 0xffffffff);
	refused(image(X64, [badSections]), "section table");
	const nonAscii = segment();
	nonAscii[72] = 0x80;
	refused(image(X64, [nonAscii]), "ASCII");
	console.log("Mach-O images: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
