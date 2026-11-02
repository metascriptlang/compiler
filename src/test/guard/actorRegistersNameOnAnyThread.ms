// INVARIANT: ULTRALOCK M1 and V0 (std state an actor reaches is safe on any pool thread).
// RED MEANS: an actor calling registerName is refused again, or concurrent registrations lose a name.
// GUARD-JS
// GUARD-TSAN

import { exit } from "std/process";
import { registerName, whereis } from "std/actor";

actor Named {
	claim(name: string): boolean { return registerName(this.pid, name); }
}

const actors: Named[] = [];
const claims: Promise<boolean>[] = [];
for (let i = 0; i < 16; i++) {
	const a = new Named();
	actors.push(a);
	claims.push(a.claim(`n${i}`));
}
let won = 0;
for (const c of claims) {
	if (await c) won++;
}
let found = 0;
for (let i = 0; i < 16; i++) {
	if (whereis(`n${i}`) == actors[i].pid) found++;
}
const again = await actors[0].claim("n1");
console.log(`registered ${won} found ${found} again ${again}`);
if (won != 16 || found != 16 || again) exit(1);
console.log("GUARD-OK");
