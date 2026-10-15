export type Way = "row" | "column";
export interface Look { way: Way | null; span: [string, int32] }

export function flip(l: Look): string {
	l.way = l.way === "row" ? "column" : "row";
	l.span = [l.span[0] + "+", l.span[1] + 1];
	return `${l.way ?? "none"} ${l.span[0]} ${l.span[1]}`;
}
