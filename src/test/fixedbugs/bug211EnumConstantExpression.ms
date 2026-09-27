// bug211 — an enum member initialised with a constant expression gets its folded value
//
// Symptom:    `enum Bits { A = 0x10, B = (1 << 2), C }` printed 16 17 18, then became a parse error.
// Root cause: the parser kept only integer literals and counted on past anything else.
// Fix:        the parser keeps the initializer, and the checker types and folds it where it builds the enum type.

import { compileToC, compileToJS } from "../helpers";

test "bug211: a shifted initializer and the member after it fold on JS" {
	const js = compileToJS("enum Bits { A = 0x10, B = (1 << 2), C }\nconst c = Bits.C;");
	assert js.ok, js.ok ? "" : js.error;
	assert js.value.contains("_A = 16;") && js.value.contains("_B = 4;") && js.value.contains("_C = 5;"), js.value;
}

test "bug211: earlier members fold bare and qualified" {
	const js = compileToJS("enum Perm { Read = 1 << 0, Write = 1 << 1, Both = Read | Write, Also = Perm.Read | Perm.Write }\nconst p = Perm.Also;");
	assert js.ok, js.ok ? "" : js.error;
	assert js.value.contains("_Both = 3;") && js.value.contains("_Also = 3;"), js.value;
}

test "bug211: a negated shift folds on C" {
	const c = compileToC("enum Neg { D = -(1 << 3) }\nconst n = Neg.D;");
	assert c.ok, c.ok ? "" : c.error;
	assert c.value.contains(")-8))"), c.value;
}

test "bug211: a member initialised in a function body folds" {
	const js = compileToJS("function f(): int32 {\n\tenum L { P = 3, Q = P * 2 }\n\treturn L.Q as int32;\n}");
	assert js.ok, js.ok ? "" : js.error;
	assert js.value.contains("_Q = 6;"), js.value;
}

test "bug211: a call initializer is an error naming the member" {
	const js = compileToJS("function f(): int32 { return 1; }\nenum E { A = f() }");
	assert !js.ok && js.error.contains("Enum member 'A'"), js.ok ? "compiled" : js.error;
}

test "bug211: a later member is an error naming both" {
	const js = compileToJS("enum E { A = B, B }");
	assert !js.ok && js.error.contains("Enum member 'A' uses 'B' before it is declared"), js.ok ? "compiled" : js.error;
}

test "bug211: a value past int32 is an error" {
	const js = compileToJS("enum E { A = 4294967296 }");
	assert !js.ok && js.error.contains("cannot convert 4294967296 to int32"), js.ok ? "compiled" : js.error;
}

test "bug211: an initializer that does not fold is an error naming the member" {
	const js = compileToJS("enum E { A = 1 << 32 }");
	assert !js.ok && js.error.contains("Enum member 'A' initializer does not fold"), js.ok ? "compiled" : js.error;
}
