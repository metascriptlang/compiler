export interface BundleUnit {
	code: string;
	runsOnLoad: boolean;
}

const DECLARATION_OPENERS: string[] = ["async function", "function*", "function", "class", "const", "let", "var"];

function isNameByte(b: int32): boolean {
	return (b >= "a".code && b <= "z".code) || (b >= "A".code && b <= "Z".code)
		|| (b >= "0".code && b <= "9".code) || b == "_".code || b == "$".code || b >= 128;
}

function lineEnd(code: string, from: int32): int32 {
	let i = from;
	while (i < code.byteLength && code.byteAt(i) != "\n".code) i += 1;
	return i;
}

function startsWithAt(code: string, at: int32, word: string): boolean {
	if (at + word.byteLength > code.byteLength) return false;
	for (let i: int32 = 0; i < word.byteLength; i += 1) {
		if (code.byteAt(at + i) != word.byteAt(i)) return false;
	}
	return true;
}

function declaredNameAt(code: string, lineStart: int32): string {
	for (const opener of DECLARATION_OPENERS) {
		if (!startsWithAt(code, lineStart, opener)) continue;
		let i = (lineStart + opener.byteLength) as int32;
		if (i >= code.byteLength || code.byteAt(i) != " ".code) continue;
		while (i < code.byteLength && code.byteAt(i) == " ".code) i += 1;
		const nameStart = i;
		while (i < code.byteLength && isNameByte(code.byteAt(i))) i += 1;
		return code.byteSlice(nameStart, i);
	}
	return "";
}

function continuesAStatement(b: int32): boolean {
	return b == " ".code || b == "\t".code || b == "\r".code || b == "}".code || b == ")".code
		|| b == "]".code || b == "/".code;
}

// The names a unit declares at column 0. `droppable` is false when the unit also holds text
// that is neither a declaration nor the continuation of one, because that text runs on load.
export function topLevelNames(code: string, names: string[]): boolean {
	let droppable = true;
	let lineStart: int32 = 0;
	while (lineStart < code.byteLength) {
		const end = lineEnd(code, lineStart);
		if (end > lineStart && !continuesAStatement(code.byteAt(lineStart))) {
			const name = declaredNameAt(code, lineStart);
			if (name == "") droppable = false;
			else names.push(name);
		}
		lineStart = (end + 1) as int32;
	}
	return droppable && names.length > 0;
}

function forEachName(code: string, visit: (name: string) => void): void {
	let i: int32 = 0;
	while (i < code.byteLength) {
		if (!isNameByte(code.byteAt(i))) {
			i += 1;
			continue;
		}
		const start = i;
		while (i < code.byteLength && isNameByte(code.byteAt(i))) i += 1;
		visit(code.byteSlice(start, i));
	}
}

// Which units a bundle keeps: every unit that runs on load, and every declaration a kept unit
// or one of `alwaysRead` (text outside the units: exports, the module evaluator) names.
export function liveUnits(units: BundleUnit[], alwaysRead: string[]): boolean[] {
	const live: boolean[] = [];
	const declaredBy = new HashMap<string, int32[]>();
	const pending: int32[] = [];
	for (let u: int32 = 0; u < units.length; u += 1) {
		const names: string[] = [];
		const droppable = !units[u].runsOnLoad && topLevelNames(units[u].code, names);
		live.push(!droppable && units[u].code != "");
		if (live[u]) pending.push(u);
		if (!droppable) continue;
		for (const name of names) {
			const owners = declaredBy.get(name);
			if (owners == null) declaredBy.set(name, [u]);
			else owners.push(u);
		}
	}
	const keep = (name: string): void => {
		const owners = declaredBy.get(name);
		if (owners == null) return;
		for (const owner of owners) {
			if (live[owner]) continue;
			live[owner] = true;
			pending.push(owner);
		}
	};
	for (const text of alwaysRead) forEachName(text, keep);
	while (pending.length > 0) {
		const u = pending.pop()!;
		forEachName(units[u].code, keep);
	}
	return live;
}

test "a declaration no kept unit names is dropped, and one named through another is kept" {
	const units: BundleUnit[] = [
		{ code: "function used() {\n  return helper();\n}\n", runsOnLoad: false },
		{ code: "function helper() {\n  return 1;\n}\n", runsOnLoad: false },
		{ code: "function unused() {\n  return helper();\n}\n", runsOnLoad: false },
		{ code: "console.log(used());\n", runsOnLoad: true },
	];
	const live = liveUnits(units, []);
	assert live[0] && live[1] && !live[2] && live[3];
}

test "text outside the units keeps what it names" {
	const units: BundleUnit[] = [
		{ code: "class Exported {\n}\n", runsOnLoad: false },
		{ code: "const TABLE = [1, 2];\n", runsOnLoad: false },
	];
	const live = liveUnits(units, ["export { Exported };\n"]);
	assert live[0] && !live[1];
}

test "a unit holding a statement beside its declaration runs on load" {
	const units: BundleUnit[] = [
		{ code: "class Widget {\n}\nregistry.push(Widget);\n", runsOnLoad: false },
		{ code: "const { a, b } = pair;\n", runsOnLoad: false },
		{ code: "", runsOnLoad: false },
	];
	const live = liveUnits(units, []);
	assert live[0] && live[1] && !live[2];
}

test "every column-0 declaration of a unit is one of its names" {
	const names: string[] = [];
	const code = "let Shape;\nfunction Shape_make(a) {\n  const inner = 1;\n  return a;\n}\nasync function load() {\n}\nfunction* walk() {\n}\n";
	assert topLevelNames(code, names);
	assert names.join(",") == "Shape,Shape_make,load,walk";
}

test "a name inside a string or a longer name is read as a whole word" {
	const units: BundleUnit[] = [
		{ code: "function tag() {\n}\n", runsOnLoad: false },
		{ code: "function tagged() {\n}\n", runsOnLoad: false },
		{ code: "print(\"tag\", tagged$1);\n", runsOnLoad: true },
	];
	const live = liveUnits(units, []);
	assert live[0] && !live[1];
}
