export class ClassBase {
	value: int32 = 0;
	readonly label: string = "base";
	protected offset: int32 = 1;
	private secret: int32 = 2;
	constructor(value: int32) { this.value = value; }
	add(amount: int32) { return this.value + amount; }
	apply(callback: (value: int32) => int32): int32 { return callback(this.value); }
	private hidden(): int32 { return this.secret; }
}
