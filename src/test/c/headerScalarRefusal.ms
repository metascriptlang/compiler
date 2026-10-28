// A refused numeric conversion into an imported scalar (a header's size_t or ssize_t, which
// cimport declares as `extern type <name>: <base> from "<name>"` with the target's width) names
// that typedef, so the suggested cast is the one that is right on every target.
// Sibling of importedScalarSpelling, which owns the imported-scalar emission contract.

import { compileToC } from "../helpers";

function refusal(decls: string, call: string): string {
	const result = compileToC(decls + "function f(): void {\n\t" + call + "\n}\nf();\n");
	return result.ok ? "ACCEPTED" : result.error;
}

test "C: uint64 into a 32-bit size_t is refused with 'as size_t'" {
	const e = refusal("extern type size_t: uint32 from \"size_t\";\nextern function takeIndex(i: size_t): size_t;\nconst i: int32 = 2;\n", "takeIndex(i as uint64);");
	assert e.contains("uint64 → size_t"), e;
	assert e.contains("write an explicit 'as size_t'"), e;
	assert !e.contains("uint32"), e;
}

test "C: int64 into a 32-bit ssize_t and into a 64-bit size_t name the typedef" {
	const signed = refusal("extern type ssize_t: int32 from \"ssize_t\";\nextern function takeSigned(i: ssize_t): ssize_t;\nconst i: int64 = 2;\n", "takeSigned(i as int64);");
	assert signed.contains("write an explicit 'as ssize_t'"), signed;
	const wide = refusal("extern type size_t: uint64 from \"size_t\";\nextern function takeIndex(i: size_t): size_t;\nconst i: int64 = 2;\n", "takeIndex(i);");
	assert wide.contains("write an explicit 'as size_t'"), wide;
}
