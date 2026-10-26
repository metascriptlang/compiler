// @stdout: 2 2 2 2 2 2 6
// note: Regression guard. PROVEN RED on the JS backend before the fix: an `await` inside a nested
//   routine made every enclosing plain function emit `async`, so `outer() + 1` added to a Promise.
//   Each case holds a nested async routine with its own await; the outer stays synchronous.
import { sleepAsync } from "std/core/promise";

let ran = 0;
const bump = async (): Promise<void> => { await sleepAsync(1); ran += 1; };

function viaArrow(): int32 {
	const run = async (): Promise<void> => { await bump(); };
	run();
	return 1;
}
function viaFunctionExpr(): int32 {
	const run = async function (): Promise<void> { await bump(); };
	run();
	return 1;
}
function viaFunctionDecl(): int32 {
	async function run(): Promise<void> { await bump(); }
	run();
	return 1;
}
function depth2(): int32 {
	const mid = (): void => {
		const run = async (): Promise<void> => { await bump(); };
		run();
	};
	mid();
	return 1;
}
function viaObjectLiteral(): int32 {
	const o = { go: async (): Promise<void> => { await bump(); } };
	o.go();
	return 1;
}
class K {
	viaMethod(): int32 {
		const run = async (): Promise<void> => { await bump(); };
		run();
		return 1;
	}
}

const line = [viaArrow() + 1, viaFunctionExpr() + 1, viaFunctionDecl() + 1, depth2() + 1, viaObjectLiteral() + 1, new K().viaMethod() + 1];
await sleepAsync(50);
console.log(line.join(" ") + " " + ran);
