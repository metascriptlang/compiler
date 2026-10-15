// @stdout: 11 22 31 32 tagA tagB 3 true
// note: two modules each declare a `Gauge`, a `Dial` and a `Tag` that carry a static `make`; the call binds to the static member of the type it names, not to the same-named type of the other module. Prelude statics (`Math`, `Number`) keep resolving.
import { Gauge as GaugeA, Dial as DialA, Tag as TagA } from "./a";
import { Gauge as GaugeB, Dial as DialB, Tag as TagB } from "./b";

console.log(GaugeA.make(), GaugeB.make(), DialA.make(), DialB.make(), TagA.make(), TagB.make(), Math.floor(3.7), Number.isInteger(5));
