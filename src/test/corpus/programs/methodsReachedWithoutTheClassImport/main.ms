// @stdout: 4 42 boxed base 7
// note: a value's methods belong to its class, wherever the value came from: the caller imports neither the class nor its module — a static factory's return, a field of an interface two modules away, a generic class instance, a method inherited from a base class.

import { Factory, boxOf, derived } from "./factory";
import { createModel } from "./model";

const d = derived();
console.log(`${Factory.make(4).get()} ${createModel().session.bump(40)} ${boxOf("boxed").take()} ${d.label()} ${d.n}`);
