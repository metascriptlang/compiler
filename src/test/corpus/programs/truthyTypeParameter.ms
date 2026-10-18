// @stdout: TFFFTF | TFTF | TTF | FTF | FTFTTF | 02020 | FTTTFF | 7 d 9 | FTFFT | TFTT | TTFF
// note: a condition on a value of type parameter T is chosen per instance: the same generic body tests a number, a string, a class and a nullable as TS does, also through a lambda typed by inferring T and through a local. The body used to test x.byteLength > 0 for every T, which died at the C compiler for a number and answered false for every number on JS.

class User { name: string; constructor(n: string) { this.name = n; } }
function maybeNum(v: number, on: boolean): number | null { return on ? v : null; }

function t<T>(x: T): string { return x ? "T" : "F"; }
function notT<T>(x: T): string { if (!x) { return "F"; } return "T"; }
function loopT<T>(x: T): string { let n = 0; while (x) { n++; if (n > 1) { break; } } return `${n}`; }
function both<A, B>(a: A, b: B): string { return (a && b ? "T" : "F") + (a || b ? "T" : "F"); }
function either<T>(x: T, y: T): T { return x || y; }
class Holder<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	has(): string { return this.v ? "T" : "F"; }
}
function probe<T>(when: () => T, truthy: (v: T) => boolean): string { return truthy(when()) ? "T" : "F"; }
function probeLocal<T>(when: () => T): string {
	const v = when();
	return v ? "T" : "F";
}

const parts: string[] = [];
const i5: int32 = 5;
const i0: int32 = 0;
parts.push(t<number>(5) + t<number>(0) + t<number>(-0) + t<number>(NaN) + t<int32>(i5) + t<int32>(i0));
parts.push(t<string>("hi") + t<string>("") + t<boolean>(true) + t<boolean>(false));
parts.push(t<User>(new User("u")) + t<number[]>([]) + t<User | null>(null));
parts.push(t<number | null>(maybeNum(0, true)) + t<number | null>(maybeNum(5, true)) + t<number | null>(maybeNum(5, false)));
parts.push(notT<number>(0) + notT<number>(2) + notT<string>("") + notT<string>("a") + notT<User>(new User("u")) + notT<number | null>(maybeNum(0, true)));
parts.push(loopT<number>(0) + loopT<number>(3) + loopT<string>("") + loopT<string>("x") + loopT<User | null>(null));
parts.push(both<number, string>(1, "") + both<number, string>(1, "a") + both<string, number>("", 0));
parts.push(`${either<number>(0, 7)} ${either<string>("", "d")} ${either<number | null>(maybeNum(0, true), 9)}`);
parts.push(new Holder<number>(0).has() + new Holder<number>(1).has() + new Holder<string>("").has() + new Holder<User | null>(null).has() + new Holder<User>(new User("v")).has());
parts.push(probe(() => 5, (v) => v ? true : false) + probe(() => 0, (v) => v ? true : false) + probe(() => "hi", (v) => v ? true : false) + probe(() => true, (v) => v ? true : false));
parts.push(probe<number>(() => 5, (v: number) => v ? true : false) + probeLocal<number>(() => 5) + probeLocal<number>(() => 0) + probeLocal<string>(() => ""));
console.log(parts.join(" | "));
