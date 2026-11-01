import { ClassBase } from "./classBase";
export class ClassChild extends ClassBase {
	own: string = "child";
	constructor(value: int32) { super(value); }
	scaled(factor: int32) { return this.value * factor; }
}
export class ClassOther {
	value: int32 = 0;
	constructor(value: int32) { this.value = value; }
	add(amount: int32) { return this.value + amount; }
}
export class ClassTwin {
	value: int32 = 0;
	constructor(value: int32) { this.value = value; }
	add(amount: int32) { return this.value + amount; }
}
export class ClassParameter {
	constructor(public readonly title: string) {}
}
export { ClassBase } from "./classBase";
