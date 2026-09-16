// Parity program — `@exportName` pins a function body's C symbol: the definition keeps the raw
// name instead of the module-qualified one, takes external linkage, and stays alive through
// dead-code elimination even when nothing in MetaScript calls it. Calling it back through an
// `extern` declaration is the proof, and it is a link-time one: a mangled, static or dropped
// definition fails to build. The bare form keeps the declared name, so the C symbol is camelCase
// here — the directive pins whatever name is asked for, snake_case is a convention of the host.
//
// @skip-js: `extern function` binds a C symbol; the JS backend has no C linkage
// @stdout: 42|7|49
// @exit: 0

@exportName("corpus778Answer")
function answer(): int32 {
	return 42;
}

@exportName
function corpus778Bare(): int32 {
	return 7;
}

extern function corpus778Answer(): int32;

function main(): void {
	const pinned = corpus778Answer();
	const bare = corpus778Bare();
	console.log(`${pinned}|${bare}|${pinned + bare}`);
}
main();
