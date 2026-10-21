// @stdout: $ true true true true|dollarEnv_ true true true true|closure 9
// note: a user class whose name starts like a compiler-made one is still one type in every
// module. C used to give it a TypeInfo per module, so `instanceof` across modules was false.
import { $base, $kid, dollarEnv_base, dollarEnv_kid, makeKid, isKid, makeEnvKid, isEnvKid } from "./lib";

const a = makeKid(3);
const b: $base = new $kid(4);
const c = makeEnvKid(5);
const d: dollarEnv_base = new dollarEnv_kid(6);
const bump = 1;
const add = (x: $base): int32 => x.v + bump;
console.log([
	`$ ${a instanceof $kid} ${b instanceof $kid} ${isKid(a)} ${isKid(b)}`,
	`dollarEnv_ ${c instanceof dollarEnv_kid} ${d instanceof dollarEnv_kid} ${isEnvKid(c)} ${isEnvKid(d)}`,
	`closure ${add(a) + add(b)}`,
].join("|"));
