// @xfail(raiser): raiser runtime error: expected an object, got value kind Int
// Parity program — a generic function passed as a value to another generic
// function whose props carry a nullable function of the type parameter. The
// callee binds its own parameter to the uninstantiated props type, so the open
// `((item: T) => int32) | null` spelling meets the Maybe carrier its
// instantiation builds: both directions must relate, and the callback must
// still be the one the call site supplied.
//
// @stdout: keyed 42|plain 2|param 3|param none 0
// @exit: 0

interface Row { id: int32; }

function comp<P>(C: (props: P) => int32, props: P): int32 { return C(props); }

function sumKeys<T>(props: { each: () => T[]; key?: ((item: T) => int32) | null }): int32 {
	const items = props.each();
	const k = props.key;
	if (k == null) { return items.length as int32; }
	let sum = 0;
	for (const it of items) { sum += k(it); }
	return sum;
}

function orZero<T>(props: { each: () => T[]; fallback: T | null; read: (item: T) => int32 }): int32 {
	const f = props.fallback;
	if (f == null) { return 0; }
	return props.read(f);
}

function main(): void {
	const rows: Row[] = [{ id: 7 }, { id: 35 }];
	const spare: Row = { id: 3 };
	const keyed = comp(sumKeys, { each: () => rows, key: (r: Row) => r.id });
	const plain = comp(sumKeys, { each: () => rows });
	const param = comp(orZero, { each: () => rows, fallback: spare, read: (r: Row) => r.id });
	const paramNone = comp(orZero, { each: () => rows, fallback: null, read: (r: Row) => r.id });
	console.log("keyed " + keyed.toString() + "|plain " + plain.toString()
		+ "|param " + param.toString() + "|param none " + paramNone.toString());
}

main();
