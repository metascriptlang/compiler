class N { id: int32 = 7; }
class H { at: Unowned<N> | null = null; }
const h = new H();
function attach(): void {
	const n = new N();
	h.at = n;
}
attach();
const seen = h.at;
if (seen != null && seen.id != 7) throw new Error("an Unowned edge read a destroyed N");
