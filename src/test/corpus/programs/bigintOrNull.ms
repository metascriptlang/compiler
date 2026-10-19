// @stdout: null true false true false | false true true true false | true true false true true false true | 6 7 | null 5 anullb5 null 5 | true 14 null | 9 null true | 14 2 5 null 3 | F F T if-F | true true false | 5 6 null 5n
// @xfail(raiser): bigint is not supported on the Raiser VM
// note: bigint | null is a nullable pointer on C (null is the NULL pointer) that keeps its TS meaning on C and JS: == null tests the pointer, == against a value compares values, text prints "null" or the digits, 0n is falsy, tuples compare the values and x! on a value reads it. C used to stop in the transform or in the C compiler, and JS printed <object> for String() and console.log.

class Holder { x: bigint | null = null; }
type Box = { x: bigint | null };
function nb(v: bigint | null): bigint | null { return v; }

const none = nb(null);
const five = nb(5n);
const parts: string[] = [];
parts.push(`${none} ${none == null} ${none != null} ${none === null} ${none !== null}`);
parts.push(`${five == null} ${five != null} ${null != five} ${five !== null} ${five === null}`);
parts.push(`${five == 5n} ${5n == five} ${none == 5n} ${five == nb(5n)} ${none == nb(null)} ${five == none} ${five != 6n}`);
const sum = five != null ? five + 1n : 0n;
let next = 0n;
if (five !== null) next = five + 2n;
parts.push(`${sum} ${next}`);
parts.push(`${none} ${five} ${"a" + none + "b" + five} ${String(none)} ${String(five)}`);
const h = new Holder();
const fresh = h.x == null;
h.x = 7n;
const doubled = h.x != null ? h.x * 2n : 0n;
h.x = null;
parts.push(`${fresh} ${doubled} ${h.x}`);
const b: Box = { x: 9n };
const c: Box = { x: null };
parts.push(`${b.x} ${c.x} ${b.x == 9n && c.x == null}`);
const arr: (bigint | null)[] = [1n, null, 3n];
arr.push(null);
arr.push(10n);
let total = 0n;
let nulls = 0;
for (const v of arr) {
	if (v != null) { total += v; } else { nulls += 1; }
}
parts.push(`${total} ${nulls} ${arr.length} ${arr[1]} ${arr[2]}`);
const zero = nb(0n);
const truth: string[] = [zero ? "T" : "F", none ? "T" : "F", !zero ? "T" : "F"];
if (zero) { truth.push("if-T"); } else { truth.push("if-F"); }
parts.push(truth.join(" "));
const t1: [bigint | null, int32] = [nb(5n), 1];
const t2: [bigint | null, int32] = [nb(5n), 1];
const t3: [bigint | null, int32] = [null, 1];
const t4: [bigint | null, int32] = [none, 1];
parts.push(`${t1 == t2} ${t3 == t4} ${t1 == t3}`);
parts.push(`${five!} ${five! + 1n}`);
console.log(parts.join(" | "), none, five);
