// @exit: 1
// @stdout: Box<int32> is not Target__MSource
// @xfail(danger): unchecked class conversions do not stop
// @xfail(raiser): this lane does not capture the checked-conversion diagnostic on stderr

import { Box, boxed } from "./classConversionDiagnosticNames/models";

class Target__MSource { marker: int32 = 1; }
console.log(`before ${new Box<int32>(7).value}`);
const wrong = boxed() as Target__MSource;
console.log(`after ${wrong.marker}`);
