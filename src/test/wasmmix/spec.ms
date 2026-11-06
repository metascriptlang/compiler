// Pure parts of the wasmmix oracle runner (run.ms): directive head parse and output comparison.
// Directive shape mirrors the reference testament's `output:` and `errormsg:`.

export interface WasmmixSpec {
	stdout: string[];
	hasStdout: boolean;
	foreignStdout: string[];
	mixedErrors: string[];
	errors: string[];
	slots: boolean;
	columns: string[];
	mixedStderr: string[];
	loads: int32;
	ledgerBalanced: string[];
	ledgerLeaks: string[];
	unknown: string[];
}

function directiveValue(line: string, key: string): string {
	const prefix = "// " + key + ":";
	if (line.startsWith(prefix)) {
		return line.slice(prefix.length, line.length).trim();
	}
	return "";
}

export function parseSpec(src: string): WasmmixSpec {
	const spec: WasmmixSpec = {
		stdout: [],
		hasStdout: false,
		foreignStdout: [],
		mixedErrors: [],
		errors: [],
		slots: false,
		columns: ["c", "js", "mixed"],
		mixedStderr: [],
		loads: 1,
		ledgerBalanced: [],
		ledgerLeaks: [],
		unknown: [],
	};
	for (const line of src.split("\n")) {
		const t = line.trim();
		if (t != "" && !t.startsWith("//")) {
			break;
		}
		if (t.startsWith("// @stdout:")) {
			spec.stdout.push(directiveValue(t, "@stdout"));
			spec.hasStdout = true;
		} else if (t.startsWith("// @foreign-stdout:")) {
			spec.foreignStdout.push(directiveValue(t, "@foreign-stdout"));
		} else if (t.startsWith("// @mixed-error:")) {
			spec.mixedErrors.push(directiveValue(t, "@mixed-error"));
		} else if (t.startsWith("// @error:")) {
			spec.errors.push(directiveValue(t, "@error"));
		} else if (t.startsWith("// @columns:")) {
			const names = directiveValue(t, "@columns").split(",").map((n) => n.trim());
			if (names.every((n) => n == "c" || n == "js" || n == "mixed")) {
				spec.columns = names;
			} else {
				spec.unknown.push(t);
			}
		} else if (t.startsWith("// @mixed-stderr:")) {
			spec.mixedStderr.push(directiveValue(t, "@mixed-stderr"));
		} else if (t.startsWith("// @loads:")) {
			const v = directiveValue(t, "@loads");
			const n = v.parseInt();
			if (n >= 1 && `${n}` == v) {
				spec.loads = n as int32;
			} else {
				spec.unknown.push(t);
			}
		} else if (t.startsWith("// @ledger-balanced:")) {
			spec.ledgerBalanced.push(directiveValue(t, "@ledger-balanced"));
		} else if (t.startsWith("// @ledger-leaks:")) {
			spec.ledgerLeaks.push(directiveValue(t, "@ledger-leaks"));
		} else if (t == "// @slots") {
			spec.slots = true;
		} else if (t.startsWith("// @")) {
			spec.unknown.push(t);
		}
	}
	return spec;
}

export function normalizeOutput(s: string): string {
	return s.replaceAll("\r\n", "\n");
}

// "" when equal, else the first differing line with both sides.
export function describeDiff(expected: string, actual: string): string {
	const e = normalizeOutput(expected).split("\n");
	const a = normalizeOutput(actual).split("\n");
	const n = e.length > a.length ? e.length : a.length;
	for (let i = 0; i < n; i += 1) {
		const el = i < e.length ? e[i] : "<missing>";
		const al = i < a.length ? a[i] : "<missing>";
		if (el != al) {
			const want = JSON.stringify(el);
			return `line ${i + 1}: expected ${want}, got ${JSON.stringify(al)}`;
		}
	}
	return "";
}

export function hasLineStartingWith(text: string, prefix: string): boolean {
	for (const line of normalizeOutput(text).split("\n")) {
		if (line.startsWith(prefix)) return true;
	}
	return false;
}

export function hasLineWith(text: string, want: string): boolean {
	const fragments = want.split(" ~> ");
	for (const line of normalizeOutput(text).split("\n")) {
		let rest = line;
		let all = true;
		for (const fragment of fragments) {
			const at = rest.indexOf(fragment);
			if (at < 0) {
				all = false;
				break;
			}
			rest = rest.slice(at + fragment.length, rest.length);
		}
		if (all) {
			return true;
		}
	}
	return false;
}

