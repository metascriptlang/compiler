// @stdout: str:hello int:42 | str:hello int:42 | str:hello int:42 | str:hello int:42 | str:field int:7 | 1 s | str:assigned int:9
// note: a union reference narrowed to one member and then passed, declared, assigned or pushed into a union that lists its members in another order, or more of them, or with null, carries that member's value: the member is read from the source union and placed at its own position in the target. Same output on C, JS and the Raiser.
interface Holder { v: int32 | string; }

function show(v: string | int32): string {
	if (typeof v == "string") return "str:" + v;
	return "int:" + `${v}`;
}

function showWide(v: boolean | string | int32): string {
	if (typeof v == "string") return "str:" + v;
	if (typeof v == "boolean") return "bool";
	return "int:" + `${v}`;
}

function showPrefix(v: int32 | string | boolean): string {
	if (typeof v == "string") return "str:" + v;
	if (typeof v == "boolean") return "bool";
	return "int:" + `${v}`;
}

function showMaybe(v: string | int32 | null): string {
	if (v == null) return "null";
	if (typeof v == "string") return "str:" + v;
	return "int:" + `${v}`;
}

function seven(): int32 | string { return 7; }

function main(): void {
	const x: int32 | string = "hello";
	const z: int32 | string = 42;
	const reordered = show(x) + " " + show(z);
	const wider = showWide(x) + " " + showWide(z);
	const prefix = showPrefix(x) + " " + showPrefix(z);
	const maybe = showMaybe(x) + " " + showMaybe(z);
	const h: Holder = { v: "field" };
	let field = "";
	if (typeof h.v == "string") field = show(h.v);
	const a = seven();
	if (typeof a == "number") field = field + " " + show(a);
	const n: int32 | string = 1;
	const one: string | int32 = n;
	let m: string | int32 = 0;
	const s: int32 | string = "s";
	m = s;
	const declared = `${one} ${m}`;
	const arr: (string | int32)[] = [];
	const t: int32 | string = "assigned";
	const u: int32 | string = 9;
	arr.push(t);
	arr.push(u);
	console.log(`${reordered} | ${wider} | ${prefix} | ${maybe} | ${field} | ${declared} | ${show(arr[0])} ${show(arr[1])}`);
}

main();
