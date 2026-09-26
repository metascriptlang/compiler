// bug494 — fields named `near` or `far` did not compile on Windows
//
// Symptom:    `interface Span { near: int32; far: int32 }` failed the C build on Windows
//             (`expected identifier`); JS ran.
// Root cause: windows.h, which reaches every module through the runtime headers, defines `near`
//             and `far` as empty macros, so the preprocessor erased the field names.
// Fix:        every module undefines the legacy platform macros (`near`, `far`, `linux`, `unix`,
//             `i386`, ...) after its last #include, as the reference compiler does.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

function lastIncludeAt(c: string): int32 {
	let last: int32 = -1;
	let at = c.indexOf("#include", 0);
	while (at >= 0) {
		last = at as int32;
		at = c.indexOf("#include", at + 1);
	}
	return last;
}

test "bug494: near and far are undefined after the last include and before their fields" {
	const c = cOf("export interface Span { near: int32; far: int32; }\nexport function width(s: Span): int32 { return s.far - s.near; }\n");
	const undefNear = c.indexOf("#undef near", 0);
	const undefFar = c.indexOf("#undef far", 0);
	assert undefNear > lastIncludeAt(c);
	assert undefFar > lastIncludeAt(c);
	assert undefNear < c.indexOf("int32_t near;", 0);
}

test "bug494: the GNU-mode names are undefined before a parameter spelled like them" {
	const c = cOf("export function pick(linux: int32, unix: int32, i386: int32): int32 { return linux + unix + i386; }\n");
	for (const name of ["linux", "unix", "i386"]) {
		const undef = c.indexOf(`#undef ${name}`, 0);
		assert undef > lastIncludeAt(c);
		assert undef < c.indexOf(`int32_t ${name}`, 0);
	}
}
