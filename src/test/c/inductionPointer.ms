import { compileToC } from "../helpers";
import { hostTargetInfo } from "../../checker/types";

function vm(pcType: string, prelude: string, setup: string, mutableView: boolean = false): string {
	const codeParam = mutableView ? "src" : "code";
	const view = mutableView ? "let code: Span<int64> = src;" : "";
	return `${prelude}
enum Op { Push, Add, Jmp, Halt }
function run(${codeParam}: Span<int64>, stk: Span<int64>): int64 {
	${view}
	let pc: ${pcType} = 0;
	let sp: int64 = 0;
	${setup}
	while (true) {
		@computedGoto;
		const w = code[pc];
		pc += 1;
		const o = (w & 255) as Op;
		switch (o) {
			case Op.Push: { stk[sp] = w >> 8; sp += 1; break; }
			case Op.Add: { stk[sp - 2] = stk[sp - 2] + stk[sp - 1]; sp -= 1; break; }
			case Op.Jmp: { pc = pc + ((w >> 8) as ${pcType}); break; }
			case Op.Halt: return stk[sp - 1] + pc;
		}
	}
	return 0;
}
const prog: int64[] = [0x103, 0x203, 0x1, 0x3];
const stack: int64[] = [0, 0, 0, 0];
console.log(run(prog, stack));`;
}

function emitted(source: string, danger: boolean): string {
	const c = compileToC(source, hostTargetInfo(), false, true, danger);
	return c.ok ? c.value : "error: " + c.error;
}

function indexKept(c: string, ranPass: boolean): string {
	if (c.startsWith("error:")) return c.slice(0, 400);
	if (c.includes("dollarptr_pc")) return "pc was carried as a pointer";
	if (!c.includes("pc_1_ = 0LL") && !c.includes(").pc1")) return "pc is no longer an integer local";
	if (ranPass && !c.includes("dollarptr_sp_")) return "the pass left the whole function alone, so the bail proves nothing";
	if (!ranPass && c.includes("dollarptr_")) return "a checked build was rewritten";
	return "";
}

test "induction pointer: an int64 index of a Span parameter is carried as a pointer" {
	const c = emitted(vm("int64", "", ""), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes("dollarptr_pc_ = (code.data + 0LL)"), "no pointer initialiser for pc";
	assert c.includes("dollarptr_pc_[0]"), "code[pc] is not a read at the pointer";
	assert c.includes("(dollarptr_pc_ += 1LL)"), "pc += 1 does not step the pointer";
	assert c.includes("dollarptr_sp_[-2LL]"), "stk[sp - 2] is not a read at a negative offset";
	assert c.includes("(dollarptr_pc_ - code.data)"), "a read of pc is not the distance from the data";
	assert !c.includes("msSpanAccessUnchecked(code"), "code is still indexed";
	assert !c.includes("msSpanAccessUnchecked(stk"), "stk is still indexed";
}

test "induction pointer: i = i + e steps the pointer by e" {
	const c = emitted(vm("int64", "", ""), true);
	assert c.includes("dollarptr_pc_ += "), "pc = pc + e is not a pointer step";
	assert !c.includes("dollarptr_pc_ = (code.data + (dollarptr_pc_"), "pc = pc + e re-seated the pointer";
}

test "induction pointer: an int32 index is carried too and reads back as int32" {
	const c = emitted(vm("int32", "", ""), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes("dollarptr_pc_[0]"), "code[pc] is not a read at the pointer";
	assert c.includes("(int32_t)((dollarptr_pc_ - code.data))"), "a read of an int32 pc is not narrowed";
}

test "induction pointer: a checked build keeps every index" {
	const why = indexKept(emitted(vm("int64", "", ""), false), false);
	assert why == "", why;
}

test "induction pointer: a captured index stays an index" {
	const why = indexKept(emitted(vm("int64", "", "const peek = (): int64 => pc; console.log(peek());"), true), true);
	assert why == "", why;
}

test "induction pointer: an index passed as a ref argument stays an index" {
	const why = indexKept(emitted(vm("int64", "function bump(ref n: int64): void { n += 1; }", "bump(pc);"), true), true);
	assert why == "", why;
}

test "induction pointer: a rebound span keeps its index" {
	const why = indexKept(emitted(vm("int64", "", "code = src[0..2];", true), true), true);
	assert why == "", why;
}

test "induction pointer: an index that indexes two spans stays an index" {
	const why = indexKept(emitted(vm("int64", "", "console.log(stk[pc]);"), true), true);
	assert why == "", why;
}

test "induction pointer: an update the pass does not know stays an index" {
	const why = indexKept(emitted(vm("int64", "", "pc *= 1;"), true), true);
	assert why == "", why;
}

test "induction pointer: a bailed index leaves the other pairing of the function rewritten" {
	const c = emitted(vm("int64", "", "pc *= 1;"), true);
	assert c.includes("dollarptr_sp_[-2LL]"), "sp was dropped with pc";
}

test "induction pointer: a loop without @computedGoto is left alone" {
	const c = emitted(vm("int64", "", "").replace("@computedGoto;", ""), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes("dollarptr_"), "a plain loop was rewritten";
}
