import { checkSource, strictErrorCount } from "./helpers";
import { compileToC, compileToCWithStd } from "../helpers";
import { lookupSymbol } from "../../checker/symbol";
import { unwrapRef } from "../../checker/types";

test "genericBinding: constructor type arguments come from either annotation side" {
	const cases = [
		{ name: "LHS-only annotation infers type args for new (Map)", source: "\ntype Handler = (s: string) => void;\nfunction main(): void {\n\tconst m: Map<string, Handler> = new Map();\n\tm.set(\"a\", (s) => {});\n\tconst _ok = m.has(\"a\");\n}\n", expected: 0 },
		{ name: "RHS-only type args still works", source: "\ntype Handler = (s: string) => void;\nfunction main(): void {\n\tconst m = new Map<string, Handler>();\n\tm.set(\"a\", (s) => {});\n\tconst _ok = m.has(\"a\");\n}\n", expected: 0 },
		{ name: "both-sides type args still works", source: "\ntype Handler = (s: string) => void;\nfunction main(): void {\n\tconst m: Map<string, Handler> = new Map<string, Handler>();\n\tm.set(\"a\", (s) => {});\n\tconst _ok = m.has(\"a\");\n}\n", expected: 0 },
		{ name: "LHS contextual mismatch still errors", source: "\nfunction main(): void {\n\tconst m: Map<string, int32> = new Set();\n}\n", expected: -1 },
		{ name: "Map<string, Function> with LHS-only annotation", source: "\ntype IntFn = (x: int32) => int32;\nfunction main(): void {\n\tconst ops: Map<string, IntFn> = new Map();\n\tops.set(\"dbl\", (x) => (x * 2) as int32);\n\tconst _ok = ops.has(\"dbl\");\n}\n", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "genericBinding: empty branch arrays acquire a concrete peer element type" {
	const cases = [
		{ name: "unannotated `cond ? xs : []` compiles to C with the concrete element type", source: "function f(flag: boolean, xs: number[]): number {\n\tconst picked = flag ? xs : [];\n\treturn picked.length;\n}\nfunction main(): void { console.log(f(true, [1])); }\n", expected: 0 },
		{ name: "mirrored branches `cond ? [] : xs` also adopt the concrete type", source: "function f(flag: boolean, xs: number[]): number {\n\tconst picked = flag ? [] : xs;\n\treturn picked.length;\n}\nfunction main(): void { console.log(f(false, [1])); }\n", expected: 0 },
		{ name: "both-empty ternary is a located checker error, not an internal one", source: "function f(flag: boolean): number {\n\tconst both = flag ? [] : [];\n\treturn both.length;\n}\n", expected: -1 },
		{ name: "bare empty array decl without annotation is a located checker error", source: "function main(): void {\n\tconst x = [];\n\tx.push(1);\n}\n", expected: -1 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
		if (!result.ok) {
			assert result.error.contains("cannot infer the element type"), item.name + ": " + result.error;
			assert !result.error.contains("internal:"), item.name + ": " + result.error;
		}
	}
}

test "genericBinding: open generic function fields infer through nullable payloads" {
	const cases = [
		{ name: "a generic callee binds its type parameter to props carrying a nullable function of T", source: "\nfunction comp<P>(C: (props: P) => number, props: P): number { return C(props); }\nfunction widgetNullableFn<T>(props: { each: () => T[]; key?: ((item: T) => number) | null }): number { return props.each().length as number; }\nfunction widgetNullableParam<T>(props: { each: () => T[]; key: T | null }): number { return props.each().length as number; }\nfunction widgetRequiredFn<T>(props: { each: () => T[]; key: (item: T) => number }): number { return props.each().length as number; }\nfunction widgetConcreteFn<T>(props: { each: () => T[]; key?: ((item: int32) => number) | null }): number { return props.each().length as number; }\nfunction takesNullableFn(f: ((item: int32) => number) | null): number { return f == null ? 0 : f(1); }\nfunction main(): void { console.log(comp(widgetNullableFn, { each: () => [1, 2] }).toString()); }", expected: 0 },
		{ name: "the same holds when the nullable field is the type parameter itself", source: "\nfunction comp<P>(C: (props: P) => number, props: P): number { return C(props); }\nfunction widgetNullableFn<T>(props: { each: () => T[]; key?: ((item: T) => number) | null }): number { return props.each().length as number; }\nfunction widgetNullableParam<T>(props: { each: () => T[]; key: T | null }): number { return props.each().length as number; }\nfunction widgetRequiredFn<T>(props: { each: () => T[]; key: (item: T) => number }): number { return props.each().length as number; }\nfunction widgetConcreteFn<T>(props: { each: () => T[]; key?: ((item: int32) => number) | null }): number { return props.each().length as number; }\nfunction takesNullableFn(f: ((item: int32) => number) | null): number { return f == null ? 0 : f(1); }\nfunction main(): void { console.log(comp(widgetNullableParam, { each: () => [1, 2], key: 3 }).toString()); }", expected: 0 },
		{ name: "supplying the nullable function at the call site still binds", source: "\nfunction comp<P>(C: (props: P) => number, props: P): number { return C(props); }\nfunction widgetNullableFn<T>(props: { each: () => T[]; key?: ((item: T) => number) | null }): number { return props.each().length as number; }\nfunction widgetNullableParam<T>(props: { each: () => T[]; key: T | null }): number { return props.each().length as number; }\nfunction widgetRequiredFn<T>(props: { each: () => T[]; key: (item: T) => number }): number { return props.each().length as number; }\nfunction widgetConcreteFn<T>(props: { each: () => T[]; key?: ((item: int32) => number) | null }): number { return props.each().length as number; }\nfunction takesNullableFn(f: ((item: int32) => number) | null): number { return f == null ? 0 : f(1); }\nfunction main(): void { console.log(comp(widgetNullableFn, { each: () => [1, 2], key: (item: int32): number => item }).toString()); }", expected: 0 },
		{ name: "a required function of T and a nullable function of a concrete type keep binding", source: "\nfunction comp<P>(C: (props: P) => number, props: P): number { return C(props); }\nfunction widgetNullableFn<T>(props: { each: () => T[]; key?: ((item: T) => number) | null }): number { return props.each().length as number; }\nfunction widgetNullableParam<T>(props: { each: () => T[]; key: T | null }): number { return props.each().length as number; }\nfunction widgetRequiredFn<T>(props: { each: () => T[]; key: (item: T) => number }): number { return props.each().length as number; }\nfunction widgetConcreteFn<T>(props: { each: () => T[]; key?: ((item: int32) => number) | null }): number { return props.each().length as number; }\nfunction takesNullableFn(f: ((item: int32) => number) | null): number { return f == null ? 0 : f(1); }\nfunction main(): void { console.log(comp(widgetRequiredFn, { each: () => [1, 2], key: (item: int32): number => item }).toString()); }", expected: 0 },
		{ name: "a required function of T and a nullable function of a concrete type keep binding", source: "\nfunction comp<P>(C: (props: P) => number, props: P): number { return C(props); }\nfunction widgetNullableFn<T>(props: { each: () => T[]; key?: ((item: T) => number) | null }): number { return props.each().length as number; }\nfunction widgetNullableParam<T>(props: { each: () => T[]; key: T | null }): number { return props.each().length as number; }\nfunction widgetRequiredFn<T>(props: { each: () => T[]; key: (item: T) => number }): number { return props.each().length as number; }\nfunction widgetConcreteFn<T>(props: { each: () => T[]; key?: ((item: int32) => number) | null }): number { return props.each().length as number; }\nfunction takesNullableFn(f: ((item: int32) => number) | null): number { return f == null ? 0 : f(1); }\nfunction main(): void { console.log(comp(widgetConcreteFn, { each: () => [1, 2] }).toString()); }", expected: 0 },
		{ name: "a nullable payload that does not fit is still refused", source: "\nfunction comp<P>(C: (props: P) => number, props: P): number { return C(props); }\nfunction widgetNullableFn<T>(props: { each: () => T[]; key?: ((item: T) => number) | null }): number { return props.each().length as number; }\nfunction widgetNullableParam<T>(props: { each: () => T[]; key: T | null }): number { return props.each().length as number; }\nfunction widgetRequiredFn<T>(props: { each: () => T[]; key: (item: T) => number }): number { return props.each().length as number; }\nfunction widgetConcreteFn<T>(props: { each: () => T[]; key?: ((item: int32) => number) | null }): number { return props.each().length as number; }\nfunction takesNullableFn(f: ((item: int32) => number) | null): number { return f == null ? 0 : f(1); }\nfunction main(): void { console.log(takesNullableFn((item: string): number => 1).toString()); }", expected: -1 },
	];
	for (const item of cases) {
		const result = compileToCWithStd(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "genericBinding: generic binding preserves readonly capability per instantiation" {
	const cases = [
		{ name: "a view passes through a generic identity", source: "\ninterface N { k: int32; }\nfunction id<T>(x: T): T { return x; }\nfunction pushG<T>(arr: T[], v: T): void { arr.push(v); }\nfunction first<T>(arr: T[]): T { return arr[0]; }\nfunction u(ro: Readonly<N>): int32 { const r = id(ro); return r.k; }", expected: 0 },
		{ name: "a view pushes into an array of views through a generic", source: "\ninterface N { k: int32; }\nfunction id<T>(x: T): T { return x; }\nfunction pushG<T>(arr: T[], v: T): void { arr.push(v); }\nfunction first<T>(arr: T[]): T { return arr[0]; }\nfunction u(ro: Readonly<N>): int32 { const xs: Readonly<N>[] = []; pushG(xs, ro); return xs.length; }", expected: 0 },
		{ name: "a generic result read from an array of views stays read-only", source: "\ninterface N { k: int32; }\nfunction id<T>(x: T): T { return x; }\nfunction pushG<T>(arr: T[], v: T): void { arr.push(v); }\nfunction first<T>(arr: T[]): T { return arr[0]; }\nfunction u(ros: Readonly<N>[]): void { first(ros).k = 5; }", expected: -1 },
		{ name: "a generic result read from an array of views does not convert back", source: "\ninterface N { k: int32; }\nfunction id<T>(x: T): T { return x; }\nfunction pushG<T>(arr: T[], v: T): void { arr.push(v); }\nfunction first<T>(arr: T[]): T { return arr[0]; }\nfunction u(ros: Readonly<N>[]): N { return first(ros); }", expected: -1 },
		{ name: "a mutable instance after a view instance stays writable", source: "\ninterface N { k: int32; }\nfunction id<T>(x: T): T { return x; }\nfunction pushG<T>(arr: T[], v: T): void { arr.push(v); }\nfunction first<T>(arr: T[]): T { return arr[0]; }\nfunction u(ro: Readonly<N>): int32 { return id(ro).k; }\nfunction p(n: N): int32 { const r = id(n); r.k = 5; return r.k; }", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "genericBinding: alias substitution uses the declared body" {
	const cases = [
		{ name: "a constrained alias instance accepts a literal of its substituted shape", source: "type Box<T extends number> = { value: T };\nconst b: Box<int32> = { value: 42 };\n", expected: 0 },
		{ name: "a second, unconstrained parameter substitutes beside a constrained one", source: "type Pair<K extends string, V> = { k: K; v: V };\nconst p: Pair<string, int32> = { k: \"a\", v: 3 };\n", expected: 0 },
		{ name: "the substituted body still refuses a field of another type", source: "type Box<T extends number> = { value: T };\nconst b: Box<int32> = { value: \"x\" };\n", expected: -1 },
		{ name: "an alias whose body ignores its parameter keeps the body", source: "type Phantom<T> = int32;\nconst x: Phantom<boolean> = 3;\nconst y: Phantom<string> = x + 1;\n", expected: 0 },
		{ name: "an alias whose body ignores its parameter keeps the body", source: "type Label<T> = string;\nfunction name(l: Label<int32>): string { return l + \"!\"; }\nconst n = name(\"a\");\n", expected: 0 },
		{ name: "an alias whose body names a class is that class at every slot", source: "class Plain { n: int32 = 7; }\ntype Alias<T> = Plain;\nconst a: Alias<string> = new Plain();\nconst p: Plain = a;\n", expected: 0 },
		{ name: "an alias whose body names a class is that class at every slot", source: "class Plain { n: int32 = 7; }\ntype Alias<T> = Plain;\nfunction f(x: Alias<boolean>): int32 { return x.n; }\nconst n = f(new Plain());\n", expected: 0 },
		{ name: "an alias whose body names a class is that class at every slot", source: "class Plain { n: int32 = 7; }\ntype Alias<T> = Plain;\nfunction mk(): Alias<int32> { return new Plain(); }\nconst c: Alias<string> = mk();\n", expected: 0 },
		{ name: "an alias whose body names a struct is that struct", source: "struct Pt { x: int32; y: int32; }\ntype P<T> = Pt;\nfunction mkPt(): Pt { return { x: 1, y: 2 }; }\nconst p: P<string> = mkPt();\nfunction back(): P<int32> { return p; }\nconst q: Pt = back();\n", expected: 0 },
		{ name: "an alias whose body instantiates another generic is that instance", source: "class Holder<T> { v: T; constructor(v: T) { this.v = v; } }\ntype Box<T> = Holder<T>;\nconst b: Box<string> = new Holder<string>(\"x\");\nfunction g(h: Box<string>): string { return h.v; }\nconst s: string = g(b);\n", expected: 0 },
		{ name: "an alias whose body instantiates another generic is that instance", source: "class Holder<T> { v: T; constructor(v: T) { this.v = v; } }\ntype Box<T> = Holder<T>;\nconst w: Box<int32> = new Holder<string>(\"x\");\n", expected: 1 },
		{ name: "a generic struct instance fills a std HashMap value", source: "struct Cell<T> { v: T; }\nconst m = new HashMap<string, Cell<int32> >();\nm.set(\"a\", { v: 1 as int32 });\nconst n: number = m.size;\n", expected: 0 },
		{ name: "a generic struct instance fills a std Map value", source: "struct Cell<T> { v: T; }\nconst m = new Map<string, Cell<string> >();\nm.set(\"a\", { v: \"x\" });\nconst n: number = m.size;\n", expected: 0 },
		{ name: "an alias of a generic instance fills a std HashMap value", source: "struct Cell<T> { v: T; }\ntype Boxed<T> = Cell<T>;\nconst m = new HashMap<string, Boxed<int32> >();\nm.set(\"a\", { v: 2 as int32 });\n", expected: 0 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "genericBinding: inferred and explicit type arguments both meet constraints" {
	const cases = [
		{ name: "an explicit or inferred binding that misses its constraint is refused", source: "interface Foo { zzqw: int32; }\ninterface Baz { other: string; }\nfunction getF<T extends Foo>(v: T): int32 { return v.zzqw; }\nfunction num<T extends number>(v: T): T { return v; }\nconst z: Baz = { other: \"x\" };\nconst a = getF<Baz>(z);\n", expected: -1 },
		{ name: "an explicit or inferred binding that misses its constraint is refused", source: "interface Foo { zzqw: int32; }\ninterface Baz { other: string; }\nfunction getF<T extends Foo>(v: T): int32 { return v.zzqw; }\nfunction num<T extends number>(v: T): T { return v; }\nconst z: Baz = { other: \"x\" };\nconst a = getF(z);\n", expected: -1 },
		{ name: "an explicit or inferred binding that misses its constraint is refused", source: "interface Foo { zzqw: int32; }\ninterface Baz { other: string; }\nfunction getF<T extends Foo>(v: T): int32 { return v.zzqw; }\nfunction num<T extends number>(v: T): T { return v; }\nconst s = num(\"str\");\n", expected: -1 },
		{ name: "a binding that meets its constraint stays accepted", source: "interface Foo { zzqw: int32; }\ninterface Baz { other: string; }\nfunction getF<T extends Foo>(v: T): int32 { return v.zzqw; }\nfunction num<T extends number>(v: T): T { return v; }\nconst f: Foo = { zzqw: 7 };\nconst a = getF(f);\nconst b = num(5 as int32);\n", expected: 0 },
		{ name: "a constrained class instantiates, reads through its constraint and checks `new`", source: "interface Fooc { zzqw: int32; }\ninterface Barc { other: string; }\nclass Box<T extends Fooc> {\n\tv: T;\n\tconstructor(v: T) { this.v = v; }\n\tget(): int32 { return this.v.zzqw; }\n}\nconst f: Fooc = { zzqw: 7 };\nconst b = new Box<Fooc>(f);\nconst n = b.get();\n", expected: 0 },
		{ name: "a constrained class instantiates, reads through its constraint and checks `new`", source: "interface Fooc { zzqw: int32; }\ninterface Barc { other: string; }\nclass Box<T extends Fooc> {\n\tv: T;\n\tconstructor(v: T) { this.v = v; }\n\tget(): int32 { return this.v.zzqw; }\n}\nconst z: Barc = { other: \"x\" };\nconst b = new Box<Barc>(z);\n", expected: -1 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "generic binding: an explicit covering type is not replaced by narrower arguments" {
	const pre = "class Animal { name: string = \"\"; } class Dog extends Animal { breed: string = \"\"; } function pair<T>(a: T, b: T): T { return a; } ";
	for (const arguments of ["new Dog(), new Dog()", "new Animal(), new Dog()", "new Dog(), new Animal()"]) {
		const ctx = checkSource(pre + "const result = pair<Animal>(" + arguments + ");");
		assert ctx != null && ctx.errors.length == 0;
		const result = lookupSymbol(ctx.table, "result");
		assert result != null;
		assert unwrapRef(result.symbolType).typeName == "Animal", arguments;
	}
}
