import { compileToC } from "../helpers";

function emitted(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : "error: " + c.error;
}

function loopOver(head: string, body: string): string {
	return `${head}
		function run(op: Op): int32 {
			let acc: int32 = 0;
			while (true) {
				${body}
			}
			return acc;
		}
		console.log(run(Op.A));`;
}

const abc = "enum Op { A, B, C }";
const abcSwitch = "@computedGoto; switch (op) { case Op.A: return 1; case Op.B: return 2; case Op.C: return 3; }";

test "@computedGoto: a marked loop keeps the directive and refuses nothing it can dispatch" {
	const c = emitted(loopOver(abc, abcSwitch));
	assert !c.startsWith("error:"), c.slice(0, 400);
}

test "@computedGoto: a switch with a default is not exhaustive" {
	const c = emitted(loopOver(abc, "@computedGoto; switch (op) { case Op.A: return 1; default: return 2; }"));
	assert c.includes("case statement must be exhaustive for computed goto"), c.slice(0, 400);
}

test "@computedGoto: an enum switch that leaves a member out is not exhaustive" {
	const c = emitted(loopOver(abc, "@computedGoto; switch (op) { case Op.A: return 1; case Op.B: return 2; }"));
	assert c.includes("case statement must be exhaustive for computed goto"), c.slice(0, 400);
}

test "@computedGoto: an enum with holes is refused" {
	const c = emitted(loopOver("enum Op { A = 0, B = 2 }", "@computedGoto; switch (op) { case Op.A: return 1; case Op.B: return 2; }"));
	assert c.includes("case statement cannot work on enums with holes for computed goto"), c.slice(0, 400);
}

test "@computedGoto: an enum that does not start at 0 is refused" {
	const c = emitted(loopOver("enum Op { A = 1, B = 2 }", "@computedGoto; switch (op) { case Op.A: return 1; case Op.B: return 2; }"));
	assert c.includes("case statement has to start at 0 for computed goto"), c.slice(0, 400);
}

test "@computedGoto: an enum of more than 10000 members is refused" {
	let members = "";
	for (let i = 0; i < 10001; i += 1) members = members + (i == 0 ? "" : ", ") + `M${i}`;
	const c = emitted(loopOver(`enum Op { ${members} }`, "@computedGoto; switch (op) { case Op.M0: return 1; }"));
	assert c.includes("case statement has too many cases for computed goto"), c.slice(0, 400);
}

test "@computedGoto: an int32 switch has too many cases" {
	const c = emitted(`function run(n: int32): int32 {
			while (true) { @computedGoto; switch (n) { case 0: return 1; case 1: return 2; } }
			return 0;
		}
		console.log(run(0));`);
	assert c.includes("case statement has too many cases for computed goto"), c.slice(0, 400);
}

test "@computedGoto: an int8 switch cannot start at 0" {
	const c = emitted(`function run(n: int8): int32 {
			while (true) { @computedGoto; switch (n) { case 0: return 1; case 1: return 2; } }
			return 0;
		}
		console.log(run(0));`);
	assert c.includes("case statement has to start at 0 for computed goto"), c.slice(0, 400);
}

test "@computedGoto: a uint8 switch that misses a value is not exhaustive" {
	const c = emitted(`function run(n: uint8): int32 {
			while (true) { @computedGoto; switch (n) { case 0: return 1; case 1: return 2; } }
			return 0;
		}
		console.log(run(0));`);
	assert c.includes("case statement must be exhaustive for computed goto"), c.slice(0, 400);
}

test "@computedGoto: a string switch has no table" {
	const c = emitted(`function run(s: string): int32 {
			while (true) { @computedGoto; switch (s) { case "a": return 1; case "b": return 2; } }
			return 0;
		}
		console.log(run("a"));`);
	assert c.includes("case statement needs an enum or integer value for computed goto"), c.slice(0, 400);
}

test "@computedGoto: a loop body without a switch is refused" {
	const c = emitted(loopOver(abc, "@computedGoto; acc += 1; if (acc > 3) return acc;"));
	assert c.includes("no case statement found for computed goto"), c.slice(0, 400);
}

test "@computedGoto: a loop that is not while (true) is refused" {
	const c = emitted(`${abc}
		function run(op: Op, n: int32): int32 {
			let k = 0;
			while (k < n) { @computedGoto; k += 1; switch (op) { case Op.A: break; case Op.B: break; case Op.C: break; } }
			return k;
		}
		console.log(run(Op.A, 3));`);
	assert c.includes("@computedGoto needs a 'while (true)' loop"), c.slice(0, 400);
}

test "@computedGoto: the directive takes no argument" {
	const c = emitted(loopOver(abc, "@computedGoto(1); switch (op) { case Op.A: return 1; case Op.B: return 2; case Op.C: return 3; }"));
	assert c.includes("@computedGoto takes no argument"), c.slice(0, 400);
}

test "@computedGoto: outside a while body is refused" {
	const c = emitted(`${abc}
		function run(op: Op): int32 {
			@computedGoto;
			switch (op) { case Op.A: return 1; case Op.B: return 2; case Op.C: return 3; }
			return 0;
		}
		console.log(run(Op.A));`);
	assert c.includes("@computedGoto must be a statement of a while loop body"), c.slice(0, 400);
}

test "@computedGoto: nested in a block of the loop body is refused" {
	const c = emitted(loopOver(abc, "{ @computedGoto; } switch (op) { case Op.A: return 1; case Op.B: return 2; case Op.C: return 3; }"));
	assert c.includes("@computedGoto must be a statement of a while loop body"), c.slice(0, 400);
}

test "@computedGoto: a declaration cannot carry it" {
	const c = emitted(`@computedGoto function f(): int32 { return 1; }
		console.log(f());`);
	assert c.includes("@computedGoto marks a statement of a while loop body, not a declaration"), c.slice(0, 400);
}
