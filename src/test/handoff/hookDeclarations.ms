import { checkProjectDiagnostics, compileProjectToCWithStd, compileProjectToJSWithStd, compileToC, compileToJS, MapEntry } from "../helpers";
import { checkSource } from "./helpers";
import { Severity } from "../../checker/context";

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
			if (owner == "C" && hook != "onDestroy" && hook != "onTrace") continue;
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

test "hook declarations: a distinct type takes its hook at scope exit, as a local and as a field" {
	const src = "type Fd = distinct int32;\n"
		+ "function onDestroy(this x: Fd): void { console.log(\"closed\"); }\n"
		+ "function open(n: int32): Fd { return n as Fd; }\n"
		+ "struct Owner { fd: Fd; tag: string; }\n"
		+ "struct Cell { fd: Fd; }\n"
		+ "function local(): void { const a = open(1); console.log(\"local\"); }\n"
		+ "function field(): void { const o: Owner = { fd: open(2), tag: \"t\" }; console.log(o.tag); }\n"
		+ "function element(): void { const xs: Cell[] = [{ fd: open(3) }, { fd: open(4) }]; console.log(xs.length.toString()); }\n"
		+ "local(); field(); element();\n";
	const c = compileToC(src);
	assert c.ok, c.error;
	assert destroyCallsOf(c.value, "Fd") >= 3, "the destroy hook of a distinct type is not called from a local, a field and a struct element: " + destroyCallsOf(c.value, "Fd").toString();
}

test "hook declarations: an array of a distinct type stays legal on JS and without a hook" {
	const hooked = "type Fd = distinct int32;\n"
		+ "function onDestroy(this x: Fd): void { console.log(\"closed\"); }\n"
		+ "function open(n: int32): Fd { return n as Fd; }\n"
		+ "function run(): void { const xs: Fd[] = [open(1), open(2)]; console.log(xs.length.toString()); }\n"
		+ "run();\n";
	const js = compileToJS(hooked);
	assert js.ok, js.error;
	const plain = "type Fd = distinct int32;\nfunction open(n: int32): Fd { return n as Fd; }\nfunction run(): void { const xs: Fd[] = [open(1), open(2)]; console.log(xs.length.toString()); }\nrun();\n";
	const free = compileToC(plain);
	assert free.ok, free.error;
}

function errorsOf(source: string): string[] {
	const out: string[] = [];
	const ctx = checkSource(source);
	if (ctx == null) {
		out.push("the source did not parse");
		return out;
	}
	for (const err of ctx.errors) {
		if (err.severity == Severity.Error) out.push(err.message);
	}
	return out;
}

const shapes = "struct S { id: int32; }\nclass C { id: int32 = 0; next: C | null = null; }\n";

function expectFault(problems: string[], label: string, source: string, fault: string): void {
	const errors = errorsOf(shapes + source);
	if (errors.length != 1) problems.push(label + ": " + errors.length.toString() + " errors: " + errors.join(" | "));
	else if (errors[0].indexOf(fault) < 0) problems.push(label + ": " + errors[0]);
}

function expectAccepted(problems: string[], label: string, source: string): void {
	const errors = errorsOf(shapes + source);
	if (errors.length > 0) problems.push(label + ": " + errors[0]);
}

