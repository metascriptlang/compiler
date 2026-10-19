// filter, some, find and sort with a comparator, over numbers, strings and class instances.
// @stdout: 4,2|2 an|bo true|4|true false|bo,an,cu|4,3,2,1|a,b,c
class P { name: string; age: number; constructor(name: string, age: number) { this.name = name; this.age = age; } }
const xs: number[] = [3, 1, 4, 2];
const even = xs.filter((x: number): boolean => x % 2 === 0);
const ps: P[] = [new P("an", 30), new P("bo", 20), new P("cu", 40)];
const old = ps.filter((p: P, i: number): boolean => p.age > 25 && i >= 0);
const hit = ps.find((p: P): boolean => p.age == 20);
const miss = ps.find((p: P): boolean => p.age > 99);
const nf = xs.find((x: number): boolean => x > 3);
ps.sort((a: P, b: P): number => a.age - b.age);
xs.sort((a: number, b: number): number => b - a);
const ss: string[] = ["b", "c", "a"];
ss.sort((a: string, b: string): number => a < b ? -1 : (a > b ? 1 : 0));
console.log(`${even.join(",")}|${old.length} ${old[0].name}|${hit!.name} ${miss == null}|${nf}|${xs.some((x: number): boolean => x > 3)} ${ps.some((p: P): boolean => p.age > 99)}|${ps.map((p: P): string => p.name).join(",")}|${xs.join(",")}|${ss.join(",")}`);
