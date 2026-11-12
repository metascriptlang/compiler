// @stdout: 2 5 7
// @exit: 0

struct Layout { tabs: int32[]; active: int32 | null; }
struct Parts { layout: Layout | null; screens: int32[]; }
struct Frame { parts: Parts | null; }

function partsOf(i: int32): Parts | null {
	if (i == 0) return null;
	return { layout: i == 2 ? { tabs: [i], active: null } : null, screens: [i] };
}

function settle(): int32 {
	let layout: Layout | null = null;
	let i: int32 = 0;
	while (layout === null) {
		i += 1;
		const parts = partsOf(i);
		if (parts === null) continue;
		if (parts.layout !== null) { layout = parts.layout; }
	}
	return layout.tabs[0];
}

function deeper(frame: Frame): int32 {
	let taken: Layout | null = null;
	if (frame.parts !== null && frame.parts.layout !== null) { taken = frame.parts.layout; }
	return taken !== null ? taken.tabs[0] : -1;
}

function fromParam(parts: Parts | null): int32 {
	if (parts === null || parts.layout === null) return -1;
	const layout = parts.layout;
	return layout.tabs[0] + (layout.active ?? 0);
}

console.log(`${settle()} ${deeper({ parts: { layout: { tabs: [5], active: null }, screens: [] } })} ${fromParam({ layout: { tabs: [4], active: 3 }, screens: [] })}`);
