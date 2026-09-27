// @stdout: set values true false true false

enum Small { A, B, C, D }
enum Wide { A, B, C, D, E, F, G, H, I }
const small: HashMap<string, BitSet<Small>> = new HashMap();
const wide: HashMap<string, BitSet<Wide>> = new HashMap();
small.set("k", Small.A | Small.C);
wide.set("k", Wide.A | Wide.I);
const s = small.get("k");
const w = wide.get("k");
console.log(`set values ${s != null ? s.has(Small.C) : false} ${s != null ? s.has(Small.B) : true} ${w != null ? w.has(Wide.I) : false} ${w != null ? w.has(Wide.H) : true}`);
