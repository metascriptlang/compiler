// LSP JSON text: strings, numbers and booleans as they go on the wire.

function unicodeEscape(code: int32): string {
	const hex = code.toString(16);
	return "\\u" + "0000".slice(0, 4 - hex.length) + hex;
}

export function lspJsonString(val: string): string {
	const parts: string[] = ["\""];
	let start = 0;
	for (let i = 0; i < val.length; i++) {
		const code = val.charCodeAt(i);
		const escape = match (code) {
			"\\".code => "\\\\",
			"\"".code => "\\\"",
			"\n".code => "\\n",
			"\r".code => "\\r",
			"\t".code => "\\t",
			_ => code > 127 ? unicodeEscape(code) : "",
		};
		if (escape == "") continue;
		if (start < i) parts.push(val.slice(start, i));
		parts.push(escape);
		start = i + 1;
	}
	if (start < val.length) parts.push(val.slice(start, val.length));
	parts.push("\"");
	return parts.join("");
}

export function lspJsonNumber(val: number): string {
	return "" + val;
}

export function lspJsonBool(val: boolean): string {
	if (val) return "true";
	return "false";
}

test "simple string" { assert lspJsonString("hello") == "\"hello\""; }

test "escapes backslash" { assert lspJsonString("a\\b") == "\"a\\\\b\""; }

test "escapes quote" { assert lspJsonString("a\"b") == "\"a\\\"b\""; }

test "escapes newline" { assert lspJsonString("a\nb") == "\"a\\nb\""; }

test "empty string" { assert lspJsonString("") == "\"\""; }

test "number" {
	assert lspJsonNumber(42) == "42";
	assert lspJsonNumber(0) == "0";
}

test "bool true" { assert lspJsonBool(true) == "true"; }

test "bool false" { assert lspJsonBool(false) == "false"; }

test "json string escapes non-ASCII as lower-case \\u units" {
	assert lspJsonString("é") == "\"\\u00e9\"";
	assert lspJsonString("a\tb") == "\"a\\tb\"";
}
