class KeywordFields {
	async: int32 = 1;
	static: int32 = 2;
	readonly: int32 = 3;
	abstract: int32 = 4;
	public: int32 = 5;
	private: int32 = 6;
	protected: int32 = 7;
	extern: int32 = 8;
}

class KeywordMethods {
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

class RealModifiers {
	private backing: int32 = 10;
	readonly fixed: int32 = 11;
	public read(): int32 { return this.backing; }
	get value(): int32 { return this.backing; }
	set value(next: int32): void { this.backing = next; }
	async work(): Promise<int32> { return this.backing; }
	static static(): int32 { return 12; }
}

class OptionalKeywordFields {
	async?: int32;
	readonly?: int32;
}

test "modifier words are instance fields" {
	const item = new KeywordFields();
	assert item.async + item.static + item.readonly + item.abstract +
		item.public + item.private + item.protected + item.extern == 36;
}

test "modifier names do not impose their modifier restrictions" {
	const item = new KeywordFields();
	item.readonly = 30;
	item.private = 60;
	assert item.readonly == 30 && item.private == 60;
}

test "modifier words are callable method names" {
	const item = new KeywordMethods();
	assert item.async() + item.static(2) + item.readonly() + item.abstract() +
		item.public() + item.private() + item.protected() + item.extern() +
		item.get() + item.set() == 55;
}

test "real modifiers and accessor dispatch remain active" {
	const item = new RealModifiers();
	assert item.read() == 10 && item.fixed == 11;
	item.value = 20;
	assert item.value == 20 && item.read() == 20;
	assert RealModifiers.static() == 12;
}

test "async before a method name still makes an async method" {
	const item = new RealModifiers();
	assert await item.work() == 10;
}

test "keyword property names keep optional initialization" {
	const item = new OptionalKeywordFields();
	assert item.async == null && item.readonly == null;
}
