import {
	RaiserValue, RaiserValueKind, RaiserArrayHeap, RaiserObjectHeap,
	raiserNil, handleIndex, raiserArray, raiserObject,
	heapAllocArray, heapAllocObject, heapArrayPush, heapArrayLen, heapArrayGet, heapObjectSetField, rcIncref,
	createArrayHeap, createStructHeap, heapObjectGetField, raiserInt, rcDecref, fieldNameAt, appendField, objectFieldCount, fieldValueAt,
	RaiserClassType, RaiserObjectData, RAISER_NO_CLASS, layOutObject, fieldStoreAt, heapAllocBox, raiserFloat, raiserBool
} from "./value";
import { RaiserRegClass } from "./bytecode";

export enum RaiserCopyKind {
	Preserve,
	Array,
	Object,
	Union,
}

export interface RaiserCopyPlan {
	kind: RaiserCopyKind;
	names: string[];
	children: int32[];
	discriminants: int64[];
	laid: RaiserClassType;   // the class `laidChildren` was resolved for: the plan child of each slot of its layout, -1 for none
	laidChildren: int32[];
}

function laidChildrenOf(plan: RaiserCopyPlan, cls: RaiserClassType): int32[] {
	if (plan.laid == cls) return plan.laidChildren;
	const children: int32[] = [];
	for (let f = 0; f < cls.fields.length; f += 1) {
		let child: int32 = -1;
		for (let i = 0; i < plan.names.length; i += 1) {
			if (plan.names[i] == cls.fields[f]) {
				child = plan.children[i];
				break;
			}
		}
		children.push(child);
	}
	plan.laid = cls;
	plan.laidChildren = children;
	return children;
}

// A fully laid object copies slot by slot: word, float and bool slots as their bits, the others through their plan child.
function copyLaid(arrays: RaiserArrayHeap, objects: RaiserObjectHeap, source: RaiserObjectData, plans: RaiserCopyPlan[], plan: RaiserCopyPlan): RaiserValue {
	const cls = source.classType;
	const children = laidChildrenOf(plan, cls);
	const handle = heapAllocObject(objects);
	const at = handleIndex(handle);
	layOutObject(objects.objects[at], cls);
	for (let f = 0; f < children.length; f += 1) {
		const kind = cls.kinds[f];
		if (kind == RaiserRegClass.Ref || kind == RaiserRegClass.Dyn) {
			let copied = fieldValueAt(source, f);
			if (children[f] >= 0) copied = copyTypedValue(arrays, objects, copied, plans, children[f]);
			fieldStoreAt(objects.objects[at], f, copied);
			rcIncref(arrays, objects, copied);
		} else {
			objects.objects[at].slots[f] = source.slots[f];
		}
	}
	return raiserObject(handle);
}

