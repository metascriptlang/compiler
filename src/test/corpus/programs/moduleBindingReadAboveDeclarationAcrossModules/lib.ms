export function show(): string {
	return `${LATER.n + 1}`;
}

export function label(): string {
	return NAME + "c";
}

export function count(): string {
	return `${ITEMS.length}`;
}

export function readied(): string {
	return ready ? "ready=yes" : "ready=no";
}

struct Box { n: int32; }

function make(): Box {
	return { n: 41 };
}

export const LATER = make();
const NAME = "ab";
let ITEMS = [1, 2, 3];
let ready = false;
ready = true;
