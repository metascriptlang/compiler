// GUARD-CHECK-FAIL 'abstract' modifier can only appear on a class, method, or property declaration
// GUARD-JS

class ExplicitAbstractConstructor {
	abstract constructor(value: string) {} // GUARD-REFUSED
}
