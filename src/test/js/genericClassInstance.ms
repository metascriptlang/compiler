import { compileProjectToJSWithStd, MapEntry } from "../helpers";

function emitted(src: string): string {
	const entries: MapEntry[] = [{ entryPath: "test/box.ms", entrySource: src }];
	return compileProjectToJSWithStd(entries, "test/box.ms");
}

function constructedClass(js: string, from: int32): string {
	const at = js.indexOf("new Box_", from);
	if (at < 0) return "";
	return js.slice(at + 4, js.indexOf("(", at));
}

const header = `class Box<T> {
	items: T[];
	constructor(xs: T[]) { this.items = []; const self: Box<T> = this; for (const x of xs) { put(self, x); } }
}
function put<T>(b: Box<T>, x: T): void { b.items.push(x); }
`;

test "genericClassInstance: new of a generic class constructs its instance, declared before the construction" {
	const js = emitted(header + "const b = new Box<int32>([1, 2]);\nconsole.log(b.items.length);\n");
	assert js.indexOf("ERROR", 0) < 0;
	const name = constructedClass(js, 0);
	assert name.contains("__int32");
	const decl = js.indexOf("class " + name + " ");
	assert decl >= 0;
	assert decl < js.indexOf("new " + name);
}

test "genericClassInstance: each type argument list constructs its own instance and a repeated one reuses it" {
	const js = emitted(header + "const a = new Box<int32>([1]);\nconst s = new Box<string>([\"x\"]);\nconst c = new Box<int32>([2]);\nconsole.log(a.items.length, s.items.length, c.items.length);\n");
	assert js.indexOf("ERROR", 0) < 0;
	const first = constructedClass(js, 0);
	const second = constructedClass(js, js.indexOf("new " + first) + 1);
	const third = constructedClass(js, js.indexOf("new " + second) + 1);
	assert first.contains("__int32") && second.contains("__string");
	assert third == first;
	assert js.indexOf("class " + first + " ") == js.lastIndexOf("class " + first + " ");
}
