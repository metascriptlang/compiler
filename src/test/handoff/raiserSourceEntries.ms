import { compileToCWithStd } from "../helpers";
import { parseSource } from "../../parser/statements/validation";
import { checkProgram } from "../../checker/checkPass";
import { collectExports, hasErrors } from "../../checker/context";
import { Node } from "../../ast/node";
import { DynamicModulePlan } from "../../module/graph";
import {
	lowerForRaiser, generateRaiserProject, appendProgramToImage,
} from "../../codegen/raiser/rgen";
import { createFuncMap } from "../../codegen/raiser/context";
import { createRaiserFunction, createRaiserModule } from "../../raiser/module";
import { RaiserOpcode, RaiserRegClass, raiserABC } from "../../raiser/bytecode";
import { createVM, vmCallFunction } from "../../raiser/vm";
import { raiserInt, heapObjectGetField, rcDecref } from "../../raiser/value";

function lowered(source: string): Node {
	const parsed = parseSource(source);
	if (!parsed.ok) throw new Error("source did not parse");
	const ctx = checkProgram(parsed.value);
	if (hasErrors(ctx)) throw new Error("source did not check");
	return lowerForRaiser(parsed.value, ctx);
}

test "packed source entries: exported boxed entry returns the complete source record" {
	const parsed = parseSource(`
		struct Pair { x: int64; y: int64; }
		@noinline export function make(n: int64): Pair { return { x: n, y: n + 1 }; }
	`);
	assert parsed.ok;
	const ctx = checkProgram(parsed.value);
	assert !hasErrors(ctx);
	const exports = collectExports(ctx, ctx.modulePath);
	const mod = generateRaiserProject([{ modulePath: ctx.modulePath,
		program: lowerForRaiser(parsed.value, ctx) }], ctx.dispatchRegistry, new DynamicModulePlan(), exports);
	assert mod.exports.length == 1;
	const entry = mod.exports[0];
	assert mod.functions[entry.funcIdx].callShape == null;
	const vm = createVM(mod);
	const value = vmCallFunction(vm, entry.funcIdx, [raiserInt(7)]);
	assert vm.error == "", vm.error;
	assert heapObjectGetField(vm.arrayHeap, vm.objectHeap, value.intVal, "x").intVal == 7;
	assert heapObjectGetField(vm.arrayHeap, vm.objectHeap, value.intVal, "y").intVal == 8;
	rcDecref(vm.arrayHeap, vm.objectHeap, value);
}

test "packed source entries: append returns a direct body but keeps a separate legacy entry" {
	const halt = createRaiserFunction("halt", [raiserABC(RaiserOpcode.Halt, 0, 0, 0)], [], 0, 0, 1, [RaiserRegClass.Word]);
	const image = createRaiserModule("sourceEntries", [halt], 0);
	const map = createFuncMap();
	const first = appendProgramToImage(image, map, lowered(`
		struct Pair { x: int64; y: int64; }
		@noinline function make(n: int64): Pair { return { x: n, y: n + 1 }; }
	`), "make");
	const packed = map.packed.get(first);
	assert packed != null;
	assert image.functions[first].callShape != null;
	assert packed.entryIdx != first && image.functions[packed.entryIdx].callShape == null;
	const second = appendProgramToImage(image, map, lowered(`
		struct Other { a: int64; b: int64; c: int64; }
		@noinline function later(n: int64): Other { return { a: n, b: n + 2, c: n + 3 }; }
	`), "later");
	assert second > packed.entryIdx;
	const vm = createVM(image);
	const old = vmCallFunction(vm, packed.entryIdx, [raiserInt(11)]);
	assert vm.error == "", vm.error;
	assert heapObjectGetField(vm.arrayHeap, vm.objectHeap, old.intVal, "y").intVal == 12;
	rcDecref(vm.arrayHeap, vm.objectHeap, old);
	const newer = map.packed.get(second)!;
	const value = vmCallFunction(vm, newer.entryIdx, [raiserInt(20)]);
	assert vm.error == "", vm.error;
	assert heapObjectGetField(vm.arrayHeap, vm.objectHeap, value.intVal, "c").intVal == 23;
	rcDecref(vm.arrayHeap, vm.objectHeap, value);
}

test "packed source entries: an incremental helper can escape after its direct compilation" {
	const c = compileToCWithStd(`
		struct Pair { x: int32; y: int32; }
		@noinline function make(n: int32): Pair { return { x: n, y: n + 1 }; }
		@comptime function direct(): int32 { return make(2).x; }
		@comptime function escaped(): int32 { const f = make; return f(3).y; }
		const a = direct(); const b = escaped();
		console.log(a * 100 + b);
	`);
	assert c.ok, c.error;
	assert c.value.includes("204");
}
