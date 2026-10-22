// @stdout: 7 1 9 | 7 1 2 | 7 x 1 | 5 d 2
// note: a field the author names with a leading `__` is an ordinary field: an object spread copies it,
// note: an untyped spread keeps it in the literal's type, and a class literal that omits it runs its initializer.
interface T { __k: int32; a: int32; b: int32 }
interface S { __k: int32; __s: string; a: int32 }
class C { __k: int32 = 5; __s: string = "d"; a: int32 = 1 }
const s: T = { __k: 7, a: 1, b: 2 };
const t: T = { ...s, b: 9 };
const w: T = { ...s };
const r: S = { __k: 7, __s: "x", a: 1 };
const u = { ...r };
const c: C = { a: 2 };
console.log(`${t.__k} ${t.a} ${t.b} | ${w.__k} ${w.a} ${w.b} | ${u.__k} ${u.__s} ${u.a} | ${c.__k} ${c.__s} ${c.a}`);
