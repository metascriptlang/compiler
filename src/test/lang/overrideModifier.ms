class Base {
	value(): string { return "base"; }
	static label(): string { return "base-static"; }
}
class Child extends Base {
	override value(): string { return "child"; }
	static override label(): string { return "static"; }
}
class Middle extends Base {}
class Leaf extends Middle {
	override value(): string { return "leaf"; }
}
class Named {
	override(): string { return "named"; }
}

test "override modifier preserves dynamic method dispatch" {
	const child: Base = new Child();
	const leaf: Base = new Leaf();
	assert child.value() == "child";
	assert leaf.value() == "leaf";
}

test "static override modifier preserves a static method call" {
	assert Child.label() == "static";
}

test "override remains callable as an ordinary method name" {
	assert new Named().override() == "named";
}
