// @stdout: same 1|never 6|deeper 3|string abc|lit 5
function pick<A, B>(flag: boolean, a: A, b: B): A | B {
	if (flag) return a;
	return b;
}
function never1<A>(a: A): A | never { return a; }
function three<A, B, C>(i: int32, a: A, b: B, c: C): A | B | C {
	if (i == 0) return a;
	if (i == 1) return b;
	return c;
}
function mixed<A, B>(a: A, b: B, flag: boolean): A | B {
	return flag ? a : b;
}
const x = pick(true, 1 as int32, 2 as int32);
const y = never1(5 as int32);
const z = three(2, 1 as int32, 2 as int32, 3 as int32);
const s = mixed("abc", "def", true);
const l = never1("lit".length as int32);
console.log(`same ${x}|never ${y + 1}|deeper ${z}|string ${s}|lit ${l + 2}`);
