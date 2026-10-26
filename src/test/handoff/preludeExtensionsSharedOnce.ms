import { compileProjectToCWithStd, compileToCWithStd, compileToJSWithStd } from "../helpers";
import { MapEntry } from "../../module/loader";
import { exportLayerBuildCount } from "../../checker/context";

test "every module bind and comptime block reads the prelude extensions from one shared layer" {
	const entries: MapEntry[] = [
		{ entryPath: "/src/lib1.ms", entrySource: "export function one(s: string): string { return s.trim().repeat(2); }" },
		{ entryPath: "/src/lib2.ms", entrySource: "export function two(s: string): string { return s.padStart(4, \"*\"); }" },
		{ entryPath: "/src/main.ms", entrySource: `import { one } from "./lib1";
import { two } from "./lib2";
const K: int32 = @comptime { return "ab".repeat(3).length; };
console.log(one(" a "), two("b"), K);
` },
	];
	const before = exportLayerBuildCount();
	const c = compileProjectToCWithStd(entries, "/src/main.ms");
	assert !c.startsWith("ERROR"), c;
	const builds = exportLayerBuildCount() - before;
	assert builds <= 2, `prelude extensions registered ${builds} times for two preludes`;
}

const OVERLOAD_AND_SHADOW = `
function repeat(this s: string, sep: string): string { return s + sep + s; }
function trim(this s: string): string { return "<" + s + ">"; }
console.log("ab".repeat(2));
console.log("ab".repeat("-"));
console.log(" x ".trim());
`;

test "a user extension overloading or shadowing a prelude one resolves on C" {
	const r = compileToCWithStd(OVERLOAD_AND_SHADOW);
	assert r.ok, r.ok ? "" : r.error;
}

test "a user extension overloading or shadowing a prelude one resolves on JS" {
	const r = compileToJSWithStd(OVERLOAD_AND_SHADOW);
	assert r.ok, r.ok ? "" : r.error;
}
