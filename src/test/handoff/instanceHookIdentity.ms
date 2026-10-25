import { checkSource } from "./helpers";
import { lookupSymbol, makeSymbol } from "../../checker/symbol";
import { createContext } from "../../checker/context";
import { instanceArgsOf, sameCheckedInstance, distinctInstances, retainCheckedInstances, lookupInstanceHook } from "../../checker/instantiate";
import { createGenericInstance, createReadonlyView, unwrapRef, hasAsgnFlag } from "../../checker/types";
import { ctorRoutineOf } from "../../checker/ctorRoutine";
import { NodeKind, SymbolKind, FunctionDeclData, createNodeAt, makeLoc } from "../../ast/node";
import { makeIdentResolved, makeExprStmt } from "../../transform/util";
import { computeAliveSet } from "../../checker/reachability";
import { aliveSetHasSym } from "../../codegen/c/context";
import { createModuleGraph } from "../../module/graph";

const phantomSource = `
function phantom<T>(value: int32): int32 { return value + 1; }
const a = phantom<int32>(3);
const b = phantom<string>(4);
`;

test "instanceHookIdentity: placement keeps phantom arguments even when signatures and emission spellings agree" {
	const ctx = checkSource(phantomSource);
	assert ctx.errors.length == 0;
	const generic = lookupSymbol(ctx.table, "phantom");
	assert generic != null;
	const instances = ctx.procInstCache.get(generic);
	assert instances != null && instances.length == 2;
	const first = instances[0].sym;
	const second = instances[1].sym;
	second.name = first.name;
	(second.declNode!.data as FunctionDeclData).fnName = first.name;
	assert !sameCheckedInstance(first, second);
	assert distinctInstances([first.declNode!, second.declNode!]).length == 2;
	assert instanceArgsOf(first) == instances[0].concreteTypes;
}

test "instanceHookIdentity: independent requesters retain checked records without recreating signature arguments" {
	const ctx = checkSource(phantomSource);
	assert ctx.errors.length == 0;
	const generic = lookupSymbol(ctx.table, "phantom")!;
	const instances = ctx.procInstCache.get(generic)!;
	const requester = createContext();
	const copy = makeSymbol("differentEmissionSpelling", SymbolKind.Function, instances[0].sym.symbolType, false);
	copy.instantiatedFrom = generic;
	requester.procInstCache.set(generic, [{ sym: copy, concreteTypes: instances[0].concreteTypes }]);
	retainCheckedInstances([ctx, requester]);
	assert sameCheckedInstance(copy, instances[0].sym);
	assert !sameCheckedInstance(copy, instances[1].sym);
	const placed = distinctInstances([instances[0].sym.declNode!, instances[0].sym.declNode!, instances[1].sym.declNode!]);
	assert placed.length == 2;
}

test "instanceHookIdentity: readonly generic class constructors keep checked distinct emission names" {
	const ctx = checkSource(`
interface Cell { value: int32; }
class Box<T> { value: T; constructor(value: T) { this.value = value; } }
function view(value: Readonly<Cell>): int32 { const box = new Box<Readonly<Cell>>(value); return box.value.value; }
function change(value: Cell): int32 { const box = new Box<Cell>(value); box.value.value = 9; return box.value.value; }
`);
	assert ctx.errors.length == 0;
	const generic = lookupSymbol(ctx.table, "Box")!;
	const classes = ctx.typeInstCache.get(generic)!;
	assert classes.length == 2;
	assert !sameCheckedInstance(classes[0].sym, classes[1].sym);
	assert classes[0].sym.name != classes[1].sym.name;
	assert distinctInstances(ctx.generatedInstances).length == ctx.generatedInstances.length;
	for (const instance of classes) {
		const ctor = ctorRoutineOf(instance.sym)!;
		assert ctor.symbolKind == SymbolKind.Function;
		assert ctor.instantiatedFrom == ctorRoutineOf(generic);
		assert instanceArgsOf(ctor) == instance.concreteTypes;
	}
}

