import { env } from "std/process";
import { removeAll } from "std/fs";
import { join } from "std/fs/path";
import { compileToC } from "../helpers";
import { resetBuildState } from "../../compiler/buildSession";
import { buildPreludeContext, preludeContextFor, checkProgramWithRegistry } from "../../checker/checkPass";
import { dispatchEntryCount, CheckerContext, ExportRegistry, errorCount } from "../../checker/context";
import { duVariantRegistry, TargetInfo } from "../../checker/types";
import { preludePackStats } from "../../checker/preludePack";
import { parseSource } from "../../parser/statements/validation";
import { resolveRuntimeDir } from "../../utils/path";
import { ModuleGraph, Module } from "../../module/graph";

const MAP_SRC = "const m = new Map<string, int32>();\nm.set(\"k\", 1);\nconst s = new HashSet<string>([\"a\"]);\nconsole.log(m.get(\"k\"), s.size);\n";
const CLASS_SRC = "class A { v: int32; constructor(v: int32 = 3) { this.v = v; } f(): int32 { return this.v; } }\nclass B extends A { f(): int32 { return this.v + 1; } }\nconst x: A = new B();\nconsole.log(x.f());\n";
const DU_SRC = "type Shape = { kind: \"c\", r: float64 } | { kind: \"s\", w: float64 };\nfunction area(s: Shape): float64 { return s.kind == \"c\" ? s.r * s.r : s.w * s.w; }\nconsole.log(area({ kind: \"c\", r: 2.0 }));\n";

const VIEW_SRC = "class Sym { name: string = \"\"; }\nfunction placedOf(m: Readonly<HashMap<Sym, Sym>>, s: Readonly<Sym>): Readonly<Sym> { return m.readonlyGet(s) ?? s; }\nconsole.log(placedOf(new HashMap<Sym, Sym>(), new Sym()).name);\n";

function perBuildTables(): string {
	return `${duVariantRegistry().length}|${dispatchEntryCount()}`;
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

const PACK_ENV = ["HOME", "MSC_NO_GLOBAL_CACHE", "MSC_NO_PRELUDE_PACK"];

function withPrivatePackCache(run: (std: string) => void): void {
	const prev = PACK_ENV.map((name: string): string => env.get(name));
	const home = `out/test/buildIsolationHome.${performance.now()}`;
	env.set("HOME", home);
	env.delete("MSC_NO_GLOBAL_CACHE");
	env.delete("MSC_NO_PRELUDE_PACK");
	try {
		run(join(resolveRuntimeDir(), "std"));
	} finally {
		for (let i = 0; i < PACK_ENV.length; i += 1) {
			if (prev[i] == "") env.delete(PACK_ENV[i]);
			else env.set(PACK_ENV[i], prev[i]);
		}
		removeAll(home);
	}
}

function freshPrelude(std: string): CheckerContext {
	resetBuildState();
	return buildPreludeContext(std, ".cms");
}

function servedFromPack(): boolean {
	return preludePackStats()[3] == 1;
}

function checkedAgainst(prelude: CheckerContext): string {
	const shapes: string[] = [];
	for (const src of [DU_SRC, CLASS_SRC, VIEW_SRC]) {
		const pr = parseSource(src);
		if (!pr.ok) return pr.error;
		const ctx = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
		shapes.push(`${errorCount(ctx)}:${perBuildTables()}`);
	}
	return shapes.join(" ");
}

test "a prelude served from a warm pack brings the per-build tables the prelude checked from source brings" {
	withPrivatePackCache((std: string): void => {
		freshPrelude(std);
		assert !servedFromPack();
		const checked = perBuildTables();
		freshPrelude(std);
		assert servedFromPack();
		assert checked != "0|0";
		assert perBuildTables() == checked;
	});
}

test "programs checked against a prelude served from a warm pack see what they see against the prelude checked from source" {
	withPrivatePackCache((std: string): void => {
		const checked = checkedAgainst(freshPrelude(std));
		assert !servedFromPack();
		assert checked.startsWith("0:") && !checked.contains(" 1:");
		const packed = freshPrelude(std);
		assert servedFromPack();
		assert checkedAgainst(packed) == checked, checkedAgainst(packed);
	});
}
