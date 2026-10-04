// @stdout: generic=number 2 | string a | any concrete=number 3 | string b | boolean true keys=42 99 signer=99
// note: a module that imports a routine and declares its own of the same name calls both from inside (the imported one is gathered at the call), exports only its own, and on JS emits its own under a slot no imported routine uses. Same output on every backend.
import { viaGeneric } from "./generic";
import { viaConcrete } from "./concrete";
import { Account } from "./account";
import { Signer, bothKeys, key } from "./signer";

const raw: Account = { address: 21 };
const s = raw as Signer;
console.log(`generic=${viaGeneric(2, "a", true)} concrete=${viaConcrete(3, "b", true)} keys=${bothKeys(raw, s)} signer=${key(s)}`);
