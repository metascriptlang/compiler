export class Box { n: int32; constructor(n: int32) { this.n = n; } }
export class Holder { child: Box; constructor(n: int32) { this.child = new Box(n); } }

export let shared = new Holder(1);
export let sharedList: Box[] = [new Box(1)];

export function replaceShared(): void { shared = new Holder(2); }
export function replaceFirst(): void { sharedList[0] = new Box(2); }
