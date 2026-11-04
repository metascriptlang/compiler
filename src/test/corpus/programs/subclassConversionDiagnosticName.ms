// @exit: 1
// @stdout: Derived is not Target
// @xfail(danger): unchecked class conversions do not stop

class Base { marker: int32 = 2; }
class Derived extends Base { extra: int32 = 3; }
class Target { marker: int32 = 1; }
function source(): unknown { return new Derived(); }
console.log(`before ${new Base().marker}`);
const wrong = source() as Target;
console.log(`after ${wrong.marker}`);
