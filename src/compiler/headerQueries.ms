const QUERY = "__has_include";

export interface HeaderQueries {
	names: string[];
	quoteForm: boolean;
	macroForm: boolean;
}

export function headerQueries(text: string): HeaderQueries {
	const found: HeaderQueries = { names: [], quoteForm: false, macroForm: false };
	if (text.byteIndexOf(QUERY, 0) < 0) return found;
	const n = text.byteLength;
	let lineStart: int32 = 0;
	let i: int32 = 0;
	while (i < n) {
		const b = text.byteAt(i);
		if (b == "\n".code) {
			lineStart = i + 1;
			i += 1;
		} else if (b == "/".code && i + 1 < n && text.byteAt(i + 1) == "/".code) {
			const end = text.byteIndexOf("\n", i);
			i = end < 0 ? n : end;
		} else if (b == "/".code && i + 1 < n && text.byteAt(i + 1) == "*".code) {
			const end = text.byteIndexOf("*/", i + 2);
			i = end < 0 ? n : end + 2;
		} else if (b == "\"".code || b == "'".code) {
			i = afterQuoted(text, i);
		} else if (b == "_".code && (i == 0 || !identifierByte(text.byteAt(i - 1))) && startsAt(text, i, QUERY)) {
			i = afterQuery(text, i, lineStart, found);
		} else {
			i += 1;
		}
	}
	return found;
}

function afterQuery(text: string, at: int32, lineStart: int32, found: HeaderQueries): int32 {
	const n = text.byteLength;
	let end = at + QUERY.byteLength;
	if (startsAt(text, end, "_next")) end += 5;
	if (startsAt(text, end, "__")) end += 2;
	if (end < n && identifierByte(text.byteAt(end))) return end;
	const open = skipBlanks(text, end);
	if (open >= n || text.byteAt(open) != "(".code) return end;
	if (definesItself(text.byteSlice(lineStart, at))) return open + 1;
	const start = skipBlanks(text, open + 1);
	const quote = start < n ? text.byteAt(start) : 0;
	const close = quote == "\"".code ? "\"" : quote == "<".code ? ">" : "";
	const stop = close == "" ? -1 : text.byteIndexOf(close, start + 1);
	const newline = text.byteIndexOf("\n", start);
	if (stop < 0 || (newline >= 0 && newline < stop)) {
		found.macroForm = true;
		return open + 1;
	}
	found.names.push(text.byteSlice(start + 1, stop));
	if (quote == "\"".code) found.quoteForm = true;
	return stop + 1;
}

function definesItself(before: string): boolean {
	return before.replaceAll(" ", "").replaceAll("\t", "") == "#define";
}

function afterQuoted(text: string, at: int32): int32 {
	const n = text.byteLength;
	const quote = text.byteAt(at);
	let i: int32 = at + 1;
	while (i < n) {
		const b = text.byteAt(i);
		if (b == quote || b == "\n".code) return i + 1;
		i += b == "\\".code ? 2 : 1;
	}
	return n;
}

function skipBlanks(text: string, at: int32): int32 {
	let i: int32 = at;
	while (i < text.byteLength && (text.byteAt(i) == " ".code || text.byteAt(i) == "\t".code)) i += 1;
	return i;
}

function startsAt(text: string, at: int32, word: string): boolean {
	return at + word.byteLength <= text.byteLength && text.byteSlice(at, at + word.byteLength) == word;
}

function identifierByte(b: int32): boolean {
	return b == "_".code || b >= 128
		|| (b >= "a".code && b <= "z".code)
		|| (b >= "A".code && b <= "Z".code)
		|| (b >= "0".code && b <= "9".code);
}

test "literal queries yield their names and the quote form" {
	const q = headerQueries("#if __has_include(\"optional.h\")\n#elif __has_include( <sys/opt.h> )\n#endif\n");
	assert q.names.join(",") == "optional.h,sys/opt.h";
	assert q.quoteForm;
	assert !q.macroForm;
}

test "an angle-only query does not search the querying file's directory" {
	const q = headerQueries("#if __has_include_next(<limits.h>)\n#endif\n");
	assert q.names.join(",") == "limits.h";
	assert !q.quoteForm;
}

test "feature tests and fallback definitions are not queries" {
	const q = headerQueries(
		"#if defined(__has_include)\n#endif\n#ifndef __has_include\n#  define __has_include(__x) 0\n#endif\n" +
		"#define __has_include_next(x) 0\n",
	);
	assert q.names.length == 0;
	assert !q.macroForm;
}

test "a query whose name comes from a macro is marked" {
	assert headerQueries("#define HAS(x) __has_include(x)\n").macroForm;
	assert headerQueries("#if __has_include(OPTIONAL_HEADER)\n#endif\n").macroForm;
}

test "comments, strings and longer identifiers hold no queries" {
	const q = headerQueries(
		"// __has_include(X)\n/* __has_include(Y) */\nconst char* s = \"__has_include(Z)\";\n" +
		"int my__has_include(int); int __has_include_nextx(int);\n",
	);
	assert q.names.length == 0;
	assert !q.macroForm;
}

test "text without the token is answered without scanning" {
	const q = headerQueries("#include \"a.h\"\nint main(void) { return 0; }\n");
	assert q.names.length == 0 && !q.quoteForm && !q.macroForm;
}
