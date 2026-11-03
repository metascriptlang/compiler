import { compileToC } from "../helpers";

function emitted(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : "error: " + c.error;
}

test "@pure: a declaration with a body is refused, since its body is what the checker reads" {
	const c = emitted(`@pure function twice(a: int32): int32 { return a * 2; }
		console.log(twice(2));`);
	assert c.includes("@pure applies to an extern declaration"), c.slice(0, 400);
}

test "@pure: a method with a body is refused too" {
	const c = emitted(`class Box { n: int32 = 1; }
		@pure function bumped(this b: Box): int32 { return b.n + 1; }
		console.log(new Box().bumped());`);
	assert c.includes("@pure applies to an extern declaration"), c.slice(0, 400);
}
