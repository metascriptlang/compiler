import {
	RaiserValue, RaiserValueKind, RaiserArrayHeap, RaiserObjectHeap,
	raiserNil, raiserArray, raiserObject, copyValueInto,
	heapAllocArray, heapAllocObject, heapArrayPush, heapObjectSetField, rcIncref,
	createArrayHeap, createStructHeap, heapObjectGetField, raiserInt, rcDecref,
} from "./value";

export enum RaiserCopyKind {
	Preserve,
	Array,
	Object,
}

export interface RaiserCopyPlan {
	kind: RaiserCopyKind;
	names: string[];
	children: int32[];
}

export function copyTypedValue(
	arrays: RaiserArrayHeap,
	objects: RaiserObjectHeap,
	value: RaiserValue,
	plans: RaiserCopyPlan[],
	index: int32,
	refcounted: boolean,
): RaiserValue {
	if (index < 0) {
		const copied = raiserNil();
		copyValueInto(copied, value);
		return copied;
	}
	const plan = plans[index];
	if (plan.kind == RaiserCopyKind.Array && value.kind == RaiserValueKind.Array) {
		const handle = heapAllocArray(arrays);
		const items = arrays.arrays[value.intVal].items;
		for (const item of items) {
			const copied = copyTypedValue(arrays, objects, item, plans, plan.children[0], refcounted);
			heapArrayPush(arrays, handle, copied);
			if (refcounted) rcIncref(arrays, objects, copied);
		}
		return raiserArray(handle);
	}
	if (plan.kind == RaiserCopyKind.Object && value.kind == RaiserValueKind.Object) {
		const handle = heapAllocObject(objects);
		const fields = objects.objects[value.intVal].fields;
		for (const field of fields) {
			let copied = raiserNil();
			copyValueInto(copied, field.value);
			for (let i = 0; i < plan.names.length; i += 1) {
				if (plan.names[i] == field.name) {
					copied = copyTypedValue(arrays, objects, field.value, plans, plan.children[i], refcounted);
					break;
				}
			}
			heapObjectSetField(objects, handle, field.name, copied);
			if (refcounted) rcIncref(arrays, objects, copied);
		}
		return raiserObject(handle);
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
		kind: RaiserCopyKind.Preserve, names: [], children: [],
	};
	const sequence: RaiserCopyPlan = {
		kind: RaiserCopyKind.Array, names: [], children: [0],
	};
	const plan: RaiserCopyPlan = {
		kind: RaiserCopyKind.Object,
		names: ["items", "shared"],
		children: [1, 0],
	};
	const copied = copyTypedValue(arrays, objects, source, [preserve, sequence, plan], 2, true);
	rcIncref(arrays, objects, copied);
	assert heapObjectGetField(objects, copied.intVal, "items").intVal != items.intVal;
	assert heapObjectGetField(objects, copied.intVal, "shared").intVal == shared.intVal;
	assert objects.objects[shared.intVal].rc == 2;
	rcDecref(arrays, objects, copied);
	assert objects.objects[shared.intVal].rc == 1;
	rcDecref(arrays, objects, source);
	assert arrays.freeList.length == 2;
	assert objects.freeList.length == 3;
}
