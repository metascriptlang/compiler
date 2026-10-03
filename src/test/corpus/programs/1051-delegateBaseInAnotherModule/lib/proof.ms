import { Account, key } from "./account";
export type Signer = distinct Account;
export type Owned<T> = distinct Account;
@delegate export function key(this s: Signer): uint64;
@delegate export function key<T>(this o: Owned<T>): uint64;
export function twice(s: Signer): uint64 { return s.key() * 2; }
