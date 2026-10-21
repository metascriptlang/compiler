// @stdout: id 5 | 2.5 | s1 | true | 5 5 5 a=5 | T7
// note: a TS brand (`int32 & { __brand: "Id" }`) turns into text as its base in a template, String(),
// concatenation, console.log and `+=`, over int32, number, string and boolean, and a toString declared
// for the brand still wins. A user `distinct` stays refused (handoff/toStringUnified.ms).
type Id = int32 & { __brand: "Id" };
type Ratio = number & { __brand: "Ratio" };
type Name = string & { __brand: "Name" };
type Flag = boolean & { __brand: "Flag" };
type Tag = int32 & { __brand: "Tag" };

function toString(this t: Tag): string { return "T" + (t as int32).toString(); }

const id = 5 as Id;
const ratio = 2.5 as Ratio;
const name = "s1" as Name;
const flag = true as Flag;
const tag = 7 as Tag;
let acc = "a=";
acc += id;
console.log(`id ${id} | ${ratio} | ${name} | ${flag} | ${String(id)} ${"" + id} ${id.toString()} ${acc} | ${tag}`);
console.log(id);
console.log(name);