export function copyTypedValue(
	arrays: RaiserArrayHeap,
	objects: RaiserObjectHeap,
	value: RaiserValue,
	plans: RaiserCopyPlan[],
	index: int32,
): RaiserValue {
	if (index < 0) {
		return value;
	}
	const plan = plans[index];
	if (plan.kind == RaiserCopyKind.Array && value.kind == RaiserValueKind.Array) {
		const handle = heapAllocArray(arrays);
		const count = heapArrayLen(arrays, value.intVal);
		for (let i = 0; i < count; i = i + 1) {
			const copied = copyTypedValue(arrays, objects, heapArrayGet(arrays, value.intVal, i), plans, plan.children[0]);
			heapArrayPush(arrays, handle, copied);
			rcIncref(arrays, objects, copied);
		}
		return raiserArray(handle);
	}
	if (plan.kind == RaiserCopyKind.Object && value.kind == RaiserValueKind.Object) {
		const source = objects.objects[handleIndex(value.intVal)];
		if (source.added.length == 0 && source.classType != RAISER_NO_CLASS && source.slots.length == source.classType.fields.length) {
			return copyLaid(arrays, objects, source, plans, plan);
		}
		const handle = heapAllocObject(objects);
		objects.objects[handleIndex(handle)].classType = source.classType;
		const count = objectFieldCount(source);
		for (let f = 0; f < count; f += 1) {
			const name = fieldNameAt(source, f);
			let copied = fieldValueAt(source, f);
			for (let i = 0; i < plan.names.length; i += 1) {
				if (plan.names[i] == name) {
					copied = copyTypedValue(arrays, objects, copied, plans, plan.children[i]);
					break;
				}
			}
			appendField(objects.objects[handleIndex(handle)], name, copied);
			rcIncref(arrays, objects, copied);
		}
		return raiserObject(handle);
	}
	if (plan.kind == RaiserCopyKind.Union && value.kind == RaiserValueKind.Object) {
		const discriminant = heapObjectGetField(objects, value.intVal, plan.names[0]);
		if (discriminant.kind != RaiserValueKind.Nil) {
			for (let i = 0; i < plan.discriminants.length; i += 1) {
				if (plan.discriminants[i] == discriminant.intVal) {
					return copyTypedValue(arrays, objects, value, plans, plan.children[i]);
				}
			}
		}
		throw new Error(`internal: copy of a value union whose '${plan.names[0]}' matches no arm`);
	}
	return value;
}

test "typed copy releases owned children and retained shared references" {
	const arrays = createArrayHeap();
	const objects = createStructHeap();
	const items = raiserArray(heapAllocArray(arrays));
	heapArrayPush(arrays, items.intVal, raiserInt(1));
	const shared = raiserObject(heapAllocObject(objects));
	const source = raiserObject(heapAllocObject(objects));
	heapObjectSetField(objects, source.intVal, "items", items);
	heapObjectSetField(objects, source.intVal, "shared", shared);
	rcIncref(arrays, objects, items);
	rcIncref(arrays, objects, shared);
	rcIncref(arrays, objects, source);
	const preserve: RaiserCopyPlan = {
		kind: RaiserCopyKind.Preserve, names: [], children: [], discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [],
	};
	const sequence: RaiserCopyPlan = {
		kind: RaiserCopyKind.Array, names: [], children: [0], discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [],
	};
	const plan: RaiserCopyPlan = {
		kind: RaiserCopyKind.Object,
		names: ["items", "shared"],
		children: [1, 0],
		discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [],
	};
	const copied = copyTypedValue(arrays, objects, source, [preserve, sequence, plan], 2);
	rcIncref(arrays, objects, copied);
	assert heapObjectGetField(objects, copied.intVal, "items").intVal != items.intVal;
	assert heapObjectGetField(objects, copied.intVal, "shared").intVal == shared.intVal;
	assert objects.objects[handleIndex(shared.intVal)].rc == 2;
	rcDecref(arrays, objects, copied);
	assert objects.objects[handleIndex(shared.intVal)].rc == 1;
	rcDecref(arrays, objects, source);
	assert arrays.freeList.length == 2;
	assert objects.freeList.length == 3;
}

test "union plan copies the arm its discriminant selects" {
	const arrays = createArrayHeap();
	const objects = createStructHeap();
	const inner = raiserObject(heapAllocObject(objects));
	const source = raiserObject(heapAllocObject(objects));
	heapObjectSetField(objects, source.intVal, "kind", raiserInt(9));
	heapObjectSetField(objects, source.intVal, "side", inner);
	const preserve: RaiserCopyPlan = { kind: RaiserCopyKind.Preserve, names: [], children: [], discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [] };
	const left: RaiserCopyPlan = { kind: RaiserCopyKind.Object, names: ["kind", "side"], children: [0, 0], discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [] };
	const right: RaiserCopyPlan = { kind: RaiserCopyKind.Object, names: ["kind", "side"], children: [0, 3], discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [] };
	const struct: RaiserCopyPlan = { kind: RaiserCopyKind.Object, names: [], children: [], discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [] };
	const union: RaiserCopyPlan = { kind: RaiserCopyKind.Union, names: ["kind"], children: [1, 2], discriminants: [5, 9], laid: RAISER_NO_CLASS, laidChildren: [] };
	const copied = copyTypedValue(arrays, objects, source, [preserve, left, right, struct, union], 4);
	assert copied.intVal != source.intVal;
	assert heapObjectGetField(objects, copied.intVal, "side").intVal != inner.intVal;
}

