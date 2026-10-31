// Pure parts of the wasmmix oracle runner (run.ms): directive head parse and output comparison.
// Directive shape mirrors the reference testament's `output:` and `errormsg:`.

export interface WasmmixSpec {
	stdout: string[];
	hasStdout: boolean;
	foreignStdout: string[];
	mixedError: string;
	slots: boolean;
	unknown: string[];
}

function directiveValue(line: string, key: string): string {
	const prefix = "// " + key + ":";
	if (line.indexOf(prefix) == 0) { return line.slice(prefix.length, line.length).trim(); }
	return "";
}

export function parseSpec(src: string): WasmmixSpec {
	const spec: WasmmixSpec = { stdout: [], hasStdout: false, foreignStdout: [], mixedError: "", slots: false, unknown: [] };
	for (const line of src.split("\n")) {
		const t = line.trim();
		if (t != "" && t.indexOf("//") != 0) { break; }
		if (t.indexOf("// @stdout:") == 0) {
			spec.stdout.push(directiveValue(t, "@stdout"));
			spec.hasStdout = true;
		} else if (t.indexOf("// @foreign-stdout:") == 0) {
			spec.foreignStdout.push(directiveValue(t, "@foreign-stdout"));
		} else if (t.indexOf("// @mixed-error:") == 0) {
			spec.mixedError = directiveValue(t, "@mixed-error");
		} else if (t == "// @slots") {
			spec.slots = true;
		} else if (t.indexOf("// @") == 0) {
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
	for (let i = 0; i < n; i = i + 1) {
		const el = i < e.length ? e[i] : "<missing>";
		const al = i < a.length ? a[i] : "<missing>";
		if (el != al) { return `line ${i + 1}: expected ${JSON.stringify(el)}, got ${JSON.stringify(al)}`; }
	}
	return "";
}

test "parseSpec collects every @stdout line in order" {
	const s = parseSpec("// @stdout: 1\n// @stdout: two words\n\nimport x;\n// @stdout: after code");
	assert s.hasStdout;
	assert s.stdout.length == 2;
	assert s.stdout[0] == "1";
	assert s.stdout[1] == "two words";
}

test "parseSpec reads @mixed-error and flags an unknown directive" {
	const s = parseSpec("// @mixed-error: unsupported\n// @bogus\nx");
	assert s.mixedError == "unsupported";
	assert s.unknown.length == 1;
	assert !s.hasStdout;
}

test "describeDiff is empty on equal output and names the first differing line" {
	assert describeDiff("a\nb\n", "a\r\nb\n") == "";
	assert describeDiff("a\nb", "a\nc").contains("line 2");
	assert describeDiff("a", "a\nb").contains("<missing>");
}

test "parseSpec collects @foreign-stdout apart from @stdout" {
	const s = parseSpec("// @stdout: 1\n// @foreign-stdout: a: b\n// @foreign-stdout: c\nx");
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
