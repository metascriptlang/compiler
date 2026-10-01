// @stdout: 42 7
// note: a generic alias whose parameter carries a constraint. The instance body used to keep the
// parameter (it printed `<T>` on C) because the constraint suffix was taken for part of the
// parameter name.

type Box<T extends number> = { value: T, extra: int32 };

const b: Box<int32> = { value: 42, extra: 7 };
console.log(`${b.value} ${b.extra}`);