test "hook declarations: onTrace takes the receiver and the tracer, and nothing else" {
	const problems: string[] = [];
	const wrongCount = "signature for 'onTrace' is wrong: it takes the receiver and the tracer ('env: Ptr<void>')";
	expectFault(problems, "onTrace(this x: C)", "function onTrace(this x: C): void { }\n", wrongCount + ", 1 parameter declared");
	expectFault(problems, "onTrace(this x: C, env, extra)", "function onTrace(this x: C, env: Ptr<void>, extra: int32): void { }\n", wrongCount + ", 3 parameters declared");
	expectFault(problems, "onTrace method", "class T { next: T | null = null; onTrace(): void { } }\n", wrongCount + ", 1 parameter declared");
	expectFault(problems, "onTrace env: int32", "function onTrace(this x: C, env: int32): void { }\n", "its second parameter is 'int32', the tracer is 'env: Ptr<void>'");
	expectFault(problems, "onTrace env: Ptr<S>", "function onTrace(this x: C, env: Ptr<S>): void { }\n", "its second parameter is 'Ptr<S>', the tracer is 'env: Ptr<void>'");
	expectAccepted(problems, "onTrace on a class", "function onTrace(this x: C, env: Ptr<void>): void { }\n");
	expectAccepted(problems, "onTrace on a struct", "function onTrace(this ref x: S, env: Ptr<void>): void { }\n");
	expectAccepted(problems, "onTrace method", "class T { next: T | null = null; onTrace(env: Ptr<void>): void { } }\n");
	assert problems.length == 0, problems.join("\n");
}

test "hook declarations: C and JS both refuse an onTrace without the tracer" {
	const source = shapes + "function onTrace(this x: C): void { }\n";
	const c = compileToC(source);
	assert !c.ok, "C accepted an onTrace without the tracer";
	assert c.error.indexOf("signature for 'onTrace' is wrong") >= 0, c.error;
	const js = compileToJS(source);
	assert !js.ok, "JS accepted an onTrace without the tracer";
	assert js.error.indexOf("signature for 'onTrace' is wrong") >= 0, js.error;
}

test "hook declarations: a wrong parameter list is refused for every hook" {
	const problems: string[] = [];
	const wrong = "signature for '";
	expectFault(problems, "onDestroy extra", "function onDestroy(this x: S, extra: int32): void { }\n", wrong + "onDestroy' is wrong: it takes the receiver only, 2 parameters declared");
	expectFault(problems, "onMoved extra", "function onMoved(this ref x: S, extra: int32): void { }\n", wrong + "onMoved' is wrong: it takes the receiver only, 2 parameters declared");
	expectFault(problems, "onClone extra", "function onClone(this x: S, extra: int32): S { return x; }\n", wrong + "onClone' is wrong: it takes the receiver only, 2 parameters declared");
	expectFault(problems, "onCopy alone", "function onCopy(this ref x: S): void { }\n", wrong + "onCopy' is wrong: it takes the receiver and the source value ('y: T'), 1 parameter declared");
	expectFault(problems, "onMove alone", "function onMove(this ref x: S): void { }\n", wrong + "onMove' is wrong: it takes the receiver and the source value ('y: T'), 1 parameter declared");
	expectFault(problems, "onCopy three", "function onCopy(this ref x: S, y: S, z: S): void { }\n", wrong + "onCopy' is wrong: it takes the receiver and the source value ('y: T'), 3 parameters declared");
	expectFault(problems, "onCopy y: int32", "function onCopy(this ref x: S, y: int32): void { }\n", wrong + "onCopy' is wrong: its second parameter is 'int32', the source value is the receiver's own type ('y: T')");
	expectFault(problems, "onMove y: Var<S>", "function onMove(this ref x: S, y: Var<S>): void { }\n", wrong + "onMove' is wrong: its second parameter is 'out S'");
	expectFault(problems, "onCopy y: another struct", "struct Other { id: int32; }\nfunction onCopy(this ref x: S, y: Other): void { }\n", wrong + "onCopy' is wrong: its second parameter is 'Other'");
	expectFault(problems, "onDestroy method extra", "class T { onDestroy(extra: int32): void { } }\n", wrong + "onDestroy' is wrong: it takes the receiver only, 2 parameters declared");
	expectAccepted(problems, "onCopy y: S", "function onCopy(this ref x: S, y: S): void { }\n");
	expectAccepted(problems, "onCopy y: Readonly<S>", "function onCopy(this ref x: S, y: Readonly<S>): void { }\n");
	expectAccepted(problems, "onDestroy method", "class T { onDestroy(): void { } }\n");
	assert problems.length == 0, problems.join("\n");
}

