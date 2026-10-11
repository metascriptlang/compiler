function pair(n: int32): [int32, int32] { return [n, n + 1]; }
function point(n: int32): { x: int32, y: int32 } { return { x: n, y: n * 2 }; }
function maybe(n: int32): int32 | null { return n > 1 ? n : null; }

const base: int32[] = [100];
const [low, high] = pair(100);
const { x, y } = point(100);
const grown = [...base, low];
const kind = match (low) { 1 => "one", 10 => "ten", _ => "many" };
const either = maybe(100) ?? -1;

export function thirdSummary(): string { return `${low},${high},${x},${y},${grown.length},${kind},${either}`; }
