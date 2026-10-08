export const MODES: string[] = ["js-throws", "c-build", "split"];

export struct Identity {
	mode: string;
	symptom: string;
	label: string;
	shape: string;
	keep: string;
	forbid: string;
}

export function formatIdentity(id: Identity): string {
	return "mode: " + id.mode + "\nsymptom: " + id.symptom + "\nlabel: " + id.label + "\nshape: " + id.shape + "\nkeep: " + id.keep + "\nforbid: " + id.forbid + "\n";
}

function valueOf(text: string, key: string): string {
	for (const line of text.split("\n")) {
		if (line.startsWith(key + ": ")) { return line.slice(key.length + 2, line.length).trim(); }
	}
	return "";
}

export function parseIdentity(text: string): Result<Identity, string> {
	const mode = valueOf(text, "mode");
	let known = false;
	for (const m of MODES) { if (m == mode) { known = true; } }
	if (!known) { return Result.err("identity mode '" + mode + "' is not one of " + MODES.join(", ")); }
	const symptom = valueOf(text, "symptom");
	const label = valueOf(text, "label");
	const shape = valueOf(text, "shape");
	const keep = valueOf(text, "keep");
	const forbid = valueOf(text, "forbid");
	if (mode != "split" && symptom == "") { return Result.err("identity mode " + mode + " needs a symptom"); }
	if (mode == "split" && (label == "" || shape == "")) { return Result.err("identity mode split needs a label and a value shape"); }
	return Result.ok({ mode: mode, symptom: symptom, label: label, shape: shape, keep: keep, forbid: forbid });
}

export function missingKeep(keep: string, program: string): string {
	if (keep == "") { return ""; }
	for (const part of keep.split(",")) {
		const token = part.trim();
		if (token != "" && !program.contains(token)) { return token; }
	}
	return "";
}

export const INTRODUCED: string[] = ["--", "++"];

export function forbidOf(original: string): string {
	const out: string[] = [];
	for (const token of INTRODUCED) { if (!original.contains(token)) { out.push(token); } }
	return out.join(",");
}

export function presentForbidden(forbid: string, program: string): string {
	if (forbid == "") { return ""; }
	for (const part of forbid.split(",")) {
		const token = part.trim();
		if (token != "" && program.contains(token)) { return token; }
	}
	return "";
}

export function globMatch(pattern: string, text: string): boolean {
	const parts = pattern.split("*");
	if (parts.length == 1) { return pattern == text; }
	if (!text.startsWith(parts[0])) { return false; }
	let at = parts[0].length;
	for (let i = 1; i < parts.length - 1; i++) {
		const found = text.indexOf(parts[i], at);
		if (found < 0) { return false; }
		at = found + parts[i].length;
	}
	const last = parts[parts.length - 1];
	return text.length - last.length >= at && text.endsWith(last);
}

export function hasLine(text: string, pattern: string): boolean {
	for (const raw of text.split("\n")) { if (globMatch(pattern, raw.trim())) { return true; } }
	return false;
}

export function compilerError(line: string): string {
	const at = line.indexOf(": error: ");
	return at < 0 ? "" : line.slice(at + ": error: ".length, line.length).trim();
}

export function hasCompilerError(text: string, pattern: string): boolean {
	for (const raw of text.split("\n")) {
		const message = compilerError(raw);
		if (message != "" && globMatch(pattern, message)) { return true; }
	}
	return false;
}

export function firstCompilerError(text: string): string {
	for (const raw of text.split("\n")) {
		const message = compilerError(raw);
		if (message != "") { return message; }
	}
	return "";
}

export function throwLine(stderr: string): string {
	for (const raw of stderr.split("\n")) {
		const line = raw.trim();
		const colon = line.indexOf(": ");
		if (colon > 0 && line.slice(0, colon).endsWith("Error") && line.indexOf(" ") == colon + 1) { return line; }
	}
	return "";
}

export struct Diff {
	label: string;
	shape: string;
	left: string;
	right: string;
}

function isDigits(text: string): boolean {
	if (text == "") { return false; }
	for (let i = 0; i < text.length; i++) {
		const code = text.charCodeAt(i);
		if (code < 48 || code > 57) { return false; }
	}
	return true;
}

export function valueShape(value: string): string {
	const body = value.startsWith("-") ? value.slice(1, value.length) : value;
	if (isDigits(body)) { return "int"; }
	const dot = body.indexOf(".");
	if (dot > 0 && isDigits(body.slice(0, dot)) && isDigits(body.slice(dot + 1, body.length))) { return "float"; }
	return "text";
}

