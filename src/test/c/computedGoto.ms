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

function countOf(text: string, needle: string): int32 {
	return (text.split(needle).length - 1) as int32;
}

const fetchLoop = (marked: boolean, post: string) => `enum Op { A, B, C }
	function run(code: Op[]): int32 {
		let pc = 0;
		let acc: int32 = 0;
		while (true) {
			${marked ? "@computedGoto;" : ""}
			const op = code[pc];
			pc += 1;
			switch (op) {
				case Op.A: acc += 1; break;
				case Op.B: acc += 2; break;
				case Op.C: return acc;
			}
			${post}
		}
	}
	console.log(run([Op.A, Op.B, Op.C]));`;

test "@computedGoto: a marked loop emits a label table and a dispatch at the end of every case" {
	const c = emitted(fetchLoop(true, ""));
	assert countOf(c, "static void* const __cgtbl") == 1, c.slice(0, 600);
	assert c.includes("&&__cg"), c.slice(0, 600);
	assert countOf(c, "goto *__cgtbl") == 3, c.slice(0, 600);
	assert !c.includes("switch (op_"), c.slice(0, 600);
}

test "@computedGoto: the loop without the mark keeps its C switch" {
	const c = emitted(fetchLoop(false, ""));
	assert !c.includes("goto *"), c.slice(0, 600);
	assert c.includes("switch (op_"), c.slice(0, 600);
}

test "@computedGoto: a local declared before the switch is declared once and assigned at each dispatch" {
	const c = emitted(fetchLoop(true, "acc += 0;"));
	assert countOf(c, "op_1_ = ") == 3, c.slice(0, 800);
	assert !c.includes("op_2_"), c.slice(0, 800);
}

test "@computedGoto: a statement after the switch is repeated in every case that falls out of it" {
	const c = emitted(fetchLoop(true, "acc += 7;"));
	assert countOf(c, "acc_1_ += 7") == 2 || countOf(c, "msAddAssign(acc_1_, 7)") == 2, c.slice(0, 800);
}

test "@computedGoto: a statement that cannot be repeated because it holds a label is refused" {
	const c = emitted(fetchLoop(true, "for (let i = 0; i < 2; i += 1) { if (i == 0) continue; acc += i; }"));
	assert c.includes("computed goto repeats the statements around the switch, and one of them holds a label"), c.slice(0, 600);
}

test "@computedGoto: a break that ends a case block lands on that case's own dispatch, never on a shared tail" {
	const c = emitted(`enum Op { A, B, C }
	function run(code: Op[]): int32 {
		let pc = 0;
		let acc: int32 = 0;
		while (true) {
			@computedGoto;
			const op = code[pc];
			pc += 1;
			switch (op) {
				case Op.A: { if (acc > 5) { acc += 1; } acc += 1; break; }
				case Op.B: { if (acc > 5) { acc += 2; } acc += 2; break; }
				case Op.C: return acc;
			}
		}
	}
	console.log(run([Op.A, Op.B, Op.C]));`);
	assert countOf(c, "goto *__cgtbl") == 3, c.slice(0, 1200);
	assert !c.includes("goto __sw"), c.slice(0, 1200);
	assert !c.includes("__sw1_x_"), c.slice(0, 1200);
}

function branchLoop(caseA: string): string {
	return `enum Op { A, B }
	function run(code: Op[]): int32 {
		let pc = 0;
		let acc: int32 = 0;
		while (true) {
			@computedGoto;
			const op = code[pc];
			pc += 1;
			switch (op) {
				case Op.A: { ${caseA} break; }
				case Op.B: return acc;
			}
		}
	}
	console.log(run([Op.A, Op.B]));`;
}

test "@computedGoto: an if without else at the end of a case dispatches on both paths" {
	const c = emitted(branchLoop("if (acc < 5) { acc += 1; }"));
	assert countOf(c, "goto *__cgtbl") == 3, c.slice(0, 1400);
}

test "@computedGoto: an if with else at the end of a case dispatches in each arm" {
	const c = emitted(branchLoop("if (acc < 5) { acc += 1; } else { acc += 2; }"));
	assert countOf(c, "goto *__cgtbl") == 3, c.slice(0, 1400);
}

test "@computedGoto: a nested if at the end of a case dispatches on every path" {
	const c = emitted(branchLoop("if (acc < 5) { if (acc < 3) { acc += 1; } } else if (acc > 9) { acc += 2; }"));
	assert countOf(c, "goto *__cgtbl") == 5, c.slice(0, 1800);
}