test "parseSpec collects every @stdout line in order" {
	const s = parseSpec(
		"// @stdout: 1\n// @stdout: two words\n\nimport x;\n// @stdout: after code",
	);
	assert s.hasStdout;
	assert s.stdout.length == 2;
	assert s.stdout[0] == "1";
	assert s.stdout[1] == "two words";
}

test "parseSpec reads every @mixed-error in order and flags an unknown directive" {
	const s = parseSpec(
		"// @mixed-error: unsupported\n// @mixed-error: a ~> b\n// @bogus\nx",
	);
	assert s.mixedErrors.length == 2;
	assert s.mixedErrors[0] == "unsupported";
	assert s.mixedErrors[1] == "a ~> b";
	assert s.unknown.length == 1;
	assert !s.hasStdout;
}

test "hasLineWith needs every fragment, in order, on one line" {
	const text =
		"x 'f' in m: the result has type T, and one\r\ny 'g' in m: parameter 'p' has type U, and two";
	assert hasLineWith(text, "'f' in");
	assert hasLineWith(text, "'f' in ~> the result has type ~> and one");
	assert hasLineWith(text, "'g' in ~> parameter 'p' has type ~> and two");
	assert !hasLineWith(text, "'f' in ~> parameter 'p' has type");
	assert !hasLineWith(text, "'g' in ~> and one");
	assert !hasLineWith(text, "and one ~> 'f' in");
}

test "describeDiff is empty on equal output and names the first differing line" {
	assert describeDiff("a\nb\n", "a\r\nb\n") == "";
	assert describeDiff("a\nb", "a\nc").contains("line 2");
	assert describeDiff("a", "a\nb").contains("<missing>");
}

test "parseSpec collects @foreign-stdout apart from @stdout" {
	const s = parseSpec(
		"// @stdout: 1\n// @foreign-stdout: a: b\n// @foreign-stdout: c\nx",
	);
	assert s.stdout.length == 1;
	assert s.foreignStdout.length == 2;
	assert s.foreignStdout[0] == "a: b";
	assert s.unknown.length == 0;
}

test "parseSpec reads @slots" {
	const s = parseSpec("// @slots\n// @stdout: 1\nx");
	assert s.slots;
	assert s.unknown.length == 0;
	assert !parseSpec("// @stdout: 1\nx").slots;
}

test "parseSpec reads every @error in order, apart from @mixed-error" {
	const s = parseSpec("// @error: not an object\n// @error: retain\n// @mixed-error: m\nx");
	assert s.errors.length == 2;
	assert s.errors[0] == "not an object";
	assert s.errors[1] == "retain";
	assert s.mixedErrors.length == 1;
	assert s.unknown.length == 0;
}

test "parseSpec defaults to all three columns and one load" {
	const s = parseSpec("// @stdout: 1\nx");
	assert s.columns.length == 3;
	assert s.loads == 1;
	assert s.mixedStderr.length == 0;
	assert s.ledgerBalanced.length == 0;
	assert s.ledgerLeaks.length == 0;
}

test "parseSpec reads @columns, @mixed-stderr, @loads, @ledger-balanced and @ledger-leaks" {
	const s = parseSpec(
		"// @columns: mixed\n// @mixed-stderr: x\n// @loads: 2\n// @ledger-balanced: Counter\n// @ledger-leaks: Box\nx",
	);
	assert s.columns.length == 1;
	assert s.columns[0] == "mixed";
	assert s.mixedStderr.length == 1;
	assert s.mixedStderr[0] == "x";
	assert s.loads == 2;
	assert s.ledgerBalanced.length == 1;
	assert s.ledgerBalanced[0] == "Counter";
	assert s.ledgerLeaks.length == 1;
	assert s.ledgerLeaks[0] == "Box";
	assert s.unknown.length == 0;
}

test "parseSpec flags a bad @columns name, a bad @loads and an unknown directive" {
	assert parseSpec("// @columns: wasm\nx").unknown.length == 1;
	assert parseSpec("// @loads: 0\nx").unknown.length == 1;
	assert parseSpec("// @bogus: 1\nx").unknown.length == 1;
}

test "hasLineStartingWith matches a line start only" {
	assert hasLineStartingWith("a\r\nmsb leak: x\n", "msb leak:");
	assert !hasLineStartingWith("a msb leak: x", "msb leak:");
}
