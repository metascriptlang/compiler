// bug043 — C-header-import pipeline: three bugs found binding Facebook Yoga
//
// Symptom:    (a) `import {...} from "lib/Umbrella.h"` where the umbrella is
//             only `#include <lib/*.h>` lines yielded ZERO symbols — every
//             imported name errored "Undefined variable". (b) Once includes
//             resolved, any header whose last line is a `#define` with no
//             trailing newline crashed the compiler (null deref in
//             preprocess2). (c) An entry whose `function main` is preceded
//             by module-level decorators (@passC/@passL/...) type-checked
//             fine but its main/helpers vanished from codegen — the real
//             build then failed linking `<entry>__Init000`.
//
// Root cause: (a) loader.ms inlineHeaderImports include paths lacked the
//             header's PARENT dir, so `#include <lib/foo.h>` never resolved
//             (and translateCHeader drops preprocessor diagnostics, so the
//             failure was silent). (b) preprocess.ms copyLine returned
//             tok.next == null as "rest" when the line ran to EOF;
//             readMacroDefinition passed the null into preprocess2.
//             (c) reachability.ms computeAliveSet root scan matched raw
//             stmt kinds — a DecoratedDecl-wrapped `main` was invisible, so
//             Root 1 never fired and the entry module went dead wholesale.
//
// Fix:        loader.ms (+headerParentDir in includePaths),
//             preprocess.ms (copyLine returns the EOF token as rest),
//             reachability.ms (root scan unwraps DecoratedDecl, mirroring
//             matchDeclName).

import { compileProjectToC } from "../helpers";
import { inlineHeaderImports, createFileSystemProvider } from "../../module/loader";
import { ModuleError } from "../../module/graph";
import { writeFile, ensureDir, readFile } from "std/fs";

test "bug043: decorated main and its callees survive DCE" {
	const entries = [{
		entryPath: "bug043/main.ms",
		entrySource: `function helper043(): number { return 42; }
@passL("-lm")
function main(): void {
	const x = helper043();
}
`,
	}];
	const c = compileProjectToC(entries, "bug043/main.ms");
	assert !c.startsWith("ERROR:");
	assert c.indexOf("void main_") >= 0;
	assert c.indexOf("helper043") >= 0;
}

test "bug043: umbrella header with <lib/...> transitive includes resolves symbols" {
	ensureDir("/tmp/msbug043/mylib");
	writeFile("/tmp/msbug043/mylib/a.h", "typedef struct Bug043S* Bug043Ref;\nint bug043A(Bug043Ref r);\n");
	// b.h ends in a #define with NO trailing newline — pre-fix this crashed
	// the preprocessor (copyLine EOF), independently of the include-path fix.
	writeFile("/tmp/msbug043/mylib/b.h", "int bug043B(Bug043Ref r);\n#define BUG043_TAIL(x) x");
	writeFile("/tmp/msbug043/mylib/Umbrella.h", "#include <mylib/a.h>\n#include <mylib/b.h>\n");
	// Specifier assembled by concatenation: the bun test harness transpiler
	// regex-rewrites `from "<spec>"` occurrences even inside string literals.
	const source = "import { bug043A, bug043B } from " + "\"./mylib/Umbrella.h\";\n";
	const inlined = inlineHeaderImports(source, "/tmp/msbug043/main.ms", createFileSystemProvider());
	assert inlined.indexOf("extern function bug043A") >= 0;
	assert inlined.indexOf("extern function bug043B") >= 0;
}

test "bug043: quoted sibling #include resolves via the including file's directory" {
	ensureDir("/tmp/msbug043/t/sub");
	writeFile("/tmp/msbug043/t/top.h", "#include \"sub/outer.h\"\n");
	writeFile("/tmp/msbug043/t/sub/outer.h", "#include \"inner.h\"\n");
	writeFile("/tmp/msbug043/t/sub/inner.h", "int bug043Sib(void);\n");
	const src = "import { bug043Sib } from " + "\"./t/top.h\";\n";
	const errs: ModuleError[] = [];
	const inlined = inlineHeaderImports(src, "/tmp/msbug043/main.ms", createFileSystemProvider(), false, errs);
	assert inlined.indexOf("extern function bug043Sib") >= 0;
	assert errs.length === 0;
}

test "bug043: two headers sharing a typedef import into one module without duplicate decls" {
	ensureDir("/tmp/msbug043/mylib");
	writeFile("/tmp/msbug043/mylib/c1.h", "typedef struct Bug043T* Bug043TRef;\nint bug043C1(Bug043TRef r);\n");
	writeFile("/tmp/msbug043/mylib/c2.h", "typedef struct Bug043T* Bug043TRef;\nint bug043C2(Bug043TRef r);\n");
	const src = "import { bug043C1 } from " + "\"./mylib/c1.h\";\n"
		+ "import { bug043C2 } from " + "\"./mylib/c2.h\";\n";
	const inlined = inlineHeaderImports(src, "/tmp/msbug043/main.ms", createFileSystemProvider());
	assert inlined.indexOf("bug043C1") >= 0;
	assert inlined.indexOf("bug043C2") >= 0;
	const firstDecl = inlined.indexOf("Bug043TRef =");
	assert firstDecl >= 0;
	assert firstDecl === inlined.lastIndexOf("Bug043TRef =");
}
