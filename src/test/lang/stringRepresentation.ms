interface Pair { name: string; role: string; }

interface Container { fields: string[]; primary: string; }

function ownedStringBuild(): string {
	const buf: uint8[] = [];
	let i = 0;
	while (i < 64) {
		buf.push((65 + (i % 26)) as uint8);
		i = i + 1;
	}
	return buf.asString();
}

function temporaryStringJoined(): string {
	const a = "he";
	const b = "llo";
	return a + b;
}

function stringSpanCount(s: Span<char>): int32 {
	let n: int32 = 0;
	let i: int32 = 0;
	while (i < (s.length as int32)) {
		if ((s[i] as int32) == 99) { n = n + 1; }
		i = i + 1;
	}
	return n;
}

test "stringRepresentation: string MemberExpr === MemberExpr" {
	const u: Pair = { name: "alice", role: "admin" };
	const v: Pair = { name: "bob", role: "admin" };

	assert (u.name == v.name) == false;
	assert (u.role == v.role) == true;
	assert (u.name == u.name) == true;
}

test "stringRepresentation: Result.ok narrowing through if" {
	const r: Result<int32, string> = Result.ok(42 as int32);
	if (r.ok) {
		assert r.value == 42;
	} else {
		assert false;  
	}
}

test "stringRepresentation: Result.err narrowing through if" {
	const r: Result<int32, string> = Result.err("oops");
	if (r.ok) {
		assert false;  
	} else {
		assert r.error == "oops";
	}
}

test "stringRepresentation: string ArrayAccess === MemberExpr" {
	const c: Container = { fields: ["a", "b", "c"], primary: "b" };

	assert (c.fields[0] == c.primary) == false;
	assert (c.fields[1] == c.primary) == true;
	assert (c.fields[2] == c.primary) == false;
}

test "stringRepresentation: ArrayAccess === ArrayAccess across two arrays" {
	const a: string[] = ["x", "y", "z"];
	const b: string[] = ["x", "Y", "z"];
	assert (a[0] == b[0]) == true;
	assert (a[1] == b[1]) == false;
	assert (a[2] == b[2]) == true;
}

test "stringRepresentation: string byte views preserve contents for bound chained and empty consumers" {
	for (const text of ["", "abc", "hello"]) {
		const bytes = text.asBytes();
		assert bytes.length == text.length;
		assert bytes.asString() == text;
		assert text.asBytes().asString() == text;
		for (let i: int32 = 0; i < bytes.length; i++) assert bytes[i] == text.charCodeAt(i);
	}
	let sum: int32 = 0;
	for (const byte of "xyz".asBytes()) sum += byte as int32;
	assert sum == 363;
	const built: uint8[] = [];
	built.push(104);
	built.push(105);
	assert built.asString() == "hi";
}

test "stringRepresentation: byte push retains its width through capacity growth without changing numeric arrays" {
	const bytes: uint8[] = [];
	bytes.push(104);
	bytes.push(105);
	const high: uint8 = 200;
	bytes.push(high);
	for (let i: int32 = 0; i < 100; i++) bytes.push(i as uint8);
	assert bytes.length == 103;
	assert bytes[0] == 104 && bytes[1] == 105 && bytes[2] == 200;
	for (let i: int32 = 0; i < 100; i++) assert bytes[i + 3] == i;
	const numbers: float64[] = [];
	numbers.push(1.5);
	numbers.push(2.5);
	assert numbers[0] == 1.5 && numbers[1] == 2.5;
}

test "stringRepresentation: returned asString survives the builder scope" {
	const s1 = ownedStringBuild();
	const junk: uint8[] = [];
	let j = 0;
	while (j < 64) {
		junk.push(88);
		j = j + 1;
	}
	assert s1.length == 64;
	assert s1.charCodeAt(0) == 65;
	assert s1.charCodeAt(63) == 76;
	assert s1.charCodeAt(25) == 90;
}

test "stringRepresentation: asString result survives source realloc and heap reuse" {
	const buf: uint8[] = [];
	buf.push(104);
	buf.push(105);
	const s = buf.asString();
	let k = 0;
	while (k < 200) {
		buf.push(33);
		k = k + 1;
	}
	const spoil = "abc" + "d";
	assert spoil.length == 4;
	assert s.length == 2;
	assert s == "hi";
	assert s.charCodeAt(0) == 104;
}

test "stringRepresentation: asBytes on a concat rvalue receiver" {
	const rv = (temporaryStringJoined() + "!").asBytes();
	assert rv.length == 6;
	assert rv[0] == 104;
	assert rv[5] == 33;
}