test "laid struct copies word, float, bool, ref and dyn slots, and a nested struct is a new object" {
	const arrays = createArrayHeap();
	const objects = createStructHeap();
	const inner = raiserObject(heapAllocObject(objects));
	const innerClass: RaiserClassType = { name: "Inner", chain: [], fields: ["n"], kinds: [RaiserRegClass.Word] };
	layOutObject(objects.objects[handleIndex(inner.intVal)], innerClass);
	objects.objects[handleIndex(inner.intVal)].slots[0] = 7;
	rcIncref(arrays, objects, inner);
	const source = raiserObject(heapAllocObject(objects));
	const outerClass: RaiserClassType = { name: "Outer", chain: [], fields: ["w", "f", "b", "next", "any"], kinds: [RaiserRegClass.Word, RaiserRegClass.Float, RaiserRegClass.Bool, RaiserRegClass.Ref, RaiserRegClass.Dyn] };
	layOutObject(objects.objects[handleIndex(source.intVal)], outerClass);
	const box: RaiserValue = { kind: RaiserValueKind.Box, intVal: heapAllocBox(arrays, raiserInt(5)), floatVal: 0.0 };
	const at = handleIndex(source.intVal);
	fieldStoreAt(objects.objects[at], 0, raiserInt(41));
	fieldStoreAt(objects.objects[at], 1, raiserFloat(2.5));
	fieldStoreAt(objects.objects[at], 2, raiserBool(true));
	fieldStoreAt(objects.objects[at], 3, inner);
	fieldStoreAt(objects.objects[at], 4, box);
	rcIncref(arrays, objects, source);
	const preserve: RaiserCopyPlan = { kind: RaiserCopyKind.Preserve, names: [], children: [], discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [] };
	const innerPlan: RaiserCopyPlan = { kind: RaiserCopyKind.Object, names: ["n"], children: [0], discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [] };
	const outerPlan: RaiserCopyPlan = { kind: RaiserCopyKind.Object, names: ["any", "next", "w"], children: [0, 1, 0], discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [] };
	const plans = [preserve, innerPlan, outerPlan];
	for (let round = 0; round < 2; round += 1) {
		const copied = copyTypedValue(arrays, objects, source, plans, 2);
		rcIncref(arrays, objects, copied);
		assert copied.intVal != source.intVal;
		assert heapObjectGetField(objects, copied.intVal, "w").intVal == 41;
		assert heapObjectGetField(objects, copied.intVal, "f").floatVal == 2.5;
		assert heapObjectGetField(objects, copied.intVal, "b").intVal == 1;
		const next = heapObjectGetField(objects, copied.intVal, "next");
		assert next.intVal != inner.intVal;
		assert heapObjectGetField(objects, next.intVal, "n").intVal == 7;
		const any = heapObjectGetField(objects, copied.intVal, "any");
		assert any.kind == RaiserValueKind.Box && any.intVal == box.intVal;
		assert objects.objects[handleIndex(copied.intVal)].classType == outerClass;
		assert objects.objects[handleIndex(source.intVal)].rc == 1;
	}
	assert outerPlan.laid == outerClass;
	assert outerPlan.laidChildren.length == 5 && outerPlan.laidChildren[0] == 0 && outerPlan.laidChildren[3] == 1 && outerPlan.laidChildren[4] == 0;
}
