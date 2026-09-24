// @stdout: classes A1 B4 a:x b:y7
// @exit: 0
// note: two modules export a class `Box`, one module imports both through aliases, and each module also keeps a private class `Tag`. A class's init routine is its own symbol owned by the declaring module, and a method call matches its receiver by the class's symbol: C used to name every init `Box_init`/`Tag_init` (duplicate symbols at link) and to resolve `BoxB.show()` to the first `Box` imported; as separate JS files the two classes were imported under one name; the Raiser looked a constructor up by the text of the `new` callee, which an alias changes.

import { Box as BoxA, tagA } from "./a";
import { Box as BoxB, tagB } from "./b";

console.log(`classes ${new BoxA(1).show()} ${new BoxB(2).show()} ${tagA()} ${tagB()}`);
