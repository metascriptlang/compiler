// GUARD-JS
// GUARD-CHECK-FAIL does not extend another class
// GUARD-CHECK-FAIL not declared in the base class

class Base {
	value(): string { return "base"; }
	static label(): string { return "base"; }
}
class Orphan {
	override value(): string { return "orphan"; } // GUARD-REFUSED
}
class Misspelled extends Base {
	override missing(): string { return "missing"; } // GUARD-REFUSED
}
class StaticOrphan {
	static override label(): string { return "orphan"; } // GUARD-REFUSED
}
class StaticMisspelled extends Base {
	static override missing(): string { return "missing"; } // GUARD-REFUSED
}
