class N { id: int32 = 7; }
class H { at: Unowned<N> | null = null; }
const h = new H();
function attach(): void {
	const n = new N();
	h.at = n;
}
attach();
