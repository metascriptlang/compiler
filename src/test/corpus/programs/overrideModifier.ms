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
const child: Base = new Child();
const leaf: Base = new Leaf();
const result = `${child.value()} ${Child.label()} ${leaf.value()} ${new Named().override()}`;
console.log(result);
if (result != "child static leaf named") throw new Error("override modifier changed dispatch");
