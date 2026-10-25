// @stdout: u u u 3 7 ann 9
// note: a type parameter's constraint is the one its declaration wrote, read with the declaration's
// own parameters bound to the arguments: `K extends keyof T` sees the `T` given beside it, not the
// `T` of the routine the reference sits in, and `Keys` and `Model` are the declaring module's,
// whatever the using module imports or declares under those names.
import { At, Slot, Cell, Sub, Tagged, Store } from "./lib";

interface Root { user: string; n: int32; }
interface Model { other: string; }
interface User { id: int32; name: string; }

function outer<T>(t: T, r: Root): string {
	const x: At<Root, "user"> = r.user;
	return x;
}

const r: Root = { user: "u", n: 7 };
const a: At<Root, "user"> = r.user;
const s: Slot<Root, "user"> = { v: r.user };
const c: Cell<Root, "n"> = new Cell<Root, "n">(r.n);
const three: Sub<int32, int32> = 3;
const tagged: Tagged<int32, "a"> = 9;
const store: Store<User> = { item: { id: 1, name: "ann" } };
console.log(`${a} ${s.v} ${outer<Model>({ other: "x" }, r)} ${three} ${c.v} ${store.item.name} ${tagged}`);
