// @stdout: k 7 3
// @stdout: n - 2
// note: a const-frozen struct whose fields include a nullable value (`uint32 | null`, `string | null`, stored as a Maybe) and a Sendable function is shared with spawned tasks, generic instance and plain struct alike.
struct Holder { id: int32; owner: uint32 | null; }
struct Keyed<T> { name: string; keyOf: Sendable<(row: T) => int32>; }
const k: Keyed<Holder> = { name: "k", keyOf: (row: Holder): int32 => row.id + ((row.owner ?? 0) as int32) };
struct Named { label: string | null; tag: string | null; keyOf: Sendable<(id: uint32) => uint32>; }
const n: Named = { label: "n", tag: null, keyOf: (id: uint32): uint32 => id + 1 };
async function main(): Promise<void> {
	const a = spawn((): string => `${k.name} ${k.keyOf({ id: 2, owner: 5 })} ${k.keyOf({ id: 3, owner: null })}`);
	const b = spawn((): string => `${n.label ?? "-"} ${n.tag ?? "-"} ${n.keyOf(1)}`);
	console.log(await a);
	console.log(await b);
}
await main();
