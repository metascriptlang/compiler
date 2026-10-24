// Parity program — a template's free names are the declarations visible where the template is
// declared, not the ones visible where it is called: a private function of the template's module
// that the caller shadows, a module const the caller shadows with a local while passing that local
// as the argument, a statement template reading a const its caller cannot see, and a same-module
// template whose module const a caller's local shadows.
//
// @stdout: 1 2 110
// @stdout: base=10
// @stdout: 1
import { viaSecret, plusBase, logBase } from "./lib/names";

function secret(): int32 { return 2; }

function inner(): int32 {
	const base: int32 = 100;
	return plusBase(base);
}

console.log(`${viaSecret()} ${secret()} ${inner()}`);
logBase();

const k: int32 = 1;
template getK(): int32 { return k; }

function shadow(): int32 {
	const k: int32 = 2;
	return getK();
}

console.log(shadow());
