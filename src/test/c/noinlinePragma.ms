import { compileToC } from "../helpers";

function emitted(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : "error: " + c.error;
}

test "@noinline: a module function keeps the noinline attribute on its prototype and definition" {
	const c = emitted(`@noinline function wide(a: int32): int32 { return a * 3; }
		function narrow(a: int32): int32 { return a + 1; }
		console.log(wide(2) + narrow(3));`);
	assert c.split("__attribute__((noinline))").length - 1 >= 2, c.slice(0, 400);
	const at = c.indexOf("__attribute__((noinline))");
	assert at >= 0 && c.slice(at, at + 120).includes("wide"), c.slice(0, 400);
	assert !c.includes("__attribute__((noinline)) MS_LIB_PRIVATE int32_t narrow"), c.slice(0, 400);
}

test "@noinline: an exported function keeps the attribute" {
	const c = emitted(`@noinline export function shared(a: int32): int32 { return a * 5; }
		console.log(shared(2));`);
	const at = c.indexOf("__attribute__((noinline))");
	assert at >= 0 && c.slice(at, at + 120).includes("shared"), c.slice(0, 400);
}

test "@noinline: anything but a function is refused" {
	const c = emitted(`@noinline class Box { value: int32 = 1; }
		console.log(new Box().value);`);
	assert c.includes("@noinline applies to a function"), c.slice(0, 400);
}

test "@noinline: a function marked @inline too is refused" {
	const c = emitted(`@inline @noinline function both(a: int32): int32 { return a * 7; }
		console.log(both(2));`);
	assert c.includes("cannot be both @inline and @noinline"), c.slice(0, 400);
}
