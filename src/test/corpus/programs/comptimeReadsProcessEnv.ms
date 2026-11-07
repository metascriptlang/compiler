// @stdout: true true | true
// @xfail(js): a comptime helper on JS compiles the .jms variant of std/process, whose @emit the engine cannot run (inbox 2026-10-19-macro-on-js-runs-the-jms-variant-of-its-imports)
// @xfail(esm): the same JS gap as @xfail(js)
// note: `env.get` of std/process, a std class the comptime engine has no tier of, runs at comptime in a block and through a helper. Before, the block stopped with "Property 'get' does not exist on type 'env'" and the helper with "cannot evaluate 'env_get' at comptime".
import { env } from "std/process";

function pathSet(): boolean {
	return env.get("PATH") != "";
}

const IN_BLOCK = @comptime { return env.get("PATH") != ""; };
const IN_HELPER = @comptime { return pathSet(); };

console.log(`${IN_BLOCK} ${IN_HELPER} | ${pathSet()}`);
