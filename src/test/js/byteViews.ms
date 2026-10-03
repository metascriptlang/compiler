import { compileToC, compileProjectToJSWithStd, MapEntry } from "../helpers";

const PET = "struct P { a: uint32; b: uint8; }\nconst values: P[] = [{ a: 258, b: 2 }];\nlet value: P = { a: 258, b: 2 };\n";
const NO_BYTES = "no byte representation or recoverable typed location for this conversion";

function js(source: string): string {
	const entries: MapEntry[] = [{ entryPath: "test/byteViews.ms", entrySource: PET + source }];
	return compileProjectToJSWithStd(entries, "test/byteViews.ms");
}

function refused(source: string, conversion: string): boolean {
	const out = js(source);
	return out.startsWith("ERROR:") && out.includes(conversion + " on JS: " + NO_BYTES);
}

test "byteViews: a span cast through Ptr<void> to bytes is refused on JS" {
	assert refused("function read(v: Span<P>): uint8 { return (v as Ptr<void> as Ptr<uint8>)[0]; }\nconsole.log(read(values));\n",
		"cannot convert Span<P> to Ptr<void>");
}

test "byteViews: a byte view through an intermediate typed pointer is refused on JS" {
	assert refused("function read(v: Span<P>): uint8 { const p = v as Ptr<P>; return (p as Ptr<void> as Ptr<uint8>)[0]; }\nconsole.log(read(values));\n",
		"cannot convert Ptr<P> to Ptr<void>");
	assert refused("const p = value as Ptr<P>; console.log((p as Ptr<uint8>)[0]);\n", "cannot convert Ptr<P> to Ptr<uint8>");
}

test "byteViews: a reinterpret between typed scalar pointers is refused on JS" {
	assert refused("let ns: uint32[] = [258]; const v: Span<uint32> = ns; const p = v as Ptr<uint32>; console.log((p as Ptr<uint8>)[0]);\n",
		"cannot convert Ptr<uint32> to Ptr<uint8>");
}

test "byteViews: an integer is not a typed pointer on JS" {
	assert refused("function load(address: uint64): uint64 { const at = address as Ptr<uint64>; return at[]; }\nconsole.log(load(8));\n",
		"cannot convert uint64 to Ptr<uint64>");
}

test "byteViews: changing a span's element type is refused on JS" {
	const out = js("function read(v: Span<P>): uint8 { const bytes = v as Span<uint8>; return bytes[0]; }\nconsole.log(read(values));\n");
	assert out.startsWith("ERROR:") && out.includes("a view keeps its element type"), out.slice(0, 300);
}

test "byteViews: every spelling of the byte pointer type is refused on JS" {
	const raw = "const raw: Ptr<void> = value as Ptr<void>;\n";
	assert refused(raw + "type BytePtr = Ptr<uint8>;\nconsole.log((raw as BytePtr)[0]);\n", "cannot convert Ptr<void> to Ptr<uint8>");
	assert refused(raw + "console.log((raw as Readonly<Ptr<uint8>>)[0]);\n", "cannot convert Ptr<void> to Readonly<Ptr<uint8>>");
	assert refused(raw + "const b = raw as Ptr<uint8> | null; if (b != null) console.log(b[0]);\n", "cannot convert Ptr<void> to Ptr<uint8>");
	assert refused("class C { n: uint32 = 258; }\nconst u: unknown = new C(); console.log((u as Ptr<uint8>)[0]);\n", "cannot convert unknown to Ptr<uint8>");
}

test "byteViews: generic byte views are checked after instantiation on JS" {
	const raw = "const raw: Ptr<void> = value as Ptr<void>;\n";
	assert refused("function read<T>(p: Ptr<T>): uint8 { return (p as Ptr<void> as Ptr<uint8>)[0]; }\nconsole.log(read(value as Ptr<P>));\n",
		"cannot convert Ptr<P> to Ptr<void>");
	assert refused(raw + "function at<T>(p: Ptr<void>): T { const g = (): T => (p as Ptr<T>)[0]; return g(); }\nconsole.log(at<uint8>(raw));\n",
		"cannot convert Ptr<void> to Ptr<uint8>");
	assert refused(raw + "class Reader<T> { at(p: Ptr<void>): T { return (p as Ptr<T>)[0]; } }\nconsole.log(new Reader<uint8>().at(raw));\n",
		"cannot convert Ptr<void> to Ptr<uint8>");
}

test "byteViews: a generic byte view instantiated from another module is refused on JS" {
	const entries: MapEntry[] = [
		{ entryPath: "test/main.ms", entrySource: "import { at } from \"./lib\";\n" + PET + "const raw: Ptr<void> = value as Ptr<void>;\nconsole.log(at<uint8>(raw));\n" },
		{ entryPath: "test/lib.ms", entrySource: "export function at<T>(p: Ptr<void>): T { return (p as Ptr<T>)[0]; }\n" },
	];
	const out = compileProjectToJSWithStd(entries, "test/main.ms");
	assert out.startsWith("ERROR:") && out.includes("cannot convert Ptr<void> to Ptr<uint8> on JS"), out.slice(0, 300);
}

test "byteViews: a same-element span pointer compiles on JS" {
	const out = js("function first(v: Span<P>): uint32 { const p = v as Ptr<P>; return p[0].a; }\nconsole.log(first(values));\n");
	assert !out.startsWith("ERROR:"), out.slice(0, 300);
}

test "byteViews: a span of references is not a pointer to its objects on either backend" {
	const source = "class Row { value: uint32; constructor(value: uint32) { this.value = value; } }\nfunction read(v: Span<Row>): uint32 { const p = v as Ptr<Row>; return p.value; }\n";
	const c = compileToC(source);
	assert !c.ok;
	if (!c.ok) assert c.error.includes("the view stores reference slots"), c.error;
	const out = compileProjectToJSWithStd([{ entryPath: "test/rows.ms", entrySource: source }], "test/rows.ms");
	assert out.includes("the view stores reference slots"), out.slice(0, 300);
}

test "byteViews: pointer arithmetic and ordering are refused on JS" {
	const at = "let xs: uint8[] = [1, 2, 3]; let p = xs[0..3] as Ptr<uint8>; const q = xs[1..3] as Ptr<uint8>;\n";
	assert refusedOp(at + "console.log((p + 1)[0]);\n", "cannot apply '+' to a pointer");
	assert refusedOp(at + "console.log(q - p);\n", "cannot apply '-' to a pointer");
	assert refusedOp(at + "console.log(p < q);\n", "cannot apply '<' to a pointer");
	assert refusedOp(at + "p += 1; console.log(p[0]);\n", "cannot apply '+=' to a pointer");
	assert refusedOp(at + "console.log(p[1]);\n", "cannot index a pointer past the element it addresses");
	assert refusedOp(at + "let i = 0; console.log(p[i]);\n", "cannot index a pointer past the element it addresses");
}

test "byteViews: pointer identity and the first element stay legal on JS" {
	const out = js("let xs: uint8[] = [1, 2]; const p = xs[0..2] as Ptr<uint8>; const q = xs[0..1] as Ptr<uint8>;\nconsole.log(`${p == q} ${p[0]} ${p[]}`);\n");
	assert !out.startsWith("ERROR:"), out.slice(0, 300);
}

function refusedOp(source: string, refusal: string): boolean {
	const out = js(source);
	return out.startsWith("ERROR:") && out.includes(refusal + " on JS: a location there has no address arithmetic");
}
