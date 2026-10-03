// @xfail(raiser): raiser runtime error: cannot evaluate 'headers' at comptime: symbol kind is Module (card 2026-09-26-raiser-namespace-import-module-symbol)
// @stdout: owners 1 2 0 2 11 ab cd 42

import { makeArr } from "./library";
import { Multi } from "./hub";
import { direct } from "./namespaceDirect";
import { throughHub } from "./namespaceHub";

enum Color { Red, Green, Blue }
type UserId = int32;
function helper(): int32 { return 42; }

@passC("-DENTRY_REACHABLE")
function main(): void {
	const colors = makeArr<Color>(null);
	colors.push(Color.Red);
	colors.push(Color.Blue);
	const ids = makeArr<UserId>(null);
	ids.push(11);
	console.log(`owners ${Multi.one()} ${Multi.two()} ${colors[0] as int32} ${colors[1] as int32} ${ids[0]} ${direct()} ${throughHub()} ${helper()}`);
}
main();
