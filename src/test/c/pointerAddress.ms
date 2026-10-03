import { compileToC } from "../helpers";

function cError(source: string): string {
	const c = compileToC(source);
	return c.ok ? "compiled" : c.error;
}

test "pointerAddress: a const value's address is a read-only view" {
	const prefix = "struct S { n: int32; }\nfunction main(): void { const s: S = { n: 1 }; const p = s as Ptr<S>; ";
	assert cError(prefix + "console.log(`${p[].n}`); }\nmain();\n") == "compiled";
	assert cError(prefix + "p[].n = 2; }\nmain();\n").includes("cannot write through Readonly<Ptr<S>>");
}

test "pointerAddress: a value-type parameter's address is a read-only view" {
	const head = "struct Big { a: int64; b: int64; c: int64; d: int64; e: int64; }\n";
	assert cError(head + "function peek(s: Big): int64 { const p = s as Ptr<Big>; return p[].a; }\n") == "compiled";
	assert cError(head + "function bump(s: Big): void { const p = s as Ptr<Big>; p[].a = 99; }\n")
		.includes("cannot write through Readonly<Ptr<Big>>");
}

test "pointerAddress: an expression without a location has no address" {
	assert cError("struct S { n: int32; }\nfunction mk(): S { return { n: 5 }; }\nconst p = mk() as Ptr<S>;\n")
		.includes("expression has no address");
}

test "pointerAddress: an integer is the address it holds, never its own location" {
	const source = "struct Key { a: uint64; }\nfunction load(address: uint64): uint64 { const at = address as Ptr<uint64>; return at[]; }\n"
		+ "function key(address: uint64): Key { const at = address as Ptr<Key>; return at[]; }\n"
		+ "function past(address: uint64): Ptr<Key> { return (address + 96) as Ptr<Key>; }\n";
	const c = compileToC(source);
	assert c.ok, c.ok ? "" : c.error;
	if (c.ok) assert !c.value.contains("&(address"), "an integer source must not have its address taken";
}

test "pointerAddress: a heap container's handle is not its elements" {
	assert cError("function main(): void { let xs: uint8[] = [7, 8]; const p = xs as Ptr<uint8>; }\nmain();\n")
		.includes("is a handle to heap storage");
	assert cError("function main(): void { let s: string = \"AB\"; const p = s as Ptr<uint8>; }\nmain();\n")
		.includes("is a handle to heap storage");
	assert cError("function main(): void { let xs: uint8[] = [7, 8]; const p = xs as Ptr<uint8[]>; }\nmain();\n") == "compiled";
}

test "pointerAddress: a view keeps its element type" {
	assert cError("struct P { a: uint32; }\nfunction f(v: Span<P>): uint8 { const b = v as Span<uint8>; return b[0]; }\n")
		.includes("a view keeps its element type");
	assert cError("struct P { a: uint32; }\nfunction f(v: P[]): uint8 { const b = v as Span<uint8>; return b[0]; }\n")
		.includes("a view keeps its element type");
}

test "pointerAddress: a span of references is not a pointer to its objects" {
	const source = "class Row { value: uint32; constructor(value: uint32) { this.value = value; } }\nfunction read(v: Span<Row>): uint32 { const p = v as Ptr<Row>; return p.value; }\n";
	assert cError(source).includes("the view stores reference slots");
}

test "pointerAddress: a pointer to pointers is a double pointer in C" {
	const c = compileToC("struct S { n: int32; }\nfunction f(q: Ptr<S>): int32 { let local = q; const pq = local as Ptr<Ptr<S>>; return pq[].n; }\n");
	assert c.ok, c.ok ? "" : c.error;
	if (c.ok) assert c.value.contains("**"), "Ptr<Ptr<S>> must be a pointer to a pointer";
}
