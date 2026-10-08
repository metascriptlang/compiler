export struct Scene { nodes: int32; }
export function create(this typeof Scene): Scene { return { nodes: 2 }; }
export function add(ref s: Scene, n: int32): int32 { s.nodes = s.nodes + n; return s.nodes; }
