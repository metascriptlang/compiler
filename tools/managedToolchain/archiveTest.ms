import { ArchiveMember, parseArchive } from "./archive";

const MAGIC = Buffer.fromString("!<arch>\n", "utf8");
let cases: int32 = 0;

function bytes(text: string): Buffer {
	return Buffer.fromString(text, "utf8");
}

function member(name: string, body: Buffer): Buffer {
	if (name.length > 16) { throw new Error("fixture name exceeds header"); }
	const header = name.padEnd(16, " ") + "0".padEnd(12, " ") +
		"0".padEnd(6, " ") + "0".padEnd(6, " ") +
		"100644".padEnd(8, " ") + String(body.length).padEnd(10, " ") + "`\n";
	let encoded = Buffer.concat(bytes(header), body);
	if (body.length % 2 != 0) { encoded = Buffer.concat(encoded, bytes("\n")); }
	return encoded;
}

function bsdMember(name: string, body: Buffer): Buffer {
	const encoded = bytes(name);
	while (encoded.length % 8 != 0) { encoded.push(0); }
	return member("#1/" + String(encoded.length), Buffer.concat(encoded, body));
}

function archive(parts: Buffer[]): Buffer {
	let data = Buffer.copy(MAGIC);
	for (const part of parts) { data = Buffer.concat(data, part); }
	return data;
}

function truncated(data: Buffer, count: int32): Buffer {
	const copy = Buffer.copy(data);
	copy.length = copy.length - count;
	return copy;
}

function expectMembers(data: Buffer, expected: ArchiveMember[]): void {
	const parsed = parseArchive(data);
	if (!parsed.ok) { throw new Error(parsed.error); }
	if (parsed.value.length != expected.length) {
		throw new Error("archive member count differs");
	}
	for (let i: int32 = 0; i < expected.length; i += 1) {
		const actual = parsed.value[i];
		if (actual.name != expected[i].name ||
			Buffer.compare(actual.data, expected[i].data) != 0) {
			throw new Error("archive member differs: " + String(i));
		}
	}
	cases += 1;
}

function expectRefusal(data: Buffer, expectedFragment: string): void {
	const parsed = parseArchive(data);
	if (parsed.ok) { throw new Error("accepted malformed archive"); }
	if (parsed.error.indexOf(expectedFragment) < 0) {
		throw new Error("unexpected archive refusal: " + parsed.error);
	}
	cases += 1;
}

