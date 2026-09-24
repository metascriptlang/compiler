// @stdout: ovmerge lib-num main-str:a lib-num num str:b
// note: a module declares an overload of a function it imports. The importer's own symbol heads the set and carries the imported one; the imported symbol is never written, so `other.ms`, which imports the same `h`, still sees one signature. C used to fail to link (the local overload joined the imported copy and was never emitted), then to compile (the call to the imported member was not declared); JS exported a name it never defined.
import { h, tag } from "./lib";
import { viaOther } from "./other";

function h(s: string): string { return "main-str:" + s; }
function tag(this s: string): string { return "str:" + s; }

const n: number = 3;
console.log(`ovmerge ${h(1)} ${h("a")} ${viaOther()} ${n.tag()} ${"b".tag()}`);
