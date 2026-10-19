import { checkProjectDiagnostics } from "../helpers";

function errors(source: string, text: string): int32 {
	let n: int32 = 0;
	for (const m of checkProjectDiagnostics([{ entryPath: "src/main.ms", entrySource: source }], "src/main.ms")) {
		if (m.indexOf(text) >= 0) n += 1;
	}
	return n;
}

const mismatch = "is not assignable to type 'function'";
const override = "an override keeps the ownership mode of every parameter";

test "sinkParamModes: a sink parameter compiles on a function, a method, a generic method and a constructor" {
	assert errors("function f(sink s: string): number { return s.length; }", "") == 0;
	assert errors("class K { items: string[] = []; push(sink v: string): void { this.items.push(v); } }", "") == 0;
	assert errors("class B<T> { items: T[] = []; push(sink v: T): void { this.items.push(v); } }", "") == 0;
	assert errors("export class H { text: string; constructor(sink text: string) { this.text = text; } }", "") == 0;
}

test "sinkParamModes: a sink function does not stand in for a plain function type and the reverse" {
	assert errors("function take(sink v: string): number { return 1; }\nconst f: (v: string) => number = take;", mismatch) == 1;
	assert errors("function take(v: string): number { return 1; }\nconst f: (sink v: string) => number = take;", mismatch) == 1;
	assert errors("class K { push(sink v: string): void { } }\nconst k = new K();\nconst f: (v: string) => void = k.push;", mismatch) == 1;
	assert errors("function take(sink v: string): number { return 1; }\nconst f: (sink v: string) => number = take;", mismatch) == 0;
	assert errors("function take(v: string): number { return 1; }\nconst f: (v: string) => number = take;", mismatch) == 0;
}

test "sinkParamModes: an override keeps the sink mode of every parameter" {
	assert errors("class A { push(v: string): void { } }\nclass B extends A { push(sink v: string): void { } }", override) == 1;
	assert errors("class A { push(sink v: string): void { } }\nclass B extends A { push(v: string): void { } }", override) == 1;
	assert errors("class A { push(sink v: string): void { } }\nclass B extends A { push(sink v: string): void { } }", override) == 0;
	assert errors("class A { push(v: string): void { } }\nclass B extends A { push(v: string): void { } }", override) == 0;
}
