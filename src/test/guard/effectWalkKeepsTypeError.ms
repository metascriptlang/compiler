// INVARIANT: a type error the checker reported is the diagnostic, not an internal error of a later walk.
// RED MEANS: the module-state walk throws on a call the checker left untyped and hides the type error.
// GUARD-JS
// GUARD-CHECK-FAIL cannot instantiate: 'T'

actor A {
	go(): string { return JSON.stringify(JSON.parse("{\"a\":1}")); } // GUARD-REFUSED
}

const t = spawn((): string => JSON.stringify(JSON.parse("{\"a\":1}"))); // GUARD-REFUSED
const a = new A();
console.log(`${await t} ${await a.go()}`);
