import { env } from "std/process";
import { compileToC } from "../helpers";
import { resetBuildState } from "../../compiler/buildSession";
import { buildPreludeContext, preludeContextFor } from "../../checker/checkPass";
import { ctorDefaultsMark } from "../../checker/instantiate";
import { dispatchEntryCount } from "../../checker/context";
import { duVariantRegistry, TargetInfo } from "../../checker/types";
import { getGenericTypeInstCount } from "../../parser/context";

const MAP_SRC = "const m = new Map<string, int32>();\nm.set(\"k\", 1);\nconst s = new HashSet<string>([\"a\"]);\nconsole.log(m.get(\"k\"), s.size);\n";
const CLASS_SRC = "class A { v: int32; constructor(v: int32 = 3) { this.v = v; } f(): int32 { return this.v; } }\nclass B extends A { f(): int32 { return this.v + 1; } }\nconst x: A = new B();\nconsole.log(x.f());\n";
const DU_SRC = "type Shape = { kind: \"c\", r: float64 } | { kind: \"s\", w: float64 };\nfunction area(s: Shape): float64 { return s.kind == \"c\" ? s.r * s.r : s.w * s.w; }\nconsole.log(area({ kind: \"c\", r: 2.0 }));\n";

function perBuildTables(): string {
	return `${getGenericTypeInstCount()}|${duVariantRegistry().length}|${ctorDefaultsMark()}|${dispatchEntryCount()}`;
}

function sameC(a: Result<string, string>, b: Result<string, string>): boolean {
	return a.ok && b.ok && a.value == b.value;
}

test "a compile emits the same C whatever the compiles before it built" {
	const t32: TargetInfo = { ptrSize: 4, floatSize: 8, cpu: "i386", os: "linux" };
	const map1 = compileToC(MAP_SRC);
	const class1 = compileToC(CLASS_SRC);
	const du1 = compileToC(DU_SRC);
	const map32First = compileToC(MAP_SRC, t32);
	assert sameC(compileToC(MAP_SRC), map1);
	assert sameC(compileToC(CLASS_SRC), class1);
	assert sameC(compileToC(DU_SRC), du1);
	assert sameC(compileToC(MAP_SRC, t32), map32First);
}

test "a view of the shared prelude brings what loading that prelude puts in the per-build tables" {
	compileToC("const x: int32 = 1;\n");
	resetBuildState();
	const empty = perBuildTables();
	env.set("MSC_NO_PRELUDE_PACK", "1");
	try {
		buildPreludeContext("", ".cms");
	} finally {
		env.delete("MSC_NO_PRELUDE_PACK");
	}
	const loaded = perBuildTables();
	resetBuildState();
	assert perBuildTables() == empty;
	preludeContextFor("", ".cms");
	assert loaded != empty;
	assert perBuildTables() == loaded;
}
