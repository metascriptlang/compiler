import { strictErrorCount } from "./helpers";
import { compileToC, compileToCWithStd, compileToJS } from "../helpers";

test "callableBoundaries: required callable fields cannot use value default initialization" {
	const cases = [
		{ name: "a missing function field is rejected", source: "\ninterface H { f: (n: number) => void; g: (n: number) => void; }\nfunction mk(): H {\n\treturn { f: (n: number): void => { console.log(n); } };\n}\nfunction main(): void { mk().g(1); }\n", expected: -1 },
		{ name: "a nullable function field may be omitted", source: "\ninterface H { f: (n: number) => void; g: ((n: number) => void) | null; }\nfunction mk(): H {\n\treturn { f: (n: number): void => { console.log(n); } };\n}\nfunction main(): void { mk().f(1); }\n", expected: 0 },
		{ name: "value fields retain default initialization", source: "\ninterface P { a: number; b: string; c: number[]; }\nfunction mk(): P { return { a: 1 }; }\nfunction main(): void { console.log(mk().a); }\n", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToCWithStd(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "callableBoundaries: expression arrows fit the contextual return type" {
	const cases = [
		{ name: "an expr-bodied arrow returning number into a string slot is a checker error", source: "\nfunction take(f: () => string): void {\n\tconsole.log(f());\n}\n\nfunction main(): void {\n\tconst n = (): number => 7;\n\ttake(() => n());\n}\n\nmain();\n", expected: -1 },
		{ name: "a value-returning expr arrow into a void slot still compiles", source: "\nfunction takeVoid(f: () => void): void {\n\tf();\n}\n\nfunction main(): void {\n\tlet a: int32[] = [];\n\ttakeVoid(() => a.push(1));\n}\n\nmain();\n", expected: 0 },
		{ name: "a legal widening through an expr arrow keeps its conversion", source: "\nfunction takeNum(f: () => number): void {\n\tconsole.log(f().toString());\n}\n\nfunction main(): void {\n\tconst j = (): int32 => 42;\n\ttakeNum(() => j());\n}\n\nmain();\n", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToCWithStd(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "callableBoundaries: call position requires a callable value or a resolved conversion function" {
	const cases = [
		{ name: "a void value in call position is a type error", source: "\nfunction mount(): void {}\nfunction main(): void {\n\tconst dispose = mount();\n\tdispose();\n}\n", expected: -1 },
		{ name: "a number value in call position is a type error", source: "function main(): void { const n: int32 = 1; n(); }\n", expected: -1 },
		{ name: "a string value in call position is a type error", source: "function main(): void { const s = \"a\"; s(); }\n", expected: -1 },
		{ name: "calling the void result of a call is a type error", source: "function mount(): void {}\nfunction main(): void { mount()(); }\n", expected: -1 },
		{ name: "a bound conversion function is callable after an explicit scalar cast", source: "\nfunction main(): void {\n\tconst x: float64 = 2.5;\n\tconst n = x as int32;\n\tconsole.log(String(n));\n}\n", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToCWithStd(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "callableBoundaries: implicit conversion cannot recursively reapply itself" {
	const cases = [
		{ name: "a converter does not apply inside its own body", source: "\ninterface Box { n: int32; }\nconverter boxToText(b: Box): string {\n\tconst t: string = b;\n\treturn t;\n}\nfunction main(): void {\n\tconst b: Box = { n: 1 };\n\tconst s: string = b;\n\tconsole.log(s);\n}\nmain();\n", expected: -1 },
		{ name: "valueOf does not apply inside its own body", source: "\ntype Acc = distinct (() => int32);\nfunction valueOf(this a: Acc): int32 {\n\tconst n: int32 = a;\n\treturn n;\n}\nfunction main(): void {\n\tconst a = (() => 5) as Acc;\n\tconst v: int32 = a;\n\tconsole.log(v);\n}\nmain();\n", expected: -1 },
		{ name: "another type's converter still applies inside the body", source: "\ninterface Inner { n: int32; }\ninterface Outer { inner: Inner; }\nconverter innerToText(i: Inner): string { return \"inner\"; }\nconverter outerToText(o: Outer): string {\n\tconst t: string = o.inner;\n\treturn t;\n}\nfunction main(): void {\n\tconst o: Outer = { inner: { n: 1 } };\n\tconst s: string = o;\n\tconsole.log(s);\n}\nmain();\n", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToCWithStd(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "callableBoundaries: method syntax retains the ordinary argument relation" {
	const cases0 = [
		{ name: "a plain call narrowing its argument is refused", source: "\nfunction extAt(this s: string, i: int32): int32 { return i; }\nfunction plainAt(s: string, i: int32): int32 { return i; }\nclass C { at(i: int32): int32 { return i; } }\nfunction pick(this s: string, i: int32): int32 { return i; }\nfunction pick(this n: int32, i: int32): int32 { return i; }\nconst pf: number = 1.5;\nconst pi: int32 = 1;\nplainAt(\"xy\", pf);", expected: -1 },
		{ name: "an extension call narrowing its argument is refused", source: "\nfunction extAt(this s: string, i: int32): int32 { return i; }\nfunction plainAt(s: string, i: int32): int32 { return i; }\nclass C { at(i: int32): int32 { return i; } }\nfunction pick(this s: string, i: int32): int32 { return i; }\nfunction pick(this n: int32, i: int32): int32 { return i; }\nconst pf: number = 1.5;\nconst pi: int32 = 1;\n\"xy\".extAt(pf);", expected: -1 },
		{ name: "an extension call with a mismatched argument is refused", source: "\nfunction extAt(this s: string, i: int32): int32 { return i; }\nfunction plainAt(s: string, i: int32): int32 { return i; }\nclass C { at(i: int32): int32 { return i; } }\nfunction pick(this s: string, i: int32): int32 { return i; }\nfunction pick(this n: int32, i: int32): int32 { return i; }\nconst pf: number = 1.5;\nconst pi: int32 = 1;\n\"xy\".extAt(\"s\");", expected: -1 },
		{ name: "a class method call narrowing its argument is refused", source: "\nfunction extAt(this s: string, i: int32): int32 { return i; }\nfunction plainAt(s: string, i: int32): int32 { return i; }\nclass C { at(i: int32): int32 { return i; } }\nfunction pick(this s: string, i: int32): int32 { return i; }\nfunction pick(this n: int32, i: int32): int32 { return i; }\nconst pf: number = 1.5;\nconst pi: int32 = 1;\nnew C().at(pf);", expected: -1 },
		{ name: "an overloaded extension call narrowing its argument is refused", source: "\nfunction extAt(this s: string, i: int32): int32 { return i; }\nfunction plainAt(s: string, i: int32): int32 { return i; }\nclass C { at(i: int32): int32 { return i; } }\nfunction pick(this s: string, i: int32): int32 { return i; }\nfunction pick(this n: int32, i: int32): int32 { return i; }\nconst pf: number = 1.5;\nconst pi: int32 = 1;\n\"xy\".pick(pf);", expected: -1 },
		{ name: "method-form calls with matching arguments compile", source: "\nfunction extAt(this s: string, i: int32): int32 { return i; }\nfunction plainAt(s: string, i: int32): int32 { return i; }\nclass C { at(i: int32): int32 { return i; } }\nfunction pick(this s: string, i: int32): int32 { return i; }\nfunction pick(this n: int32, i: int32): int32 { return i; }\nconst pf: number = 1.5;\nconst pi: int32 = 1;\n\"xy\".extAt(pi); new C().at(pi); \"xy\".pick(pi); console.log(pf);", expected: 0 },
	];
	for (const item of cases0) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
	const cases1 = [
		{ name: "a Ptr<T> receiver on a T extension is the free call's mismatch", source: "\nstruct S { n: int32; }\nfunction get(this x: S): int32 { return x.n; }\nfunction bump(this ref x: S): void { x.n = x.n + 1; }\nfunction mk(): S { return { n: 10 }; }\n\nfunction main(): int32 {\n\tlet arena: S[1] = [{ n: 10 }];\n\tconst ptr = arena[0] as Ptr<S>;\n\tconst s: S = { n: 10 };\n\tconsole.log(ptr.get());\n\treturn 0;\n}\nprocess.exit(main());\n", expected: -1 },
		{ name: "a Ptr<T> receiver on a T extension is the free call's mismatch", source: "\nstruct S { n: int32; }\nfunction get(this x: S): int32 { return x.n; }\nfunction bump(this ref x: S): void { x.n = x.n + 1; }\nfunction mk(): S { return { n: 10 }; }\n\nfunction main(): int32 {\n\tlet arena: S[1] = [{ n: 10 }];\n\tconst ptr = arena[0] as Ptr<S>;\n\tconst s: S = { n: 10 };\n\tconsole.log(get(ptr));\n\treturn 0;\n}\nprocess.exit(main());\n", expected: -1 },
		{ name: "a const receiver cannot pass a this ref receiver", source: "\nstruct S { n: int32; }\nfunction get(this x: S): int32 { return x.n; }\nfunction bump(this ref x: S): void { x.n = x.n + 1; }\nfunction mk(): S { return { n: 10 }; }\n\nfunction main(): int32 {\n\tlet arena: S[1] = [{ n: 10 }];\n\tconst ptr = arena[0] as Ptr<S>;\n\tconst s: S = { n: 10 };\n\ts.bump();\n\treturn 0;\n}\nprocess.exit(main());\n", expected: -1 },
		{ name: "a temporary cannot be a this ref receiver", source: "\nstruct S { n: int32; }\nfunction get(this x: S): int32 { return x.n; }\nfunction bump(this ref x: S): void { x.n = x.n + 1; }\nfunction mk(): S { return { n: 10 }; }\n\nfunction main(): int32 {\n\tlet arena: S[1] = [{ n: 10 }];\n\tconst ptr = arena[0] as Ptr<S>;\n\tconst s: S = { n: 10 };\n\tmk().bump();\n\treturn 0;\n}\nprocess.exit(main());\n", expected: -1 },
		{ name: "a value parameter cannot be a this ref receiver", source: "\nstruct S { n: int32; }\nfunction get(this x: S): int32 { return x.n; }\nfunction bump(this ref x: S): void { x.n = x.n + 1; }\nfunction mk(): S { return { n: 10 }; }\nfunction use(p: S): void { p.bump(); }\nfunction main(): int32 {\n\tlet arena: S[1] = [{ n: 10 }];\n\tconst ptr = arena[0] as Ptr<S>;\n\tconst s: S = { n: 10 };\n\tuse(s);\n\treturn 0;\n}\nprocess.exit(main());\n", expected: -1 },
		{ name: "ref this names the spelling this ref", source: "\nstruct S { n: int32; }\nfunction bump(ref this x: S): void { x.n = x.n + 1; }\n", expected: -1 },
		{ name: "a let receiver passes a this ref receiver", source: "\nstruct S { n: int32; }\nfunction get(this x: S): int32 { return x.n; }\nfunction bump(this ref x: S): void { x.n = x.n + 1; }\nfunction mk(): S { return { n: 10 }; }\n\nfunction main(): int32 {\n\tlet arena: S[1] = [{ n: 10 }];\n\tconst ptr = arena[0] as Ptr<S>;\n\tconst s: S = { n: 10 };\n\tlet v: S = { n: 1 }; v.bump(); console.log(v.n);\n\treturn 0;\n}\nprocess.exit(main());\n", expected: 0 },
	];
	for (const item of cases1) {
		const result = compileToCWithStd(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "callableBoundaries: static receivers do not shift explicit parameter modifiers" {
	const cases0 = [
		{ name: "a ref in the second position takes a variable beside a literal", source: "\nstruct Ctx { n: int32; }\nstruct R { k: int32; }\nclass Box { v: int32 = 0; }\nfunction seven(): int32 { return 7; }\nfunction fresh(): Ctx { return { n: 0 }; }\nfunction create(this typeof R, ref c: Ctx, k: int32): R {\n\tc.n = c.n + 1;\n\treturn { k: k };\n}\nfunction make(this typeof R, k: int32, name: string, ref c: Ctx): R {\n\tc.n = k;\n\treturn { k: k + name.length };\n}\nfunction split(this typeof R, out half: int32, k: int32): R {\n\thalf = k / 2;\n\treturn { k: k };\n}\nlet c: Ctx = { n: 0 };\nlet h: int32 = 0;\nR.create(c, 7);", expected: 0 },
		{ name: "a ref in the second position takes a variable beside a call", source: "\nstruct Ctx { n: int32; }\nstruct R { k: int32; }\nclass Box { v: int32 = 0; }\nfunction seven(): int32 { return 7; }\nfunction fresh(): Ctx { return { n: 0 }; }\nfunction create(this typeof R, ref c: Ctx, k: int32): R {\n\tc.n = c.n + 1;\n\treturn { k: k };\n}\nfunction make(this typeof R, k: int32, name: string, ref c: Ctx): R {\n\tc.n = k;\n\treturn { k: k + name.length };\n}\nfunction split(this typeof R, out half: int32, k: int32): R {\n\thalf = k / 2;\n\treturn { k: k };\n}\nlet c: Ctx = { n: 0 };\nlet h: int32 = 0;\nR.create(c, seven());", expected: 0 },
		{ name: "a ref in the third position takes a variable after a call and a literal", source: "\nstruct Ctx { n: int32; }\nstruct R { k: int32; }\nclass Box { v: int32 = 0; }\nfunction seven(): int32 { return 7; }\nfunction fresh(): Ctx { return { n: 0 }; }\nfunction create(this typeof R, ref c: Ctx, k: int32): R {\n\tc.n = c.n + 1;\n\treturn { k: k };\n}\nfunction make(this typeof R, k: int32, name: string, ref c: Ctx): R {\n\tc.n = k;\n\treturn { k: k + name.length };\n}\nfunction split(this typeof R, out half: int32, k: int32): R {\n\thalf = k / 2;\n\treturn { k: k };\n}\nlet c: Ctx = { n: 0 };\nlet h: int32 = 0;\nR.make(seven(), \"ab\", c);", expected: 0 },
		{ name: "the ref argument of a static extension still has to be a variable", source: "\nstruct Ctx { n: int32; }\nstruct R { k: int32; }\nclass Box { v: int32 = 0; }\nfunction seven(): int32 { return 7; }\nfunction fresh(): Ctx { return { n: 0 }; }\nfunction create(this typeof R, ref c: Ctx, k: int32): R {\n\tc.n = c.n + 1;\n\treturn { k: k };\n}\nfunction make(this typeof R, k: int32, name: string, ref c: Ctx): R {\n\tc.n = k;\n\treturn { k: k + name.length };\n}\nfunction split(this typeof R, out half: int32, k: int32): R {\n\thalf = k / 2;\n\treturn { k: k };\n}\nlet c: Ctx = { n: 0 };\nlet h: int32 = 0;\nR.create(fresh(), 7);", expected: -1 },
		{ name: "an out in the second position takes a variable beside a literal", source: "\nstruct Ctx { n: int32; }\nstruct R { k: int32; }\nclass Box { v: int32 = 0; }\nfunction seven(): int32 { return 7; }\nfunction fresh(): Ctx { return { n: 0 }; }\nfunction create(this typeof R, ref c: Ctx, k: int32): R {\n\tc.n = c.n + 1;\n\treturn { k: k };\n}\nfunction make(this typeof R, k: int32, name: string, ref c: Ctx): R {\n\tc.n = k;\n\treturn { k: k + name.length };\n}\nfunction split(this typeof R, out half: int32, k: int32): R {\n\thalf = k / 2;\n\treturn { k: k };\n}\nlet c: Ctx = { n: 0 };\nlet h: int32 = 0;\nR.split(h, 7);", expected: 0 },
		{ name: "a readonly parameter of a static extension refuses a write", source: "\nstruct Ctx { n: int32; }\nstruct R { k: int32; }\nclass Box { v: int32 = 0; }\nfunction seven(): int32 { return 7; }\nfunction fresh(): Ctx { return { n: 0 }; }\nfunction create(this typeof R, ref c: Ctx, k: int32): R {\n\tc.n = c.n + 1;\n\treturn { k: k };\n}\nfunction make(this typeof R, k: int32, name: string, ref c: Ctx): R {\n\tc.n = k;\n\treturn { k: k + name.length };\n}\nfunction split(this typeof R, out half: int32, k: int32): R {\n\thalf = k / 2;\n\treturn { k: k };\n}\nlet c: Ctx = { n: 0 };\nlet h: int32 = 0;\nfunction peek(this typeof R, readonly a: Box, b: Box): int32 { a.v = 1; return b.v; }", expected: -1 },
		{ name: "the parameter after a readonly one stays writable", source: "\nstruct Ctx { n: int32; }\nstruct R { k: int32; }\nclass Box { v: int32 = 0; }\nfunction seven(): int32 { return 7; }\nfunction fresh(): Ctx { return { n: 0 }; }\nfunction create(this typeof R, ref c: Ctx, k: int32): R {\n\tc.n = c.n + 1;\n\treturn { k: k };\n}\nfunction make(this typeof R, k: int32, name: string, ref c: Ctx): R {\n\tc.n = k;\n\treturn { k: k + name.length };\n}\nfunction split(this typeof R, out half: int32, k: int32): R {\n\thalf = k / 2;\n\treturn { k: k };\n}\nlet c: Ctx = { n: 0 };\nlet h: int32 = 0;\nfunction poke(this typeof R, readonly a: Box, b: Box): int32 { b.v = 1; return a.v; }", expected: 0 },
	];
	for (const item of cases0) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
	const cases1 = [
		{ name: "the JS backend takes a ref in the second and the third position", source: "\nstruct Ctx { n: int32; }\nstruct R { k: int32; }\nclass Box { v: int32 = 0; }\nfunction seven(): int32 { return 7; }\nfunction fresh(): Ctx { return { n: 0 }; }\nfunction create(this typeof R, ref c: Ctx, k: int32): R {\n\tc.n = c.n + 1;\n\treturn { k: k };\n}\nfunction make(this typeof R, k: int32, name: string, ref c: Ctx): R {\n\tc.n = k;\n\treturn { k: k + name.length };\n}\nfunction split(this typeof R, out half: int32, k: int32): R {\n\thalf = k / 2;\n\treturn { k: k };\n}\nlet c: Ctx = { n: 0 };\nlet h: int32 = 0;\nR.create(c, seven());\nR.make(7, \"ab\", c);", expected: 0 },
	];
	for (const item of cases1) {
		const result = compileToJS(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "callableBoundaries: stacked ownership modifiers preserve the underlying relation" {
	const cases = [
		{ name: "an unknown value pushes into an array of unknown", source: "\nclass Box { n: int32 = 0; }\nextern function keep<T>(sink v: T): void from \"keep\";\nextern function keepInt(sink v: int32): void from \"keepInt\";\nfunction make(): unknown { return new Box(); }\nconst items: unknown[] = [];\nitems.push(make());\n", expected: 0 },
		{ name: "an unknown value passes a sink unknown parameter", source: "\nclass Box { n: int32 = 0; }\nextern function keep<T>(sink v: T): void from \"keep\";\nextern function keepInt(sink v: int32): void from \"keepInt\";\nfunction make(): unknown { return new Box(); }\nkeep(make());\n", expected: 0 },
		{ name: "an unknown value still needs a cast for a sink int32 parameter", source: "\nclass Box { n: int32 = 0; }\nextern function keep<T>(sink v: T): void from \"keep\";\nextern function keepInt(sink v: int32): void from \"keepInt\";\nfunction make(): unknown { return new Box(); }\nkeepInt(make());\n", expected: -1 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "callableBoundaries: spread operands retain their full expression grammar" {
	const cases = [
		{ name: "a spread takes a call as its operand", source: "\nfunction arr(): int32[] { return [1, 2, 3]; }\nconst groups: int32[][] = [[1, 2]];\nconst s: int32[] = [...arr(), 4];\n", expected: 0 },
		{ name: "a spread takes a member call and an index as its operand", source: "\nfunction arr(): int32[] { return [1, 2, 3]; }\nconst groups: int32[][] = [[1, 2]];\nconst t: int32[] = [1, 2, 3];\nconst w: int32[] = [...t.slice(1, 2), ...groups[0]];\n", expected: 0 },
		{ name: "a literal made only of spreads takes its element type from them", source: "\nfunction arr(): int32[] { return [1, 2, 3]; }\nconst groups: int32[][] = [[1, 2]];\nconst base = arr();\nconst all = [...arr(), ...base];\nconst n: int32 = all[0];\n", expected: 0 },
		{ name: "a spread of a function value is still refused", source: "\nfunction arr(): int32[] { return [1, 2, 3]; }\nconst groups: int32[][] = [[1, 2]];\nconst f: int32[] = [...arr];\n", expected: -1 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "callableBoundaries: overload selection is not permission to bypass argument fitting" {
	const cases0 = [
		{ name: "a number argument does not pick an int32 overload", source: "function f(x: int32): string { return \"i\"; }\nfunction f(x: string): string { return x; }\nconst n: number = 3.7;\nconst r = f(n);\n", expected: -1 },
		{ name: "null is refused by the class overload it picked", source: "class Box { v: int32; constructor(v: int32) { this.v = v; } }\nfunction f(b: Box): string { return \"b\"; }\nfunction f(s: string): string { return s; }\nconst r = f(null);\n", expected: -1 },
		{ name: "a read-only view is refused by a mutable overload", source: "function clear(xs: int32[]): string { xs.push(9); return \"a\"; }\nfunction clear(s: string): string { return s; }\nfunction show(v: Readonly<int32[]>): string { return clear(v); }\n", expected: -1 },
		{ name: "a callback taking a subclass is refused for a base-class parameter", source: "class A { n: string; constructor(n: string) { this.n = n; } }\nclass D extends A { t: string; constructor(n: string) { super(n); this.t = \"t\"; } }\nfunction each(xs: A[], f: (a: A) => string): string { return \"\"; }\nfunction each(xs: string, f: (a: string) => string): string { return xs; }\nfunction onlyD(d: D): string { return d.t; }\nconst xs: A[] = [];\nconst r = each(xs, onlyD);\n", expected: -1 },
		{ name: "a negative literal does not match an unsigned overload", source: "function ov(x: uint32): string { return \"u\"; }\nfunction ov(x: string): string { return x; }\nconst r = ov(-1);\n", expected: -1 },
	];
	for (const item of cases0) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
	const cases1 = [
		{ name: "matching arguments still resolve and convert", source: "function f(x: int32): string { return \"i\"; }\nfunction f(x: string): string { return x; }\nconst a = f(3);\nconst b = f(\"s\");\nfunction g(x: int64): string { return \"l\"; }\nfunction g(x: string): string { return x; }\nconst i: int32 = 4;\nconst c = g(i);\n", expected: 0 },
	];
	for (const item of cases1) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "callableBoundaries: named functions fit closure signatures before adaptation" {
	const cases0 = [
		{ name: "a named function of another signature is refused for a closure parameter", source: "function named(s: string, flag: boolean): string { return flag ? s + \":T\" : s + \":F\"; }\nfunction apply(f: (s: string, i: number) => string): string { return f(\"a\", 1); }\nconst r = apply(named);\n", expected: -1 },
		{ name: "a generic callee refuses it too", source: "function named(s: string, flag: boolean): string { return flag ? s + \":T\" : s + \":F\"; }\nfunction applyG<T>(x: T, f: (s: T, i: number) => string): string { return f(x, 1); }\nconst r = applyG(\"a\", named);\n", expected: -1 },
		{ name: "a generic callee refuses it too", source: "function named(s: string, flag: boolean): string { return flag ? s + \":T\" : s + \":F\"; }\nconst xs: string[] = [\"a\", \"b\"];\nconst r = xs.map(named);\n", expected: -1 },
		{ name: "a closure-typed declaration refuses it", source: "function named(s: string, flag: boolean): string { return flag ? s + \":T\" : s + \":F\"; }\nconst f: (s: string, i: number) => string = named;\n", expected: -1 },
	];
	for (const item of cases0) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
	const cases1 = [
		{ name: "a named function of the same signature is still wrapped", source: "function named(s: string, i: number): string { return s + i.toString(); }\nfunction apply(f: (s: string, i: number) => string): string { return f(\"a\", 1); }\nfunction applyG<T>(x: T, f: (s: T, i: number) => string): string { return f(x, 1); }\nconst f: (s: string, i: number) => string = named;\nconst xs: string[] = [\"a\", \"b\"];\nconsole.log(apply(named) + applyG(\"b\", named) + xs.map(named).join(\",\") + f(\"c\", 3));\n", expected: 0 },
	];
	for (const item of cases1) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
	const cases2 = [
		{ name: "a named function of the same signature is still wrapped", source: "function named(s: string, i: number): string { return s + i.toString(); }\nfunction apply(f: (s: string, i: number) => string): string { return f(\"a\", 1); }\nfunction applyG<T>(x: T, f: (s: T, i: number) => string): string { return f(x, 1); }\nconst f: (s: string, i: number) => string = named;\nconst xs: string[] = [\"a\", \"b\"];\nconsole.log(apply(named) + applyG(\"b\", named) + xs.map(named).join(\",\") + f(\"c\", 3));\n", expected: 0 },
	];
	for (const item of cases2) {
		const result = compileToJS(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "callableBoundaries: constructor rest arguments fit the rest element" {
	const cases = [
		{ name: "constructor rest arguments fit the rest element", source: "class Summed {\n\ttotal: number;\n\tconstructor(base: number, ...rest: number[]) {\n\t\tlet t = base;\n\t\tfor (const n of rest) { t = t + n; }\n\t\tthis.total = t;\n\t}\n}\nclass Ints {\n\ttotal: int32 = 0;\n\tconstructor(...xs: int32[]) { for (const x of xs) this.total += x; }\n}\nconst a = new Summed(1, 2, 3);\nconst b = new Ints(1, 2, 3);\nconst c = new Ints();\n", expected: 0 },
		{ name: "a constructor rest argument of another element type is still refused", source: "class Summed {\n\ttotal: number;\n\tconstructor(base: number, ...rest: number[]) {\n\t\tlet t = base;\n\t\tfor (const n of rest) { t = t + n; }\n\t\tthis.total = t;\n\t}\n}\nclass Ints {\n\ttotal: int32 = 0;\n\tconstructor(...xs: int32[]) { for (const x of xs) this.total += x; }\n}\nconst d = new Ints(1, \"two\");\n", expected: -1 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "callable boundaries: a static receiver is absent from the extern argument list" {
	const cases = [
		{ declaration: "extern function lowest(this typeof R, k: int32 = -5): int32;", call: "R.lowest()", emitted: "lowest(-5)" },
		{ declaration: "extern function lowest(this typeof R, a: int32, k: int32 = -5): int32;", call: "R.lowest(1)", emitted: "lowest(1, -5)" },
	];
	for (const item of cases) {
		const c = compileToC("struct R { value: int32; } " + item.declaration + " const value: int32 = " + item.call + ";");
		assert c.ok, c.error;
		assert c.value.contains(item.emitted), item.call;
	}
}

test "callable boundaries: nullable closure slots fit signatures before wrapping" {
	const pre = "function named(s: string, flag: boolean): string { return s; } ";
	const rejected = [
		"const f: ((s: string, i: number) => string) | null = named;",
		"function pick(): ((s: string, i: number) => string) | null { return (s: string, flag: boolean): string => s; }",
	];
	for (const source of rejected) assert strictErrorCount(pre + source) > 0, source;
	assert strictErrorCount("function named(s: string, i: number): string { return s; } const f: ((s: string, i: number) => string) | null = named; const g: ((s: string, i: number) => string) | null = null;") == 0;
	const unwrapped = "type Compare = (a: int32, b: int32) => int32; function f(): void { const values = new Map<string, Compare>(); values.set(\"min\", (a, b) => (a < b ? a : b) as int32); const compare = values.get(\"min\"); console.log(compare(3, 7)); }";
	const c = compileToCWithStd(unwrapped);
	assert !c.ok;
}

test "callableBoundaries: an overload signature chosen by a method call is fitted to its implementation" {
	const cases = [
		{ name: "a signature whose receiver the implementation does not accept is refused", source: "\nstruct Account { address: uint64; }\nfunction key(this a: Account): uint64 { return a.address * 2; }\ntype Signer = distinct Account;\nfunction key(this s: Signer): uint64;\nconst a: Account = { address: 21 };\nconst k = (a as Signer).key();\n", refusal: "Overload signature for 'key' param 1 type 'Signer' not assignable to implementation param type 'Account'" },
		{ name: "signatures the implementation accepts are called through method syntax", source: "\nstruct A { v: int32; }\nstruct B { w: int32; }\nfunction show(this a: A): int32;\nfunction show(this b: B): int32;\nfunction show(this x: A | B): int32 { return 1; }\nconst a: A = { v: 1 };\nexport const shown: int32 = a.show();\n", refusal: "" },
	];
	for (const item of cases) {
		const result = compileToCWithStd(item.source);
		const error = result.ok ? "" : result.error;
		assert result.ok == (item.refusal == ""), item.name + ": " + error;
		assert item.refusal == "" || error.indexOf(item.refusal, 0) >= 0, item.name + ": " + error;
	}
}
