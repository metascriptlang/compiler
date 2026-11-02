// ===== Operators =====
// Primitive operators (C runtime)
export extern function `==`(this a: string, b: string): boolean from "msStringEquals";
export extern function `<`(this a: string, b: string): boolean from "msStringCompareLt";
export extern function `<=`(this a: string, b: string): boolean from "msStringCompareLe";
// Derived operators (!=, >, >=) come from the system templates.