test "instanceHookIdentity: generic extension operations bind ordered capability arguments" {
	const ctx = checkSource(`
interface Cell { value: int32; }
interface Slot<T> { item: T; tag: int32; }
function onDestroy<T>(this self: Slot<T>): void { console.log(self.tag); }
function read(value: Readonly<Cell>): int32 { const slot: Slot<Readonly<Cell>> = { item: value, tag: 1 }; return slot.item.value; }
function change(value: Cell): int32 { const slot: Slot<Cell> = { item: value, tag: 2 }; slot.item.value = 9; return slot.item.value; }
`);
	assert ctx.errors.length == 0;
	const owner = lookupSymbol(ctx.table, "Slot")!;
	const cell = lookupSymbol(ctx.table, "Cell")!;
	const mutable = createGenericInstance(unwrapRef(owner.symbolType), [cell.symbolType]);
	const readonly = createGenericInstance(unwrapRef(owner.symbolType), [createReadonlyView(cell.symbolType)]);
	const mutableHook = lookupInstanceHook(mutable, "onDestroy");
	const readonlyHook = lookupInstanceHook(readonly, "onDestroy");
	assert mutableHook != null && readonlyHook != null;
	assert !sameCheckedInstance(mutableHook, readonlyHook);
	assert lookupInstanceHook(mutable, "onCopy") == null;
}

test "instanceHookIdentity: DCE follows an independent requester copy by phantom arguments rather than name" {
	const ctx = checkSource(phantomSource);
	assert ctx.errors.length == 0;
	const generic = lookupSymbol(ctx.table, "phantom")!;
	const instances = ctx.procInstCache.get(generic)!;
	const selected = instances[0].sym;
	const unused = instances[1].sym;
	unused.name = selected.name;
	(unused.declNode!.data as FunctionDeclData).fnName = selected.name;
	const requester = createContext();
	const copy = makeSymbol("unrelatedOutputName", SymbolKind.Function, selected.symbolType, false);
	copy.instantiatedFrom = generic;
	copy.modulePath = "/owner.ms";
	requester.procInstCache.set(generic, [{ sym: copy, concreteTypes: instances[0].concreteTypes }]);
	retainCheckedInstances([ctx, requester]);
	const loc = makeLoc(1, 1);
	const owner = createNodeAt(NodeKind.Program, { programStmts: [selected.declNode!, unused.declNode!] }, loc);
	const user = createNodeAt(NodeKind.Program, { programStmts: [makeExprStmt(makeIdentResolved(copy, loc), loc)] }, loc);
	const alive = computeAliveSet([owner, user], ["/owner.ms", "/user.ms"], "/user.ms", false, createModuleGraph());
	assert aliveSetHasSym(alive, selected);
	assert !aliveSetHasSym(alive, unused);
}

test "instanceHookIdentity: scalar generic user operations mark every equivalent checked owner managed" {
	const ctx = checkSource(`
struct Ticket<T> { value: T; tag: int32; }
function onDestroy<T>(this ref self: Ticket<T>): void { console.log(self.tag); }
const first: Ticket<int32> = { value: 3, tag: 1 };
const second: Ticket<int32> = { value: 4, tag: 2 };
`);
	assert ctx.errors.length == 0;
	const first = lookupSymbol(ctx.table, "first")!.symbolType;
	const second = lookupSymbol(ctx.table, "second")!.symbolType;
	assert hasAsgnFlag(first) && hasAsgnFlag(second);
	assert lookupInstanceHook(first, "onDestroy") != null;
	assert lookupInstanceHook(first, "onDestroy") == lookupInstanceHook(second, "onDestroy");
}

test "instanceHookIdentity: same-spelled nominal arguments from sibling scopes have distinct emitted class names" {
	const ctx = checkSource(`
class Box<T> { value: T; constructor(value: T) { this.value = value; } }
function left(): int32 { type Token = distinct int32; const box = new Box<Token>(1 as Token); return box.value as int32; }
function right(): int32 { type Token = distinct int32; const box = new Box<Token>(0 as Token); return box.value as int32; }
`);
	assert ctx.errors.length == 0;
	const generic = lookupSymbol(ctx.table, "Box")!;
	const classes = ctx.typeInstCache.get(generic)!;
	assert classes.length == 2;
	assert !sameCheckedInstance(classes[0].sym, classes[1].sym);
	assert classes[0].sym.name != classes[1].sym.name;
	assert classes[0].concreteTypes[0].sym!.disamb != classes[1].concreteTypes[0].sym!.disamb;
	assert classes[0].sym.disamb == 0 && classes[1].sym.disamb == 0;
	assert distinctInstances(ctx.generatedInstances).length == 2;
}
