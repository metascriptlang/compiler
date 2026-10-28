// @stdout: 5 5
// @stdout: 6 4
struct Info { id: int32; name: string; }
class Store {
	count: int32 = 0;
	constructor(schema: Readonly<Span<Info>>) {
		for (const info of schema) { this.count += info.id; }
	}
}
class Sum {
	total: int32 = 0;
	constructor(values: Span<int32>) {
		for (const v of values) { this.total += v; }
	}
}
function schema(): Vec<Info> { return [{ id: 2, name: "a" }, { id: 3, name: "b" }]; }
function nums(): Vec<int32> { return [1, 3]; }
const fromCall = new Store(schema());
const local: Vec<Info> = schema();
const fromLocal = new Store(local);
console.log(`${fromCall.count} ${fromLocal.count}`);
console.log(`${new Sum([1, 2, 3]).total} ${new Sum(nums()).total}`);
