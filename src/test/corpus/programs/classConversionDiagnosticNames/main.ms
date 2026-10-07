// @exit: 1
// @stdout: Source__MMarker is not Target__ZMarker
// @xfail(danger): unchecked class conversions do not stop
// @xfail(raiser): static class members are not implemented on this backend

import { Source__MMarker, source } from "./models";

class Target__ZMarker { marker: int32 = 1; }
console.log(`before ${Source__MMarker.name} ${new Source__MMarker(9).value}`);
const wrong = source() as Target__ZMarker;
console.log(`after ${wrong.marker}`);
