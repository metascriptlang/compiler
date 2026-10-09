function pair(n: int32): [int32, int32] { return [n, n + 1]; }
function point(n: int32): { x: int32, y: int32 } { return { x: n, y: n * 2 }; }
function maybe(n: int32): int32 | null { return n > 1 ? n : null; }

const base: int32[] = [10];
const [low, high] = pair(10);
const { x, y } = point(10);
const grown = [...base, low];
const kind = match (low) { 1 => "one", 10 => "ten", _ => "many" };
const either = maybe(10) ?? -1;

export function secondSummary(): string { return `${low},${high},${x},${y},${grown.length},${kind},${either}`; }
