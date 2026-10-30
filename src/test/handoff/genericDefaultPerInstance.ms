import { checkProjectDiagnostics } from "../helpers";

function refused(source: string, text: string): int32 {
	let n: int32 = 0;
	for (const m of checkProjectDiagnostics([{ entryPath: "src/main.ms", entrySource: source }], "src/main.ms")) {
		if (m.indexOf(text) >= 0) n += 1;
	}
	return n;
}

const k = "function k<T>(x: T, y: T = 300): T { return y; }\n";

test "genericDefaultPerInstance: a default that does not fit the instance's type is refused at the call" {
	assert refused(k + "const u: uint8 = 1;\nk(u);", "the default of parameter 'y' of 'k' does not fit this call, where 'y' is uint8") == 1;
	assert refused(k + "const s: int8 = 1;\nk(s);", "the default of parameter 'y' of 'k' does not fit this call, where 'y' is int8") == 1;
	assert refused("function d<T>(x: T, y: T = 2.75): T { return y; }\nconst n: int32 = 1;\nd(n);", "where 'y' is int32") == 1;
	assert refused("function two<A, B>(a: A, b: B, c: B = 300): B { return c; }\nconst u: uint8 = 1;\nconst w: int32 = 1;\ntwo(w, u);", "the default of parameter 'c' of 'two' does not fit this call, where 'c' is uint8") == 1;
	assert refused("function m<T>(y: T = 300): T { return y; }\nm<uint8>();", "where 'y' is uint8") == 1;
}

test "genericDefaultPerInstance: a default that fits the instance, or an argument in its place, is accepted" {
	assert refused(k + "const w: int32 = 1;\nk(w);", "the default of parameter") == 0;
	assert refused(k + "const u: uint8 = 1;\nk(u, 9 as uint8);", "the default of parameter") == 0;
	assert refused("function two<A, B>(a: A, b: B, c: B = 300): B { return c; }\nconst u: uint8 = 1;\nconst w: int32 = 1;\ntwo(u, w);", "the default of parameter") == 0;
}

test "genericDefaultPerInstance: an object literal default is built as each instance of a generic interface" {
	const opts = "interface Opts<C> { flag?: boolean | null; label?: ((value: C) => string) | null; }\n";
	assert refused(opts + "function make<C>(value: C, options: Opts<C> = {}): boolean { return options.flag ?? true; }\nmake<int32>(1);\nmake(\"s\");", "not assignable") == 0;
	assert refused(opts + "struct Box<P> { inner: P; }\nfunction wrap<C>(value: C, options: Opts<Box<C>> = { flag: false }): boolean { return options.flag ?? true; }\nwrap(1);", "not assignable") == 0;
}
