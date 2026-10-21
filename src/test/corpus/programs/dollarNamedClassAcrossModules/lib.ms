export class $base { v: int32; constructor(v: int32) { this.v = v; } }
export class $kid extends $base { constructor(v: int32) { super(v); } }
export class dollarEnv_base { v: int32; constructor(v: int32) { this.v = v; } }
export class dollarEnv_kid extends dollarEnv_base { constructor(v: int32) { super(v); } }

export function makeKid(n: int32): $base { return new $kid(n); }
export function isKid(x: $base): boolean { return x instanceof $kid; }
export function makeEnvKid(n: int32): dollarEnv_base { return new dollarEnv_kid(n); }
export function isEnvKid(x: dollarEnv_base): boolean { return x instanceof dollarEnv_kid; }
