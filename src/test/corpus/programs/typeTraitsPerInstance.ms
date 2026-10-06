// @stdout: traits-ok kind=plain,plain,managed,managed,managed,managed copy=share,copy,copy,copy,share,share only=4,3 chain=plain,flagless,managed lambda=share,copy box=plain,managed plain=1,1,1,0,0,1,1,0,1,1,0,1,0 copies=1,1,1,0,0,0,0,1
// note: isPlainData<T>() and needsCopy<T>() answer from the type while compiling, and a `when` that asks one picks its branch per generic instance; the untaken branch is never checked for that instance (`x.length` on int32), a flag `when` still decides at parse. Same output on every backend.
import { isPlainData, needsCopy } from "std/typetraits";

struct Plain { a: int32; b: int32; }
struct Named { a: int32; s: string; }
struct Pair<T> { a: T; b: T; }
struct Hooked { h: int32; }
class Pet { name: string = "x"; }
enum Color { Red, Green }
type Id = distinct int32;
type Word = "a" | "b";

let destroyed: int32 = 0;
function onDestroy(this ref s: Hooked): void { destroyed += 1; }

function kind<T>(x: T): string {
	when (isPlainData<T>()) {
		return "plain";
	} else {
		return "managed";
	}
}

function copies<T>(x: T): string {
	when (needsCopy<T>()) { return "copy"; } else { return "share"; }
}

function onlyPlain<T>(x: T): int32 {
	when (isPlainData<T>()) {
		return sizeof(T);
	} else {
		return x.length;
	}
}

function chain<T>(): string {
	when (noSuchFlag) {
		return "flag";
	} else when (isPlainData<T>()) {
		return "plain";
	} else when (!needsCopy<T>() && !noSuchFlag) {
		return "managed";
	}
	return "flagless";
}

function viaLambda<U>(x: U): string {
	const f = (): string => {
		when (needsCopy<U>()) { return "copy"; } else { return "share"; }
	};
	return f();
}

class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	describe(): string {
		when (isPlainData<T>()) { return "plain"; } else { return "managed"; }
	}
}

function bit(b: boolean): string {
	return b ? "1" : "0";
}

const v: Vec<int32> = [1, 2];
const p: Plain = { a: 1, b: 2 };
const n: Named = { a: 1, s: "s" };
const pet = new Pet();
const kinds = [kind(1 as int32), kind(p), kind(n), kind(v), kind(pet), kind("s")];
const copied = [copies(1 as int32), copies(p), copies(n), copies(v), copies(pet), copies("s")];
const plain = [
	isPlainData<int32>(),
	isPlainData<[int32, int32]>(),
	isPlainData<Pair<int32>>(),
	isPlainData<Pair<string>>(),
	isPlainData<Hooked>(),
	isPlainData<Color>(),
	isPlainData<Id>(),
	isPlainData<Word>(),
	isPlainData<Ptr<int32>>(),
	isPlainData<int32[4]>(),
	isPlainData<string[4]>(),
	isPlainData<int32 | null>(),
	isPlainData<int32[]>(),
];
const copyAnswers = [
	needsCopy<Pair<int32>>(),
	needsCopy<int32[4]>(),
	needsCopy<[int32, int32]>(),
	needsCopy<Color>(),
	needsCopy<Id>(),
	needsCopy<int32[]>(),
	needsCopy<Word>(),
	needsCopy<Vec<string>>(),
];
let plainBits = "";
for (let i = 0; i < plain.length; i += 1) plainBits += (i > 0 ? "," : "") + bit(plain[i]);
let copyBits = "";
for (let i = 0; i < copyAnswers.length; i += 1) copyBits += (i > 0 ? "," : "") + bit(copyAnswers[i]);
console.log("traits-ok kind=" + kinds.join(",") + " copy=" + copied.join(",")
	+ " only=" + onlyPlain(1 as int32).toString() + "," + onlyPlain("abc").toString()
	+ " chain=" + chain<int32>() + "," + chain<Vec<int32>>() + "," + chain<string>()
	+ " lambda=" + viaLambda(1 as int32) + "," + viaLambda(p)
	+ " box=" + new Box<int32>(1).describe() + "," + new Box<string>("s").describe()
	+ " plain=" + plainBits + " copies=" + copyBits);