test "stringRepresentation: asBytes on a direct call rvalue receiver" {
	const direct = temporaryStringJoined().asBytes();
	assert direct.length == 5;
	assert direct[4] == 111;
}

test "stringRepresentation: statement-position rvalue receiver still works" {
	(temporaryStringJoined() + "?").asBytes();
	assert temporaryStringJoined().length == 5;
}

test "stringRepresentation: string indexes and padding count UTF-16 units rather than encoded bytes" {
	const texts: string[] = ["axbxc", "héxlo", "a—xb", "日本語x", "👍x"];
	const lengths: int32[] = [5, 5, 4, 4, 3];
	const first: int32[] = [1, 2, 2, 3, 2];
	const last: int32[] = [3, 2, 2, 3, 2];
	for (let i: int32 = 0; i < texts.length; i++) {
		assert texts[i].length == lengths[i];
		assert texts[i].indexOf("x") == first[i];
		assert texts[i].lastIndexOf("x") == last[i];
		assert texts[i].padStart(6, ".") == ".".repeat(6 - lengths[i]) + texts[i];
		assert texts[i].padEnd(6, ".") == texts[i] + ".".repeat(6 - lengths[i]);
	}
}

test "stringRepresentation: byte search and byte slices count encoded bytes at their edges" {
	const s = "hello";
	const got = [
		s.byteIndexOf("l").toString(), s.byteIndexOf("l", 3).toString(), s.byteIndexOf("l", 4).toString(),
		s.byteIndexOf("", 2).toString(), s.byteIndexOf("o", -5).toString(), s.byteIndexOf("h", 9).toString(),
		s.byteLastIndexOf("l").toString(), s.byteLastIndexOf("l", 2).toString(), s.byteLastIndexOf("").toString(),
		s.byteLastIndexOf("hello!").toString(), s.byteSlice(1, 3), s.byteSlice(3, 99), s.byteSlice(2, 1),
		s.byteAt(1).toString(), s.byteAt(9).toString(), s.byteLength().toString(), "é".byteLength().toString(),
	].join(",");
	assert got == "2,3,-1,2,4,-1,3,2,5,-1,el,lo,,101,-1,5,2", got;
	assert "héxlo".byteIndexOf("x") == 3;
	assert "héxlo".byteLastIndexOf("l") == 4;
	assert "a,b,,c".split(",").join("|") == "a|b||c";
}

test "stringRepresentation: astral character indexing and slicing retain individual surrogate halves" {
	assert "👍x".charAt(1).charCodeAt(0) == 56397;
	assert "👍x"[1].charCodeAt(0) == 56397;
	assert "👍x".charAt(0).charCodeAt(0) == 55357;
	assert "héxlo"[1] == "é";
	const cut = "👍x".slice(1, 3);
	assert cut.charCodeAt(0) == 56397;
	assert cut.charCodeAt(1) == 120;
	assert "👍x".slice(0, 1).charCodeAt(0) == 55357;
}

test "stringRepresentation: string coerces to Span<char> and reads its bytes" {
	const txt = "hello";
	const chars: Span<char> = txt;
	assert (chars.length as int32) == 5;
	assert (chars[0] as int32) == 104;
	assert (chars[4] as int32) == 111;
}

test "stringRepresentation: string literal meets a Span<char> parameter" {
	assert stringSpanCount("accbc") == 3;
}

test "stringRepresentation: empty string yields an empty span, not a crash" {
	const empty = "";
	const none: Span<char> = empty;
	assert (none.length as int32) == 0;
}

test "stringRepresentation: slicing a string yields a span over its bytes" {
	const txt = "hello";
	const mid = txt[1..4];
	assert (mid.length as int32) == 3;
	assert (mid[0] as int32) == 101;
	assert (mid[2] as int32) == 108;
}

test "stringRepresentation: span over a heap-built string, and a slice of that span" {
	let built = "ab";
	built = built + "cdc";
	const s: Span<char> = built;
	assert (s.length as int32) == 5;
	assert stringSpanCount(built) == 2;
	const inner = s[1..3];
	assert (inner.length as int32) == 2;
	assert (inner[0] as int32) == 98;
}

test "stringRepresentation: Span<char> over a string walks with for..of" {
	const txt = "abc";
	const s: Span<char> = txt;
	let total: int32 = 0;
	for (const c of s) { total = total + (c as int32); }
	assert total == 294;
}
