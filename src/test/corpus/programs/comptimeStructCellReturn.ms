// @stdout: 3 4 5 north
// note: a `@comptime` block returns a struct the VM holds as a laid object cell (plain words, a nested struct, a string); the compiler reads it back field by field through the cell's own layout, as it reads an untyped object.
struct Point { x: int32; y: int32; }
struct Segment { from: Point; to: Point; name: string; }
const seg = @comptime { const s: Segment = { from: { x: 3, y: 4 }, to: { x: 5, y: 0 }, name: "north" }; return s; };
console.log(seg.from.x, seg.from.y, seg.to.x, seg.name);
