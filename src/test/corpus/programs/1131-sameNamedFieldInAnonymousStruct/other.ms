import { wrap } from "./wrap";

struct PagesKey { items: string[]; selectedIndex: int32; }

export function otherParsed(): string {
	const r = JSON.parse<PagesKey>(`{"items":["a","b"],"selectedIndex":1}`);
	return r.ok ? `${r.value.items.length} ${r.value.selectedIndex}` : "err";
}

export function otherWrapped(): string {
	const w = wrap<PagesKey>({ items: ["x", "y", "z"], selectedIndex: 2 });
	return `${w.held.items.length} ${w.held.selectedIndex}`;
}
