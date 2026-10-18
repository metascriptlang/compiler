// @stdout: during: caught Cannot access 'table' before initialization
// @stdout: after: fallback 1
// @xfail(js): node names the binding by its mangled JS name in the ReferenceError message (inbox 2026-10-16-js-tdz-message-names-the-mangled-binding)
// note: a const whose initializer calls a function that reads the const itself throws the ReferenceError JS throws; the initializer then completes with the caught value.
function build(): string[] {
	try {
		return [`size ${table.length}`];
	} catch (e) {
		console.log(`during: caught ${(e as Error).message}`);
		return ["fallback"];
	}
}
export const table: string[] = build();
console.log(`after: ${table[0]} ${table.length}`);