when (!testBuild) {
	expectMembers(MAGIC, []);
	expectMembers(archive([
		member("/", [0, 0, 0, 0]),
		member("//", bytes("/private/tmp/cache/closedir.o/\n")),
		member("/0", [0, 255, 127]),
		member("short.o/", bytes("even")),
	]), [
		{ name: "/private/tmp/cache/closedir.o", data: [0, 255, 127] },
		{ name: "short.o", data: bytes("even") },
	]);
	expectMembers(archive([
		bsdMember("long-object-name.o", bytes("odd")),
		member("short.o", bytes("even")),
	]), [
		{ name: "long-object-name.o", data: bytes("odd") },
		{ name: "short.o", data: bytes("even") },
	]);
	for (const name of ["高.o", "🚀.o", "\uFEFFname.o", "\uFFFD.o"]) {
		expectMembers(archive([bsdMember(name, [0, 255, 0])]), [
			{ name, data: [0, 255, 0] },
		]);
	}
	expectMembers(archive([
		member("//", bytes("café.o/\n")), member("/0", bytes("data")),
	]), [{ name: "café.o", data: bytes("data") }]);
	for (const name of [
		"__.SYMDEF", "__.SYMDEF SORTED", "__.SYMDEF_64", "__.SYMDEF_64 SORTED",
	]) {
		expectMembers(archive([
			bsdMember(name, bytes("index")),
			bsdMember("object.o", bytes("object")),
		]), [{ name: "object.o", data: bytes("object") }]);
	}
	expectMembers(archive([
		member("__.SYMDEF", bytes("index")),
		bsdMember("__.SYMDEF_extra.o", bytes("ordinary")),
	]), [{ name: "__.SYMDEF_extra.o", data: bytes("ordinary") }]);
	expectMembers(archive([
		bsdMember("dup.o", bytes("first")),
		bsdMember("dup.o", bytes("second")),
	]), [
		{ name: "dup.o", data: bytes("first") },
		{ name: "dup.o", data: bytes("second") },
	]);
	expectMembers(archive([
		member("/SYM64/", [0, 0]), member("zero.o/", []),
	]), [{ name: "zero.o", data: [] }]);
	for (const invalid of [
		{ data: member("#1/bad", bytes("name")), why: "BSD ar name length" },
		{ data: member("#1/0", bytes("object")), why: "BSD ar name length" },
		{ data: member("#1/20", bytes("short")), why: "BSD ar name length" },
		{ data: member("#1/4", [0, 0, 0, 0]), why: "invalid ar member name" },
		{ data: member("#1/4", [120, 0, 121, 0]), why: "invalid ar member name" },
		{ data: member("#1/1", [255, 111]), why: "not UTF-8" },
		{ data: member("/0", bytes("object")), why: "long name reference" },
		{ data: member("/unknown", bytes("object")), why: "unsupported ar member" },
		{ data: member(" bad.o/", bytes("x")), why: "invalid ar member name" },
		{ data: member("nu\0l.o/", bytes("x")), why: "invalid ar member name" },
		{ data: member("", bytes("x")), why: "invalid ar member name" },
	]) { expectRefusal(archive([invalid.data]), invalid.why); }
	for (const invalidName of [
		[192, 175], [237, 160, 128], [244, 144, 128, 128], [226, 130],
	]) {
		const raw: Buffer = [];
		for (const byte of invalidName) { raw.push(byte as uint8); }
		expectRefusal(archive([member("#1/" + String(raw.length), raw)]),
			"not UTF-8");
	}
	expectRefusal(archive([
		member("//", bytes("unterminated")), member("/0", bytes("object")),
	]), "long name reference");
	expectRefusal(archive([
		member("//", bytes("short.o/\n")), member("/100", bytes("object")),
	]), "long name reference");
	const names = bytes("short.o/\n");
	expectRefusal(archive([
		member("//", names), member("/" + String(names.length - 1), bytes("x")),
	]), "long name reference");
	expectRefusal(archive([truncated(member("odd.o/", bytes("odd")), 1)]),
		"truncated");
	expectRefusal(archive([truncated(member("a.o/", bytes("abc")), 2)]),
		"truncated");
	const oversized = member("large.o/", []);
	const hugeSize = bytes("9999999999");
	for (let i: int32 = 0; i < hugeSize.length; i += 1) {
		oversized[48 + i] = hugeSize[i];
	}
	expectRefusal(archive([oversized]), "truncated");
	expectRefusal(bytes("not an archive"), "not an ar archive");
	expectRefusal(bytes("!<thin>\n"), "not an ar archive");
	expectRefusal(archive([bytes("short header")]), "bad ar member header");
	const badHeader = member("bad.o/", bytes("x"));
	badHeader[58] = 0;
	expectRefusal(archive([badHeader]), "bad ar member header");
	const badSize = member("bad.o/", bytes("x"));
	badSize[48] = "x".code as uint8;
	expectRefusal(archive([badSize]), "bad ar member size");
	const nonAscii = member("bad.o/", bytes("x"));
	nonAscii[0] = 255;
	expectRefusal(archive([nonAscii]), "not ASCII");
	const mutable = archive([member("owned.o/", [1, 2, 3])]);
	const parsed = parseArchive(mutable);
	if (!parsed.ok) { throw new Error(parsed.error); }
	mutable[68] = 99;
	if (parsed.value[0].data[0] != 1) {
		throw new Error("archive result aliases the borrowed input");
	}
	cases += 1;
	console.log("GNU/BSD archive: " + String(cases) + " cases OK");
}
