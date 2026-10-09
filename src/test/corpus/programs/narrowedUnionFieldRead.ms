// @stdout: concat=s3 add=4 template=t3 local=6 str=w=q1 this=m5 nested=n3 after=z bump=b4 elem=e1 assigned=a4 struct=8 param=2
// note: a field whose declared type is a union, read after `typeof` narrows it, is read as the narrowed member wherever it is used, while a write to it still stores a whole union value.

class H {
	v: int32 | string = 3;
	w: string | int32 = "q";
}
class O { h: H = new H(); }
struct S { v: int32 | string; }
class M {
	v: int32 | string = 5;
	show(): string {
		if (typeof this.v === "number") { return "this=m" + this.v; }
		return "this=?";
	}
}

function viaParam(p: S): string {
	if (typeof p.v === "number") { return "param=" + p.v; }
	return "param=?";
}

const out: string[] = [];
const h = new H();
if (typeof h.v === "number") {
	out.push("concat=s" + h.v);
	out.push(`add=${h.v + 1}`);
	out.push(`template=t${h.v}`);
	console.log(h.v);
	const n = h.v;
	out.push(`local=${n * 2}`);
}
if (typeof h.w === "string") { out.push("str=w=" + h.w + h.w.length); }
out.push(new M().show());
const o = new O();
if (typeof o.h.v === "number") { out.push("nested=n" + o.h.v); }
h.v = "z";
if (typeof h.v === "string") {
	out.push("after=" + h.v);
	h.v = 3;
}
if (typeof h.v === "number") {
	h.v++;
	out.push("bump=b" + h.v);
}
const elems: (int32 | string)[] = [1, "s"];
if (typeof elems[0] === "number") { out.push("elem=e" + elems[0]); }
h.v = 4;
if (typeof h.v === "number") { out.push("assigned=a" + h.v); }
const st: S = { v: 7 };
if (typeof st.v === "number") { out.push(`struct=${st.v + 1}`); }
out.push(viaParam({ v: 2 }));
console.log(out.join(" "));
