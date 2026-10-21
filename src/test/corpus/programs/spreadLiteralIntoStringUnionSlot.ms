// @stdout: u 0.75:2 0.5:2 s
// @stdout: nullable got:a got:a:7 none
struct Paint { alpha: float32; width: float32; }
interface Product { id: string; price: number; }
struct Item { id: string; price: int32; }
function showU(value: Paint | string): string {
	if (typeof value === "string") { return value; }
	return value.alpha + ":" + value.width;
}
const products: Product[] = [{ id: "a", price: 1 }];
function findProduct(id: string): Product | null {
	for (const p of products) {
		if (p.id !== id) { continue; }
		return { ...p };
	}
	return null;
}
const items: Item[] = [{ id: "a", price: 1 }];
function findItem(id: string): Item | null {
	for (const item of items) {
		if (item.id !== id) { continue; }
		return { ...item, price: 7 };
	}
	return null;
}
const initial: Paint = { alpha: 0.5, width: 2 };
console.log("u " + showU({ ...initial, alpha: 0.75 }) + " " + showU({ width: 3, ...initial }) + " " + showU("s"));
const product = findProduct("a");
const item = findItem("a");
const missing = findProduct("zz");
console.log("nullable got:" + (product === null ? "none" : product.id) + " got:"
	+ (item === null ? "none" : item.id + ":" + item.price) + " " + (missing === null ? "none" : missing.id));
