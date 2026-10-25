// @stdout: plain hi 2 | generic hi 5 | free hi 1 | class none 7 | nullable none 1
interface G<T> { a: T; n: int32; }
interface N<T> { a: T | null; n: int32; }
class Box<T> { a: T | null = null; n: int32 = 7; }
interface H { a: string; n: int32; }
interface W { a: string | null; n: int32; }

function text(s: string | null): string { return s === null ? "none" : s as string; }

const g: G<string> = { a: "hi", n: 1 };
const plain: H = { ...g, n: 2 };
const generic: G<string> = { ...g, n: 5 };
const free = { ...g };
const fromClass: W = { ...new Box<string>() };
const nul: N<string> = { a: null, n: 1 };
const nullable: W = { ...nul };
console.log(`plain ${plain.a} ${plain.n} | generic ${generic.a} ${generic.n} | free ${free.a} ${free.n} | class ${text(fromClass.a)} ${fromClass.n} | nullable ${text(nullable.a)} ${nullable.n}`);
