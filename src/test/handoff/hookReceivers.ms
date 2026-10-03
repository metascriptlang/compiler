import { compileToC, compileToJS } from "../helpers";
import { checkSource } from "./helpers";
import { Severity } from "../../checker/context";

const declared = "struct S { h: int32; }\nclass C { h: int32 = 0; }\nenum E { A, B }\ntype AS = S;\ntype AC = C;\n";
const hooks = ["onDestroy", "onCopy", "onMove", "onMoved", "onTrace", "onClone"];
const owners = ["S", "C"];

function hookSource(hook: string, receiver: string, owner: string): string {
	let rest = "";
	if (hook == "onCopy" || hook == "onMove") rest = ", y: " + owner;
	if (hook == "onTrace") rest = ", env: Ptr<void>";
	if (hook == "onClone") return declared + "function onClone(" + receiver + "): " + owner + " { return null as unknown as " + owner + "; }\n";
	return declared + "function " + hook + "(" + receiver + rest + "): void { }\n";
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

function writesItsReceiver(hook: string): boolean {
	return hook == "onCopy" || hook == "onMove" || hook == "onMoved" || hook == "onTrace";
}

function expectRefused(problems: string[], hook: string, receiver: string, owner: string, why: string): void {
	const errors = errorsOf(hookSource(hook, receiver, owner));
	const label = hook + "(" + receiver + ") on " + owner + ": ";
	if (errors.length != 1) problems.push(label + errors.length.toString() + " errors");
	else if (errors[0].indexOf("signature for '" + hook + "' must take its receiver as ") < 0) problems.push(label + errors[0]);
	else if (errors[0].indexOf(why) < 0) problems.push(label + errors[0]);
}

function expectAccepted(problems: string[], hook: string, receiver: string, owner: string): void {
	const errors = errorsOf(hookSource(hook, receiver, owner));
	if (errors.length > 0) problems.push(hook + "(" + receiver + ") on " + owner + ": " + errors[0]);
}

test "hook receivers: a pointer to the type is refused at the declaration" {
	const problems: string[] = [];
	for (const hook of hooks) {
		for (const owner of owners) {
			expectRefused(problems, hook, "this x: Ptr<" + owner + ">", owner, "addresses the type");
		}
	}
	assert problems.length == 0, problems.join("\n");
}

test "hook receivers: a receiver that is not the type's own name is refused at the declaration" {
	const problems: string[] = [];
	for (const hook of hooks) {
		for (const owner of owners) {
			expectRefused(problems, hook, "this x: Ref<" + owner + ">", owner, "'Ref<" + owner + ">'");
			expectRefused(problems, hook, "this x: A" + owner, owner, "is not the type's own name");
			expectRefused(problems, hook, "this x: Cursor<" + owner + ">", owner, "is not a type a hook can belong to");
			expectRefused(problems, hook, "this x: Borrow<" + owner + ">", owner, "is not a type a hook can belong to");
			expectRefused(problems, hook, "this x: " + owner + "[]", owner, "is not a type a hook can belong to");
			expectRefused(problems, hook, "this x: " + owner + " | null", owner, "'" + owner + " | null'");
			expectRefused(problems, hook, "this x: int32", owner, "'int32' is not a type a hook can belong to");
			expectRefused(problems, hook, "this x: E", owner, "'E' is not a type a hook can belong to");
		}
	}
	assert problems.length == 0, problems.join("\n");
}

test "hook receivers: a class receiver is the class itself, never a pointer to its reference" {
	const problems: string[] = [];
	for (const hook of hooks) {
		expectRefused(problems, hook, "this ref x: C", "C", "points at the class reference");
		expectRefused(problems, hook, "this x: Var<C>", "C", "points at the class reference");
	}
	assert problems.length == 0, problems.join("\n");
}

test "hook receivers: a hook that writes its receiver refuses a read-only view and a value copy" {
	const problems: string[] = [];
	for (const hook of hooks) {
		if (!writesItsReceiver(hook)) continue;
		expectRefused(problems, hook, "this x: Readonly<C>", "C", "is a read-only view");
		expectRefused(problems, hook, "this x: S", "S", "the hook has to write");
		expectRefused(problems, hook, "this x: Readonly<S>", "S", "the hook has to write");
	}
	assert problems.length == 0, problems.join("\n");
}

test "hook receivers: onClone takes its receiver by value" {
	const problems: string[] = [];
	expectRefused(problems, "onClone", "this ref x: S", "S", "a clone is a new value");
	expectRefused(problems, "onClone", "this x: Var<S>", "S", "a clone is a new value");
	assert problems.length == 0, problems.join("\n");
}

test "hook receivers: a bare generic parameter is refused" {
	const errors = errorsOf("function onDestroy<T>(this x: T): void { }\n");
	assert errors.length == 1, errors.length.toString() + " errors";
	assert errors[0].indexOf("signature for 'onDestroy' must take its receiver as ") >= 0, errors[0];
}

test "hook receivers: the shapes the reference accepts still compile" {
	const problems: string[] = [];
	for (const owner of owners) {
		expectAccepted(problems, "onDestroy", "this x: " + owner, owner);
		expectAccepted(problems, "onDestroy", "this x: Readonly<" + owner + ">", owner);
	}
	expectAccepted(problems, "onClone", "this x: S", "S");
	expectAccepted(problems, "onClone", "this x: Readonly<S>", "S");
	for (const hook of ["onDestroy", "onCopy", "onMove", "onMoved", "onTrace"]) {
		expectAccepted(problems, hook, "this ref x: S", "S");
		expectAccepted(problems, hook, "this x: Var<S>", "S");
	}
	expectAccepted(problems, "onTrace", "this x: C", "C");
	assert problems.length == 0, problems.join("\n");
	const generic = "struct B<T> { v: T; }\nclass G<T> { v: T; constructor(v: T) { this.v = v; } }\n"
		+ "function onDestroy<T>(this x: B<T>): void { }\nfunction onDestroy<T>(this x: G<T>): void { }\n"
		+ "function onMoved<T>(this ref x: B<T>): void { }\n";
	const genericErrors = errorsOf(generic);
	assert genericErrors.length == 0, genericErrors.length > 0 ? genericErrors[0] : "";
	const union = "type D = { kind: \"a\", n: int32 } | { kind: \"b\", s: string };\nfunction onDestroy(this x: D): void { }\n";
	const unionErrors = errorsOf(union);
	assert unionErrors.length == 0, unionErrors.length > 0 ? unionErrors[0] : "";
}

test "hook receivers: C and JS refuse a pointer receiver and accept the type itself, for every hook" {
	for (const hook of hooks) {
		const refused = hookSource(hook, "this x: Ptr<S>", "S");
		const c = compileToC(refused);
		assert !c.ok, hook + " on C accepted Ptr<S>";
		assert c.error.indexOf("signature for '" + hook + "'") >= 0, c.error;
		const js = compileToJS(refused);
		assert !js.ok, hook + " on JS accepted Ptr<S>";
		assert js.error.indexOf("signature for '" + hook + "'") >= 0, js.error;
		const accepted = hook == "onClone"
			? declared + "function onClone(this x: S): S { return x; }\n"
			: hookSource(hook, hook == "onDestroy" ? "this x: S" : "this ref x: S", "S");
		const cOk = compileToC(accepted);
		assert cOk.ok, hook + " on C: " + cOk.error;
		const jsOk = compileToJS(accepted);
		assert jsOk.ok, hook + " on JS: " + jsOk.error;
	}
}
