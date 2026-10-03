import { checkProjectDiagnostics, compileProjectToCWithStd, compileProjectToJSWithStd, compileToC, MapEntry } from "../helpers";

const hooks = ["onDestroy", "onCopy", "onMove", "onMoved", "onTrace", "onClone"];

const library = "export struct S { id: int32; name: string; }\n"
	+ "export class C { id: int32 = 0; }\n"
	+ "export struct B<T> { v: T; }\n"
	+ "export type Id = distinct int32;\n"
	+ "export function onDestroy(this x: Id): void { }\n";

function hookSource(hook: string, receiver: string, owner: string): string {
	let rest = "";
	if (hook == "onCopy" || hook == "onMove") rest = ", y: " + owner;
	if (hook == "onTrace") rest = ", env: Ptr<void>";
	if (hook == "onClone") return "function onClone(" + receiver + "): " + owner + " { return x; }\n";
	return "function " + hook + "(" + receiver + rest + "): void { }\n";
}

function project(lib: string, main: string): MapEntry[] {
	return [
		{ entryPath: "test/lib.ms", entrySource: lib },
		{ entryPath: "test/main.ms", entrySource: main },
	];
}

function receiverFor(hook: string, owner: string): string {
	const byRef = hook == "onCopy" || hook == "onMove" || hook == "onMoved" || hook == "onTrace";
	if (owner == "C") return "this x: C";
	return byRef ? "this ref x: " + owner : "this x: " + owner;
}

test "hook declarations: a hook declared outside the module of its type is refused for every hook" {
	const problems: string[] = [];
	for (const hook of hooks) {
		for (const owner of ["S", "C"]) {
			const main = "import { " + owner + " } from \"./lib\";\n" + hookSource(hook, receiverFor(hook, owner), owner);
			const errors = checkProjectDiagnostics(project(library, main), "test/main.ms");
			const label = hook + " on " + owner + ": ";
			const wanted = "type bound operation '" + hook + "' can be defined only in the same module with its type (" + owner + ")";
			if (errors.length != 1) problems.push(label + errors.length.toString() + " errors: " + errors.join(" | "));
			else if (errors[0].indexOf(wanted) < 0) problems.push(label + errors[0]);
		}
	}
	assert problems.length == 0, problems.join("\n");
}

test "hook declarations: a generic hook for an imported generic type is refused" {
	const main = "import { B } from \"./lib\";\nfunction onDestroy<T>(this x: B<T>): void { }\n";
	const errors = checkProjectDiagnostics(project(library, main), "test/main.ms");
	assert errors.length == 1, errors.join(" | ");
	assert errors[0].indexOf("can be defined only in the same module with its type (B)") >= 0, errors[0];
}

test "hook declarations: a hook beside its type in the imported module stays accepted" {
	const main = "import { Id } from \"./lib\";\nconst a = 5 as Id;\nconsole.log(\"made\");\n";
	const errors = checkProjectDiagnostics(project(library, main), "test/main.ms");
	assert errors.length == 0, errors.join(" | ");
}

test "hook declarations: C and JS both refuse a hook outside its type's module" {
	const main = "import { S } from \"./lib\";\nfunction onDestroy(this x: S): void { }\nconsole.log(\"made\");\n";
	const c = compileProjectToCWithStd(project(library, main), "test/main.ms");
	assert c.indexOf("can be defined only in the same module with its type (S)") >= 0, c;
	const js = compileProjectToJSWithStd(project(library, main), "test/main.ms");
	assert js.indexOf("can be defined only in the same module with its type (S)") >= 0, js;
}

function isIdentChar(c: string): boolean {
	return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_";
}

function destroyCallsOf(code: string, typeName: string): int32 {
	let n: int32 = 0;
	let at = code.indexOf("Destroy(&");
	while (at >= 0) {
		let from = at;
		while (from > 0 && isIdentChar(code.charAt(from - 1))) from -= 1;
		if (code.slice(from, at).startsWith(typeName)) n += 1;
		at = code.indexOf("Destroy(&", at + 9);
	}
	return n;
}

test "hook declarations: a struct with no managed field takes its hook at scope exit" {
	const src = "struct Handle { h: int32; }\n"
		+ "function onDestroy(this x: Handle): void { console.log(\"closed\"); }\n"
		+ "function use(): void { const a: Handle = { h: 1 }; console.log(a.h.toString()); }\n"
		+ "use();\n";
	const c = compileToC(src);
	assert c.ok, c.error;
	assert destroyCallsOf(c.value, "Handle") >= 1, "the scope exit never calls the destroy hook of a handle-only struct";
	const generic = "struct Slot<T> { v: T; }\n"
		+ "function onDestroy<T>(this x: Slot<T>): void { console.log(\"closed\"); }\n"
		+ "function use(): void { const a: Slot<int32> = { v: 1 }; console.log(a.v.toString()); }\n"
		+ "use();\n";
	const g = compileToC(generic);
	assert g.ok, g.error;
	assert destroyCallsOf(g.value, "Slot") >= 1, "the scope exit never calls the destroy hook of a handle-only generic struct instance";
}

test "hook declarations: a distinct type takes its hook at scope exit, as a field and as an element" {
	const src = "type Fd = distinct int32;\n"
		+ "function onDestroy(this x: Fd): void { console.log(\"closed\"); }\n"
		+ "function open(n: int32): Fd { return n as Fd; }\n"
		+ "struct Owner { fd: Fd; tag: string; }\n"
		+ "function local(): void { const a = open(1); console.log(\"local\"); }\n"
		+ "function field(): void { const o: Owner = { fd: open(2), tag: \"t\" }; console.log(o.tag); }\n"
		+ "function element(): void { const xs: Fd[] = [open(3), open(4)]; console.log(xs.length.toString()); }\n"
		+ "local(); field(); element();\n";
	const c = compileToC(src);
	assert c.ok, c.error;
	assert destroyCallsOf(c.value, "Fd") >= 4, "the destroy hook of a distinct type is not called from a local, a field and an element: " + destroyCallsOf(c.value, "Fd").toString();
}
