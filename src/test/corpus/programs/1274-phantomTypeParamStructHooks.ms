// @stdout: phantom|phantom|db 3 accounts|p!abu|s|accounts:1|cyc|41
class View { w: int32 = 1; }
class DbHost { name: string = "db"; }
struct Account { id: string; }

struct H<T> { tag: string; }
function mk<T>(x: T): H<T> { return { tag: "phantom" }; }

struct TableHandle<T, K> { db: DbHost; id: int32; name: string; }
function open<T, K>(db: DbHost, name: string): TableHandle<T, K> { return { db: db, id: 3, name: name }; }

function pass(h: H<int32>): string { return h.tag + "!"; }
function ret(s: string): H<int32> { return { tag: s }; }

struct Table<T> { name: string; columns: Vec<string>; }
const accountsTable: Readonly<Table<Account>> = { name: "accounts", columns: ["id"] };

class Owner { held: Tagged<int32> | null = null; }
struct Tagged<T> { tag: string; owner: Owner | null; }

struct Host { get: (key: int32) => int32; }
struct Ctx { db: Host; }
struct Keyed<T> { name: string; base: int32; keyOf: Sendable<(row: T) => int32>; }
const accounts: Readonly<Keyed<int32>> = { name: "accounts", base: 1, keyOf: (row: int32): int32 => row };
struct Handle<T> { host: Host; base: int32; }
function openHandle<T>(host: Host, table: Readonly<Keyed<T>>): Handle<T> { return { host: host, base: table.base }; }
function lookup<T>(handle: Handle<T>, key: int32): int32 { return handle.host.get(key) + handle.base; }
struct Module { call: Sendable<(ctx: Ctx, key: int32) => int32>; }
actor Runner {
	module: Module;
	constructor(module: Module) { this.module = module; }
	run(key: int32): int32 {
		const ctx: Ctx = { db: { get: (k: int32): int32 => k * 2 } };
		return this.module.call(ctx, key);
	}
}

const out: string[] = [];
out.push(mk(1 as int32).tag);
out.push(mk(new View()).tag);
const h = open<Account, int32>(new DbHost(), "accounts");
out.push(`${h.db.name} ${h.id} ${h.name}`);
const a: H<int32>[] = [ret("a"), ret("b")];
const u: H<int32> | null = ret("u");
let parts = pass(ret("p"));
for (const x of a) parts = parts + x.tag;
if (u != null) parts = parts + u.tag;
out.push(parts);
const s: H<string> = { tag: "s" };
out.push(s.tag);
out.push(`${accountsTable.name}:${accountsTable.columns.length}`);
const owner = new Owner();
owner.held = { tag: "cyc", owner: owner };
if (owner.held != null) out.push(owner.held.tag);
const runner = new Runner({ call: (ctx: Ctx, key: int32): int32 => lookup(openHandle(ctx.db, accounts), key) });
out.push(String(await runner.run(20)));
console.log(out.join("|"));
