import {
	RaiserValue, RaiserValueKind, RaiserArrayHeap, RaiserObjectHeap,
	raiserNil, handleIndex, raiserArray, raiserObject, copyValueInto,
	heapAllocArray, heapAllocObject, heapArrayPush, heapArrayLen, heapArrayGet, heapObjectSetField, rcIncref,
	createArrayHeap, createStructHeap, heapObjectGetField, raiserInt, rcDecref,
} from "./value";

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
}

export function copyTypedValue(
	arrays: RaiserArrayHeap,
	objects: RaiserObjectHeap,
	value: RaiserValue,
	plans: RaiserCopyPlan[],
	index: int32,
): RaiserValue {
	if (index < 0) {
		const copied = raiserNil();
		copyValueInto(copied, value);
		return copied;
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
		const handle = heapAllocObject(objects);
		objects.objects[handleIndex(handle)].classType = objects.objects[handleIndex(value.intVal)].classType;
		const fields = objects.objects[handleIndex(value.intVal)].fields;
		for (const field of fields) {
			let copied = raiserNil();
			copyValueInto(copied, field.value);
			for (let i = 0; i < plan.names.length; i += 1) {
				if (plan.names[i] == field.name) {
					copied = copyTypedValue(arrays, objects, field.value, plans, plan.children[i]);
					break;
				}
			}
			heapObjectSetField(objects, handle, field.name, copied);
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
	const copied = raiserNil();
	copyValueInto(copied, value);
	return copied;
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
		kind: RaiserCopyKind.Preserve, names: [], children: [], discriminants: [],
	};
	const sequence: RaiserCopyPlan = {
		kind: RaiserCopyKind.Array, names: [], children: [0], discriminants: [],
	};
	const plan: RaiserCopyPlan = {
		kind: RaiserCopyKind.Object,
		names: ["items", "shared"],
		children: [1, 0],
		discriminants: [],
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
	const preserve: RaiserCopyPlan = { kind: RaiserCopyKind.Preserve, names: [], children: [], discriminants: [] };
	const left: RaiserCopyPlan = { kind: RaiserCopyKind.Object, names: ["kind", "side"], children: [0, 0], discriminants: [] };
	const right: RaiserCopyPlan = { kind: RaiserCopyKind.Object, names: ["kind", "side"], children: [0, 3], discriminants: [] };
	const struct: RaiserCopyPlan = { kind: RaiserCopyKind.Object, names: [], children: [], discriminants: [] };
	const union: RaiserCopyPlan = { kind: RaiserCopyKind.Union, names: ["kind"], children: [1, 2], discriminants: [5, 9] };
	const copied = copyTypedValue(arrays, objects, source, [preserve, left, right, struct, union], 4);
	assert copied.intVal != source.intVal;
	assert heapObjectGetField(objects, copied.intVal, "side").intVal != inner.intVal;
}