test "hook declarations: a hook returns nothing and onClone returns its own type" {
	const problems: string[] = [];
	const wrong = "signature for '";
	expectFault(problems, "onDestroy returns int32", "function onDestroy(this x: S): int32 { return 1; }\n", wrong + "onDestroy' is wrong: it returns 'int32', a hook returns nothing");
	expectFault(problems, "onCopy returns S", "function onCopy(this ref x: S, y: S): S { return y; }\n", wrong + "onCopy' is wrong: it returns 'S', a hook returns nothing");
	expectFault(problems, "onMoved returns boolean", "function onMoved(this ref x: S): boolean { return true; }\n", wrong + "onMoved' is wrong: it returns 'boolean', a hook returns nothing");
	expectFault(problems, "onTrace returns int32", "function onTrace(this x: C, env: Ptr<void>): int32 { return 1; }\n", wrong + "onTrace' is wrong: it returns 'int32', a hook returns nothing");
	expectFault(problems, "onClone returns void", "function onClone(this x: S): void { }\n", wrong + "onClone' is wrong: it returns 'void', a clone is a new value of the receiver's own type");
	expectFault(problems, "onClone returns another struct", "struct Other { id: int32; }\nfunction onClone(this x: S): Other { return { id: 1 }; }\n", wrong + "onClone' is wrong: it returns 'Other', a clone is a new value of the receiver's own type");
	expectFault(problems, "onDestroy method returns int32", "class T { onDestroy(): int32 { return 1; } }\n", wrong + "onDestroy' is wrong: it returns 'int32', a hook returns nothing");
	expectFault(problems, "onDestroy inferred int32", "function onDestroy(this x: S) { return 1; }\n", wrong + "onDestroy' is wrong: it returns '");
	expectFault(problems, "generic onDestroy inferred int32", "struct B<T> { v: T; }\nfunction onDestroy<T>(this x: B<T>) { return 1; }\nfunction use(): void { const b: B<int32> = { v: 1 }; console.log(b.v.toString()); }\n", "signature for 'onDestroy' is wrong: it returns '");
	expectAccepted(problems, "onDestroy inferred void", "function onDestroy(this x: S) { console.log(\"closed\"); }\n");
	expectAccepted(problems, "onClone returns S", "function onClone(this x: S): S { return x; }\n");
	assert problems.length == 0, problems.join("\n");
}

function classFault(hook: string, name: string): string {
	return "signature for '" + hook + "' is wrong: '" + name + "' is a class, its values are shared by reference and never copied, moved or cloned by value, so the hook would never run";
}

test "hook declarations: a class takes no hook that copies, moves, resets or clones a value" {
	const problems: string[] = [];
	expectFault(problems, "onCopy on a class", "function onCopy(this x: C, y: C): void { }\n", classFault("onCopy", "C"));
	expectFault(problems, "onMove on a class", "function onMove(this x: C, y: C): void { }\n", classFault("onMove", "C"));
	expectFault(problems, "onMoved on a class", "function onMoved(this x: C): void { }\n", classFault("onMoved", "C"));
	expectFault(problems, "onClone on a class", "function onClone(this x: C): C { return x; }\n", classFault("onClone", "C"));
	expectFault(problems, "onCopy method on a class", "class T { onCopy(y: T): void { } }\n", classFault("onCopy", "T"));
	expectFault(problems, "onClone method on a class", "class T { onClone(): T { return this; } }\n", classFault("onClone", "T"));
	expectFault(problems, "onCopy on an interface", "interface I { id: int32; }\nfunction onCopy(this x: I, y: I): void { }\n", classFault("onCopy", "I"));
	expectAccepted(problems, "onDestroy on a class", "function onDestroy(this x: C): void { }\n");
	expectAccepted(problems, "onTrace on a class", "function onTrace(this x: C, env: Ptr<void>): void { }\n");
	assert problems.length == 0, problems.join("\n");
}
