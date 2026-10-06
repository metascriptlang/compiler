// @xfail(raiser): the Raiser VM cannot run a subclass constructor or instanceof ('cannot evaluate 'super' at comptime: symbol kind is Class', 'cannot evaluate operator 'instanceof' at comptime')
// @stdout: instance-display deep-ok

class C0 { value: int32 = 7; }
class C1 extends C0 {}
class C2 extends C1 {}
class C3 extends C2 {}
class C4 extends C3 {}
class C5 extends C4 {}
class C6 extends C5 {}
class C7 extends C6 {}
class C8 extends C7 {}
class C9 extends C8 {}
class C10 extends C9 {}
class C11 extends C10 {}
class C12 extends C11 {}
class C13 extends C12 {}
class C14 extends C13 {}
class C15 extends C14 {}
class C16 extends C15 {}
class C17 extends C16 {}
class C18 extends C17 {}
class C19 extends C18 {}
class C20 extends C19 {}
class C21 extends C20 {}
class C22 extends C21 {}
class C23 extends C22 {}
class C24 extends C23 {}
class C25 extends C24 {}
class C26 extends C25 {}
class C27 extends C26 {}
class C28 extends C27 {}
class C29 extends C28 {}
class C30 extends C29 {}
class C31 extends C30 {}
class C32 extends C31 {}
class C33 extends C32 {}
class C34 extends C33 {}
class C35 extends C34 {}
class C36 extends C35 {}
class C37 extends C36 {}
class C38 extends C37 {}
class C39 extends C38 {}
class C40 extends C39 {}
class S33 extends C32 {}

const value: unknown = new C40();
if (!(value instanceof C0) || !(value instanceof C32) || !(value instanceof C33) || !(value instanceof C40) || value instanceof S33) process.exit(1);
if ((value as C33).value != 7) process.exit(1);
console.log("instance-display deep-ok");
