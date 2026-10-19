console.log("lazy body");
export enum Size { Small, Big = 10 }
export function label(s: Size): string { return s == Size.Big ? "big" : "small"; }
