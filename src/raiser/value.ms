// Raiser VM — Value representation
// Day-1: flat tagged interface. No NaN-boxing.
// Bool stored as intVal (0/1) to keep the interface simple.

import { test, check, testGroup } from "std/testing";

export enum RaiserValueKind {
	Nil,
	Bool,
	Int,        // i64 integer
	Float,      // f64 float
}

// Flat interface — all fields always present, unused ones zeroed.
// Matches project convention (see checker/types.ms Type interface).
export interface RaiserValue {
	kind: RaiserValueKind;
	intVal: number;
	floatVal: number;
}

// --- Constructors ---

export function raiserNil(): RaiserValue {
	return { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0 };
}

export function raiserBool(b: boolean): RaiserValue {
	let v = 0;
	if (b) { v = 1; }
	return { kind: RaiserValueKind.Bool, intVal: v, floatVal: 0.0 };
}

export function raiserInt(n: number): RaiserValue {
	return { kind: RaiserValueKind.Int, intVal: n, floatVal: 0.0 };
}

export function raiserFloat(f: number): RaiserValue {
	return { kind: RaiserValueKind.Float, intVal: 0, floatVal: f };
}

// --- Accessors ---

export function raiserToInt(v: RaiserValue): number {
	return v.intVal;
}

export function raiserToFloat(v: RaiserValue): number {
	if (v.kind === RaiserValueKind.Float) return v.floatVal;
	return v.intVal + 0.0;
}

export function raiserToBool(v: RaiserValue): boolean {
	if (v.kind === RaiserValueKind.Nil) return false;
	if (v.kind === RaiserValueKind.Bool) return v.intVal !== 0;
	if (v.kind === RaiserValueKind.Int) return v.intVal !== 0;
	return v.floatVal !== 0.0;
}

export function raiserIsNil(v: RaiserValue): boolean {
	return v.kind === RaiserValueKind.Nil;
}

// --- Equality ---

export function raiserEqual(a: RaiserValue, b: RaiserValue): boolean {
	if (a.kind !== b.kind) return false;
	if (a.kind === RaiserValueKind.Nil) return true;
	if (a.kind === RaiserValueKind.Bool) return a.intVal === b.intVal;
	if (a.kind === RaiserValueKind.Int) return a.intVal === b.intVal;
	if (a.kind === RaiserValueKind.Float) return a.floatVal === b.floatVal;
	return false;
}

// --- Debug ---

export function raiserToString(v: RaiserValue): string {
	if (v.kind === RaiserValueKind.Nil) return "nil";
	if (v.kind === RaiserValueKind.Bool) {
		if (v.intVal !== 0) return "true";
		return "false";
	}
	if (v.kind === RaiserValueKind.Int) return "" + v.intVal;
	if (v.kind === RaiserValueKind.Float) return "" + v.floatVal;
	return "?";
}

// --- Tests ---

testGroup("RaiserValue constructors", () => {
	test("nil", () => {
		const v = raiserNil();
		check(v.kind === RaiserValueKind.Nil);
		check(raiserIsNil(v));
		check(!raiserToBool(v));
	});

	test("bool true", () => {
		const v = raiserBool(true);
		check(v.kind === RaiserValueKind.Bool);
		check(v.intVal === 1);
		check(raiserToBool(v));
	});

	test("bool false", () => {
		const v = raiserBool(false);
		check(v.kind === RaiserValueKind.Bool);
		check(v.intVal === 0);
		check(!raiserToBool(v));
	});

	test("int", () => {
		const v = raiserInt(42);
		check(v.kind === RaiserValueKind.Int);
		check(raiserToInt(v) === 42);
		check(raiserToBool(v));
	});

	test("int zero is falsy", () => {
		const v = raiserInt(0);
		check(!raiserToBool(v));
	});

	test("float", () => {
		const v = raiserFloat(3.14);
		check(v.kind === RaiserValueKind.Float);
		check(v.floatVal === 3.14);
	});

	test("int to float conversion", () => {
		const v = raiserInt(5);
		check(raiserToFloat(v) === 5.0);
	});
});

testGroup("RaiserValue equality", () => {
	test("nil equals nil", () => {
		check(raiserEqual(raiserNil(), raiserNil()));
	});

	test("int equals same int", () => {
		check(raiserEqual(raiserInt(42), raiserInt(42)));
	});

	test("int not equals different int", () => {
		check(!raiserEqual(raiserInt(1), raiserInt(2)));
	});

	test("different kinds not equal", () => {
		check(!raiserEqual(raiserInt(0), raiserNil()));
		check(!raiserEqual(raiserInt(1), raiserBool(true)));
	});

	test("bool equality", () => {
		check(raiserEqual(raiserBool(true), raiserBool(true)));
		check(!raiserEqual(raiserBool(true), raiserBool(false)));
	});
});

testGroup("RaiserValue toString", () => {
	test("nil", () => { check(raiserToString(raiserNil()) === "nil"); });
	test("true", () => { check(raiserToString(raiserBool(true)) === "true"); });
	test("false", () => { check(raiserToString(raiserBool(false)) === "false"); });
	test("int", () => { check(raiserToString(raiserInt(42)) === "42"); });
});
