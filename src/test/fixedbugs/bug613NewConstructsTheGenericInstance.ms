// bug613 — `new Box<int32>(…)` ran the generic class's own constructor on JS
//
// Symptom:    a generic class whose constructor calls a generic function over its own `T`
//             (`put(self, x)`, `put(this, x)`, `this.put(x)`, `identity(v)`) printed on C but threw
//             `ReferenceError: put__… is not defined` on JS (pinned by corpus 1018).
// Root cause: a class instance was only a name in `typeInstCache`; its ClassDecl and the `new`
//             callee kept the generic's symbol, so JS emitted `new Box__…` and ran the generic
//             body, whose calls name instances that are never made. C named the instance from the
//             expression's type.
// Fix:        an instance class gets its own symbol (`instantiatedFrom` the generic, cached once per
//             type arguments) and `new` binds its callee to it, as the reference constructs the
//             instance type, never the generic body.

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

test "bug613: new of a generic class constructs its instance, declared before the construction" {
	const js = emitted(header + "const b = new Box<int32>([1, 2]);\nconsole.log(b.items.length);\n");
	assert js.indexOf("ERROR", 0) < 0;
	const name = constructedClass(js, 0);
	assert name.contains("__int32");
	const decl = js.indexOf("class " + name + " ");
	assert decl >= 0;
	assert decl < js.indexOf("new " + name);
}

test "bug613: each type argument list constructs its own instance and a repeated one reuses it" {
	const js = emitted(header + "const a = new Box<int32>([1]);\nconst s = new Box<string>([\"x\"]);\nconst c = new Box<int32>([2]);\nconsole.log(a.items.length, s.items.length, c.items.length);\n");
	assert js.indexOf("ERROR", 0) < 0;
	const first = constructedClass(js, 0);
	const second = constructedClass(js, js.indexOf("new " + first) + 1);
	const third = constructedClass(js, js.indexOf("new " + second) + 1);
	assert first.contains("__int32") && second.contains("__string");
	assert third == first;
	assert js.indexOf("class " + first + " ") == js.lastIndexOf("class " + first + " ");
}
