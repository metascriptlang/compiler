import { MapEntry } from "../../module/loader";
import { compileProjectToCWithStd } from "../helpers";

const RESOLVE = `
enum Wrap { A, B }

struct Layer { wrap: Wrap; size: int32; inner: string; }

function wrapOne(layer: Layer, inner: string): string {
	return match (layer.wrap) {
		Wrap.A => inner + "[]",
		Wrap.B => "B<" + inner + ">",
	};
}

export function resolve(text: string): string {
	const layers: Layer[] = [];
	layers.push({ wrap: Wrap.A, size: 1, inner: text });
	layers.push({ wrap: Wrap.B, size: 2, inner: text + "x" });
	let t = text;
	for (let i = layers.length - 1; i >= 0; i -= 1) t = wrapOne(layers[i], t);
	return t;
}
`;

const GENERIC_RESOLVE = `
enum Wrap { A, B }

struct Layer<T> { wrap: Wrap; inner: T; }

function wrapOne(layer: Layer<string>, inner: string): string {
	return layer.wrap == Wrap.A ? inner + layer.inner : "B<" + inner + ">";
}

export function resolve(text: string): string {
	const layers: Layer<string>[] = [];
	layers.push({ wrap: Wrap.A, inner: text });
	layers.push({ wrap: Wrap.B, inner: text + "x" });
	let t = text;
	for (let i = layers.length - 1; i >= 0; i -= 1) t = wrapOne(layers[i], t);
	return t;
}
`;

const OUTER = `import { resolve } from "./a";

export function outer(text: string): string {
	return "<" + resolve(text) + ">";
}
`;

function emitted(c: string): boolean {
	return !c.startsWith("ERROR") && c.indexOf("outer", 0) >= 0;
}

test "a module whose routine calls into an importer not yet lowered summarizes it without its lifted hooks" {
	const entries: MapEntry[] = [
		{ entryPath: "/wbl/src/a.ms", entrySource: `import { outer } from "./b";\n${RESOLVE}\nconsole.log(outer("q"));\n` },
		{ entryPath: "/wbl/src/b.ms", entrySource: OUTER },
	];
	const c = compileProjectToCWithStd(entries, "/wbl/src/a.ms");
	assert emitted(c), c;
}

test "a routine two modules up a cycle is summarized before its module's hooks are lifted" {
	const entries: MapEntry[] = [
		{ entryPath: "/wbl3/src/a.ms", entrySource: `import { outer } from "./b";\n${RESOLVE}\nconsole.log(outer("q"));\n` },
		{ entryPath: "/wbl3/src/b.ms", entrySource: `import { mid } from "./c";\n\nexport function outer(text: string): string {\n\treturn "<" + mid(text) + ">";\n}\n` },
		{ entryPath: "/wbl3/src/c.ms", entrySource: `import { resolve } from "./a";\n\nexport function mid(text: string): string {\n\treturn resolve(text);\n}\n` },
	];
	const c = compileProjectToCWithStd(entries, "/wbl3/src/a.ms");
	assert emitted(c), c;
}

test "a generic struct's instance is summarized before its module's hooks are lifted" {
	const entries: MapEntry[] = [
		{ entryPath: "/wblg/src/a.ms", entrySource: `import { outer } from "./b";\n${GENERIC_RESOLVE}\nconsole.log(outer("q"));\n` },
		{ entryPath: "/wblg/src/b.ms", entrySource: OUTER },
	];
	const c = compileProjectToCWithStd(entries, "/wblg/src/a.ms");
	assert emitted(c), c;
}
