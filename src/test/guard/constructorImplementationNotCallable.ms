// GUARD-CHECK-FAIL No matching overload for the constructor of 'StringConstructor'
// GUARD-JS

class StringConstructor {
	constructor(value: string);
	constructor(value: string | int32) {}
}
const wrong = new StringConstructor(7); // GUARD-REFUSED
