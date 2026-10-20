// @stdout: methods -5 200 -30000 60000 x:-5 2 2
// @stdout: builtins -5 7 -30000 2 1x 2
// note: no float32 value is printed: a float32 read through a promise is 0 on C
//   (inbox 2026-10-19-c-a-float32-through-a-promise-reads-zero); handoff/genericArgFit.ms
//   types Promise.resolve<float32>(5) instead.

struct P { a: int32; b: string; }

class Holder {
	keep<T>(v: T): T { return v; }
	pair<A, B>(a: A, b: B): string { return `${a}:${b}`; }
	static skeep<T>(v: T): T { return v; }
}

class Box<T> {
	static make(v: T): T { return v; }
	with<U>(u: U): U { return u; }
}

const h = new Holder();
const box = new Box<string>();
const i8 = h.keep<int8>(-5);
const u8 = Holder.skeep<uint8>(200);
const i16 = Box.make<int16>(-30000);
const u16 = box.with<uint16>(60000);
const xs = h.keep<number[]>([1, 2]);
const ys = Holder.skeep<number[]>([1, 2]);
const wi8: int8 = i8;
const wu8: uint8 = u8;
const wi16: int16 = i16;
const wu16: uint16 = u16;
const paired = h.pair<string, int8>("x", -5);
console.log(`methods ${wi8} ${wu8} ${wi16} ${wu16} ${paired} ${xs.length} ${ys.length}`);

const r8 = Promise.resolve<int8>(-5);
const ru8 = Promise.resolve<uint8>(7);
const r16 = Promise.resolve<int16>(-30000);
const rxs = Promise.resolve<number[]>([1, 2]);
const rp = Promise.resolve<P>({ a: 1, b: "x" });
const a8: int8 = await r8;
const au8: uint8 = await ru8;
const a16: int16 = await r16;
const axs = await rxs;
const ap = await rp;
const ok = Result.ok<number[], string>([1, 2]);
let okLength: int32 = 0;
if (ok.ok) okLength = ok.value.length;
console.log(`builtins ${a8} ${au8} ${a16} ${axs.length} ${ap.a}${ap.b} ${okLength}`);
