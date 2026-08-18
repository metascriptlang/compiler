// An immediately-invoked function is a call whose CALLEE is a function
// expression, so the emitter has to parenthesize it: `(() => 5)()`, never
// `() => 5()` — the latter parses as an arrow returning `5()`, i.e. the value
// becomes the function itself. A block body degrades further, to a
// SyntaxError at load time.
//
// C has always been right here because it lowers the lambda to a named
// function before emission; only a backend that prints the callee back as
// source can lose the parentheses, which is why this is a parity program.

const inlineValue = (() => 41 + 1)();

const counter = (() => {
	let n = 0;
	return { bump: () => { n = n + 1; return n; } };
})();

function main(): void {
	console.log(inlineValue.toString());
	console.log(counter.bump().toString());
	console.log(counter.bump().toString());
}
main();
