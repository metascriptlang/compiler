class Fields {
	async: int32 = 1;
	static: int32 = 2;
	readonly: int32 = 3;
	abstract: int32 = 4;
	public: int32 = 5;
	private: int32 = 6;
	protected: int32 = 7;
	extern: int32 = 8;
}

class Methods {
	async(): int32 { return 1; }
	static<T>(value: T): T { return value; }
	readonly(): int32 { return 3; }
	abstract(): int32 { return 4; }
	public(): int32 { return 5; }
	private(): int32 { return 6; }
	protected(): int32 { return 7; }
	extern(): int32 { return 8; }
	get(): int32 { return 9; }
	set(): int32 { return 10; }
}

class Control {
	private backing: int32 = 10;
	readonly fixed: int32 = 11;
	public read(): int32 { return this.backing; }
	get value(): int32 { return this.backing; }
	set value(next: int32): void { this.backing = next; }
	async work(): Promise<int32> { return this.backing; }
	static static(): int32 { return 12; }
}

class Optional {
	async?: int32;
	readonly?: int32;
}

const fields = new Fields();
const methods = new Methods();
const control = new Control();
const optional = new Optional();
const fieldSum = fields.async + fields.static + fields.readonly + fields.abstract +
	fields.public + fields.private + fields.protected + fields.extern;
const methodSum = methods.async() + methods.static(2) + methods.readonly() +
	methods.abstract() + methods.public() + methods.private() + methods.protected() +
	methods.extern() + methods.get() + methods.set();
control.value = 20;
const asyncValue = await control.work();
const empty = optional.async == null && optional.readonly == null;
const result = `${fieldSum} ${methodSum} ${control.read()} ${control.fixed} ` +
	`${Control.static()} ${asyncValue} ${empty}`;
if (result != "36 55 20 11 12 20 true") {
	throw new Error("contextual class member identity or modifier flags changed");
}
console.log(result);