export function firstDiff(a: string, b: string): Diff {
	const x = a.split("\n");
	const y = b.split("\n");
	const n = x.length > y.length ? x.length : y.length;
	for (let i = 0; i < n; i++) {
		const l = i < x.length ? x[i] : "";
		const r = i < y.length ? y[i] : "";
		if (l != r) {
			const line = l == "" ? r : l;
			const space = line.indexOf(" ");
			const label = space < 0 ? line : line.slice(0, space);
			const lv = l.startsWith(label + " ") ? l.slice(label.length + 1, l.length) : "";
			const rv = r.startsWith(label + " ") ? r.slice(label.length + 1, r.length) : "";
			const ls = valueShape(lv);
			const rs = valueShape(rv);
			return { label: label, shape: ls == rs ? ls : ls + "|" + rs, left: lv, right: rv };
		}
	}
	return { label: "", shape: "", left: "", right: "" };
}

test "an identity round-trips through its text" {
	const id: Identity = { mode: "c-build", symptom: "use of undeclared identifier '_envP'", label: "", shape: "", keep: "", forbid: "" };
	const r = parseIdentity(formatIdentity(id));
	assert r.ok;
	if (r.ok) { assert r.value.mode == "c-build" && r.value.symptom == id.symptom && r.value.label == ""; }
}

test "an identity without its pinned fact is refused" {
	assert !parseIdentity("mode: split\nlabel: \n").ok;
	assert !parseIdentity("mode: js-throws\n").ok;
	assert !parseIdentity("mode: other\nsymptom: x\n").ok;
}

test "a symptom glob matches a whole line and nothing near it" {
	assert globMatch("dollarhoist_*_", "dollarhoist_6_");
	assert globMatch("dollarhoist_*_", "dollarhoist_12_");
	assert !globMatch("dollarhoist_*_", "dollarhoist_6_x");
	assert !globMatch("dollarhoist_*_", "predollarhoist_6_");
	assert !globMatch("a*a", "a");
	assert globMatch("exact", "exact");
	assert !globMatch("exact", "exactly");
}

test "a compiler error is matched by its message, not by its position" {
	const log = "x.ms:699:29: error: use of undeclared identifier '_envP'\n2 warnings and 1 error generated.\n";
	assert hasCompilerError(log, "use of undeclared identifier '_envP'");
	assert !hasCompilerError(log, "use of undeclared identifier '_envQ'");
	assert !hasCompilerError("x.ms:1:1: warning: use of undeclared identifier '_envP'\n", "use of undeclared identifier '_envP'");
	assert firstCompilerError(log) == "use of undeclared identifier '_envP'";
}

test "only the node error line of the pinned class counts as the throw" {
	const err = "/p/x.js:4275\n  g1 = --(1);\n\nSyntaxError: Invalid left-hand side expression in prefix operation\n    at wrapSafe (node:x)\n";
	assert throwLine(err) == "SyntaxError: Invalid left-hand side expression in prefix operation";
	assert hasLine(err, "SyntaxError: Invalid left-hand side expression in prefix operation");
	assert !hasLine(err, "SyntaxError: Unexpected token");
	assert throwLine("RangeError: Maximum call stack size exceeded\n") == "RangeError: Maximum call stack size exceeded";
	assert throwLine("no error here\n") == "";
}

test "a split is pinned to the label and value shape of the first line that differs" {
	const d = firstDiff("e0 1\ng0 4\ng1 5\n", "e0 1\ng0 5\ng1 5\n");
	assert d.label == "g0" && d.shape == "int" && d.left == "4" && d.right == "5";
	assert firstDiff("e0 1\ng0 4\n", "e0 2\ng0 5\n").label == "e0";
	assert firstDiff("e0 1\n", "e0 1\n").label == "";
	assert firstDiff("e0 1\n", "e0 1\ng0 1\n").label == "g0";
}

test "a different kind of value at the same label is another bug" {
	assert firstDiff("g0 <function>\n", "g0 function String() {}\n").shape == "text";
	assert firstDiff("g0 1.5\n", "g0 2.5\n").shape == "float";
	assert firstDiff("g0 -3\n", "g0 4\n").shape == "int";
	assert firstDiff("g0 3\n", "g0 4.5\n").shape == "int|float";
}

test "a pinned construct that left the program is named" {
	assert missingKeep("plantDelta", "g0 = g0 ^ plantDelta();") == "";
	assert missingKeep("plantDelta, g0", "let c = b;") == "plantDelta";
	assert missingKeep("", "anything") == "";
}

test "a reduction may not introduce an operator the original never had" {
	assert forbidOf("let a = -(-b);") == "--,++";
	assert forbidOf("i++;") == "--";
	assert presentForbidden(forbidOf("let a = -(-b);"), "function f() { --0 }") == "--";
	assert presentForbidden(forbidOf("let a = -(-b);"), "let a = -(-b);") == "";
}
