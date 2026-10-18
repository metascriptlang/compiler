import { checkSource } from "./helpers";
import { lookupSymbol, makeSymbol } from "../../checker/symbol";
import { sameInstanceType, sameInstanceArgs } from "../../checker/instantiate";
import { createArray, createRef, createReadonlyView, createStruct, createEnum, createDistinct, int32Type, stringType } from "../../checker/types";
import { SymbolKind } from "../../ast/node";

test "instanceCacheIdentity: repeated checked arguments reuse function and class instances" {
	const ctx = checkSource(`
class Box<T> { value: T; constructor(value: T) { this.value = value; } }
function id<T>(value: T): T { return value; }
const a = new Box<int32>(id<int32>(3));
const b = new Box<int32>(id<int32>(4));
const c = new Box<string>(id<string>("x"));
`);
	assert ctx.errors.length == 0;
	const fn = lookupSymbol(ctx.table, "id");
	const cls = lookupSymbol(ctx.table, "Box");
	assert fn != null && cls != null;
	const procs = ctx.procInstCache.get(fn);
	const classes = ctx.typeInstCache.get(cls);
	assert procs != null && procs.length == 2;
	assert classes != null && classes.length == 2;
	assert sameInstanceArgs(procs[0].concreteTypes, classes[0].concreteTypes);
	assert !sameInstanceArgs(procs[0].concreteTypes, procs[1].concreteTypes);
}

test "instanceCacheIdentity: readonly arguments do not reuse mutable procedure instances" {
	const ctx = checkSource(`
interface Cell { value: int32; }
function id<T>(value: T): T { return value; }
function view(value: Readonly<Cell>): int32 { return id(value).value; }
function change(value: Cell): int32 { const result = id(value); result.value = 9; return result.value; }
`);
	assert ctx.errors.length == 0;
	const fn = lookupSymbol(ctx.table, "id");
	assert fn != null;
	const instances = ctx.procInstCache.get(fn);
	assert instances != null && instances.length == 2;
	assert !sameInstanceArgs(instances[0].concreteTypes, instances[1].concreteTypes);
}

test "instanceCacheIdentity: nominal declarations with equal spellings stay distinct" {
	const left = createEnum("Token", ["A", "B"], [0, 1]);
	const right = createEnum("Token", ["A", "B"], [0, 1]);
	left.sym = makeSymbol("Token", SymbolKind.Enum, left, false);
	right.sym = makeSymbol("Token", SymbolKind.Enum, right, false);
	assert !sameInstanceType(left, right);
	assert !sameInstanceType(createArray(left), createArray(right));
	const a = createDistinct(int32Type());
	const b = createDistinct(int32Type());
	a.typeName = "Id";
	b.typeName = "Id";
	a.sym = makeSymbol("Id", SymbolKind.TypeAlias, a, false);
	b.sym = makeSymbol("Id", SymbolKind.TypeAlias, b, false);
	assert !sameInstanceType(a, b);
}

test "instanceCacheIdentity: nested readonly capability is part of checked arguments" {
	const cell = createStruct("Cell", ["value"], [int32Type()], false);
	cell.sym = makeSymbol("Cell", SymbolKind.Interface, cell, false);
	const refCell = createRef(cell);
	const mutable = createArray(createArray(refCell));
	const readonly = createArray(createArray(createReadonlyView(refCell)));
	assert !sameInstanceType(mutable, readonly);
	assert sameInstanceType(mutable, createArray(createArray(refCell)));
	assert !sameInstanceArgs([int32Type(), stringType()], [stringType(), int32Type()]);
}

test "instanceCacheIdentity: recursive arguments compare their checked shape without a depth fallback" {
	const a = createStruct("", ["next", "value"], [], false);
	const b = createStruct("", ["next", "value"], [], false);
	a.typeChildren = [a, int32Type()];
	b.typeChildren = [b, stringType()];
	assert !sameInstanceType(a, b);
	b.typeChildren = [b, int32Type()];
	assert sameInstanceType(a, b);
}
