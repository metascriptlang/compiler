// @stdout: len 3 sum 3 | put 2 | map 7 | ok
// note: an int32 argument meets a generic parameter instantiated as a union with a `number` member (`push` on `(string | number)[]`, a user `put<T>`, `Map.set`). The plain call path widened it to float64 and tagged the member; the generic path only looked for an exact member, so C was handed a bare int where the union struct goes and clang refused it. Same output on every backend.
function put<T>(xs: T[], v: T): void { xs.push(v); }

const arr: (string | number)[] = [];
for (let i = 0; i < 3; i++) arr.push(i);
let sum: number = 0;
for (const x of arr) if (typeof x == "number") sum += x;

const other: (string | number)[] = ["a"];
const k: int32 = 2;
put(other, k);

const m = new Map<string, string | number>();
const seven: int32 = 7;
m.set("k", seven);

console.log(`len ${arr.length} sum ${sum} | put ${other.length} | map ${m.get("k")} | ok`);
