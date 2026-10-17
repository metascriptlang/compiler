function note(s: string): int32 { console.log(s); return 1; }
console.log("lib before");
export class K { static v: int32 = note("static K"); }
console.log("lib after");
