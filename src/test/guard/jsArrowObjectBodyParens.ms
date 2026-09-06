// jsArrowObjectBodyParens — an expression-bodied arrow whose body is an
// ObjectLiteral must emit parenthesized on JS.
//
// Pre-fix JS emission printed the body bare: `(): Theme => ({accent:"blue"})`
// became `() => { accent: "blue" }` — a BLOCK with a labeled statement,
// returning undefined. Compile-clean on both lanes; at runtime every
// object-valued arrow read undefined (Neon's <Ctx.Provider value={{...}}>
// crashed "Cannot read properties of undefined"). C was unaffected. The
// fixedbugs/harness lane cannot see it — generateJS normalizes the body
// before emit — only this CLI-built node-run does.
//
// GUARD-JS

interface Theme { accent: string; }

function pick(): Theme {
	const f = (): Theme => ({ accent: "blue" });
	return f();
}

function main(): void {
	const t = pick();
	if (t.accent != "blue") { console.log("GUARD-FAIL wrong accent " + t.accent); }
	console.log("GUARD-OK");
}
main();
