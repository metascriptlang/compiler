const CEILING: number = @comptime { return Infinity; };
const MISSING: number = @comptime { return NaN; };
const FLOOR: number = @comptime { return -Infinity; };
console.log(CEILING, CEILING > 1e308, FLOOR < -1e308);
console.log(MISSING, MISSING == MISSING);
console.log(NaN, Infinity, -Infinity);
