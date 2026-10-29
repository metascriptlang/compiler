// @stdout: held 12 12 12 lit 13 13
struct Id { store: int32; index: int32; generation: int32; }
interface Pick { level: int32; }
struct Item { mesh: Id; material: int32; order: int32; lod: Pick | null; }

function itemOf(store: int32): Item {
	return { mesh: { store: store, index: 0, generation: 1 }, material: 3 };
}

function storeAt(items: Span<Item>, at: int32): int32 {
	let i = 0;
	for (const item of items) {
		if (i == at) return item.mesh.store;
		i += 1;
	}
	return -1;
}

function main(): void {
	const other: Id = { store: 13, index: 1, generation: 1 };
	let held: Vec<Item> = [itemOf(12), itemOf(12)];
	let lit: Vec<Item> = [{ ...held[0], mesh: other }, { ...held[1], mesh: other }];
	console.log(`held ${storeAt(held, 0)} ${storeAt(held, 1)} ${held[0].mesh.store} lit ${storeAt(lit, 0)} ${storeAt(lit, 1)}`);
}
main();
