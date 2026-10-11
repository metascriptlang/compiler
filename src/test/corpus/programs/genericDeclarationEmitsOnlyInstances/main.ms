// @stdout: fn 4 2 1
// @stdout: class 4 2 5
// @stdout: static 7 12
// @stdout: method 8 1
// @stdout: ns 4 1
// note: a generic declaration emits only its instances. JS also emitted the uninstantiated declaration (an exported generic function, a generic class, a generic method), and a `@comptime` over `T` there emitted `const size = ;`, so the module failed to load. A generic class keeps one copy of what its instances share: static methods that do not name `T` (they took the class's parameters, so C never defined them) and static fields with their static block (C never defined the global). Exported across modules and called through a namespace import, so the ESM lane reads the export list.
import { Box, sizeCode } from "./box";
import * as boxes from "./box";

class Tool {
	size<T>(x: T): int32 {
		const s = @comptime { return sizeof(T); };
		return s;
	}
}

const a = Box.make<int32>(5);
const b = new Box<uint16>(2);
const t = new Tool();
console.log(`fn ${sizeCode<int32>()} ${sizeCode<uint16>()} ${sizeCode<boolean>()}`);
console.log(`class ${a.size()} ${b.size()} ${a.v}`);
console.log(`static ${Box.count()} ${Box.hits}`);
console.log(`method ${t.size<float64>(1.5)} ${t.size(true)}`);
console.log(`ns ${boxes.sizeCode<int32>()} ${boxes.sizeCode<boolean>()}`);
