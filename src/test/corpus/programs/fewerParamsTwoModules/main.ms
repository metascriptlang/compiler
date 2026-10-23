// @stdout: left l< l~ 23 right r> r~ 34 main m! m~ 45
// Two modules and the entry each adapt a shorter function into the same slot shape and call an
// imported function whose default reads an earlier parameter, so the adapter parameters and
// default temps of every module are keyed apart by their owning module.
import { left } from "./left";
import { right } from "./right";
import { pad } from "./lib";

function tag(s: string): string { return s + "!"; }
function wide(f: (s: string, i: int32) => string): string { return f("m", 3); }

function main(): void {
	const padded = (): int32 => pad(4);
	console.log(`left ${left()} right ${right()} main ${wide(tag)} ${wide((s: string): string => s + "~")} ${padded()}`);
}

main();
