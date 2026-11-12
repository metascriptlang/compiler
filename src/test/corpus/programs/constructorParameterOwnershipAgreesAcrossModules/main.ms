// @stdout: vmznxk aospdq b/lib-b
// note: the caller and the constructor agree on which parameters the constructor takes in every module that builds an instance of a generic class: the value stored in an owning field moves in, the parent kept through an Unowned edge is lent and lives to the end of the caller's scope. The same instance built in three modules, an @inline constructor, and a subclass in another module that hands both parameters to `super`.
import { P, Cell, Quick, built } from "./lib";
import { Wide, fromOther } from "./other";

function here(): string {
	const o1 = new P("m");
	const c = new Cell<P>(new P("v"), o1);
	const o2 = new P("n");
	const q = new Quick<P>(new P("z"), o2);
	const o3 = new P("k");
	const w = new Wide(new P("x"), o3);
	return c.value.name + c.up!.name + q.value.name + q.up!.name + w.item.name + w.up!.name;
}

console.log(here(), fromOther(), built("b"));
