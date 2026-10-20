// @stdout: paint 0.75:2 0.5:2 0.5:5 1:4 0.25:6 0.5:2 fn 0.125
// @stdout: card 0.75 0.5 | alias 0.5:3 | generic 0.75:2 0.5:9
// @stdout: nullable got:a got:a:7 none
// @stdout: label hi:2 hi:1
struct Paint { alpha: float32; width: float32; }
struct Holder { paint: Paint; }
interface Card { alpha: number; }
interface Product { id: string; price: number; }
struct Item { id: string; price: int32; }
struct Label { text: string; size: int32; }
type Setter<T> = T | ((previous: T) => T);

function show(value: Paint | ((previous: Paint) => Paint)): string {
	if (typeof value !== "function") { return value.alpha + ":" + value.width; }
	const next = value({ alpha: 0, width: 0 });
	return "fn " + next.alpha;
}

function showCard(value: Card | ((previous: Card) => Card)): string {
	if (typeof value !== "function") { return "" + value.alpha; }
	return "fn";
}

function showSetter(value: Setter<Paint>): string {
	if (typeof value !== "function") { return value.alpha + ":" + value.width; }
	return "fn";
}

function showLabel(value: Label | ((previous: Label) => Label)): string {
	if (typeof value !== "function") { return value.text + ":" + value.size; }
	return "fn";
}

function apply<T>(current: T, next: Setter<T>): T {
	if (typeof next === "function") { return next(current); }
	return next;
}

function makePaint(): Paint { return { alpha: 0.25, width: 4 }; }

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
const holder: Holder = { paint: initial };
console.log("paint " + show({ ...initial, alpha: 0.75 }) + " " + show({ alpha: 0.75, ...initial })
	+ " " + show({ ...holder.paint, width: 5 }) + " " + show({ ...makePaint(), alpha: 1 })
	+ " " + show({ ...initial, ...makePaint(), width: 6 }) + " " + show({ ...initial })
	+ " " + show((previous: Paint): Paint => ({ ...previous, alpha: 0.125 })));

const card: Card = { alpha: 0.5 };
const setter: Setter<Paint> = { ...initial, width: 3 };
const raised = apply<Paint>(initial, { ...initial, alpha: 0.75 });
const widened = apply<Paint>(initial, (previous: Paint): Paint => ({ ...previous, width: 9 }));
console.log("card " + showCard({ ...card, alpha: 0.75 }) + " " + showCard({ ...card })
	+ " | alias " + showSetter(setter)
	+ " | generic " + raised.alpha + ":" + raised.width + " " + widened.alpha + ":" + widened.width);

const product = findProduct("a");
const item = findItem("a");
const missing = findProduct("zz");
console.log("nullable got:" + (product === null ? "none" : product.id) + " got:"
	+ (item === null ? "none" : item.id + ":" + item.price) + " " + (missing === null ? "none" : missing.id));

const label: Label = { text: "hi", size: 1 };
console.log("label " + showLabel({ ...label, size: 2 }) + " " + showLabel({ ...label }));
