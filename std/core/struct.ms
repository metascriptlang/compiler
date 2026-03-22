// MetaScript Structure Prelude — Map<K,V> and Set<T>
// Pure MetaScript implementation — monomorphized by the compiler.
// No C runtime, no type erasure, no boxing.
// All code in one file (prelude system loads a single file per module).

// ===== Map<K, V> =====

export interface MapEntry<K, V> {
	hcode: int64;
	key: K;
	value: V;
}

export interface Map<K, V> {
	data: MapEntry<K, V>[];
	counter: int32;
}

// ===== Hash Functions =====

export function hashString(s: string): int64 {
	if (s.byteLength === 0) return 314159265;
	let h: int64 = 5381;
	let i: int64 = 0;
	while (i < s.byteLength) {
		h = h * 33 + s.byteAt(i) as int64;
		i = i + 1;
	}
	if (h === 0) return 314159265;
	return h;
}

function mapRawGet<K, V>(m: Map<K, V>, key: K): int32 {
	if (m.data.length === 0) return -1;
	const hc = hashString(key as unknown as string);
	const mask: int32 = m.data.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	while (m.data[h].hcode !== 0) {
		if (m.data[h].hcode === hc && m.data[h].key as unknown as string === key as unknown as string) {
			return h;
		}
		h = (h + 1) & mask;
	}
	return -1 - h;
}

function mapEnlarge<K, V>(m: Map<K, V>): void {
	const oldData = m.data;
	const newCap = oldData.length * 2;
	const newData: MapEntry<K, V>[] = new Array(newCap);
	m.data = newData;
	let i: int32 = 0;
	while (i < oldData.length) {
		if (oldData[i].hcode !== 0) {
			const mask: int32 = newCap - 1;
			let j: int32 = (oldData[i].hcode & (mask as int64)) as int32;
			while (m.data[j].hcode !== 0) { j = (j + 1) & mask; }
			m.data[j].hcode = oldData[i].hcode;
			m.data[j].key = oldData[i].key;
			m.data[j].value = oldData[i].value;
		}
		i = i + 1;
	}
}

export function set<K, V>(this m: Map<K, V>, key: K, value: V): void {
	if (m.data.length === 0) {
		const init: MapEntry<K, V>[] = new Array(32);
		m.data = init;
	}
	const hc = hashString(key as unknown as string);
	const idx = mapRawGet(m, key);
	if (idx >= 0) {
		m.data[idx].value = value;
	} else {
		// Check rehash: size < 1.5 * count OR empty_slots < 4
		if (m.data.length < (m.counter + m.counter / 2) || (m.data.length - m.counter) < 4) {
			mapEnlarge(m);
		}
		// Re-probe after potential enlarge
		const mask: int32 = m.data.length - 1;
		let h: int32 = (hc & (mask as int64)) as int32;
		while (m.data[h].hcode !== 0) { h = (h + 1) & mask; }
		m.data[h].hcode = hc;
		m.data[h].key = key;
		m.data[h].value = value;
		m.counter = m.counter + 1;
	}
}

export function get<K, V>(this m: Map<K, V>, key: K): V {
	const idx = mapRawGet(m, key);
	if (idx >= 0) return m.data[idx].value;
	return null as unknown as V;
}

export function has<K, V>(this m: Map<K, V>, key: K): boolean {
	return mapRawGet(m, key) >= 0;
}

export function delete<K, V>(this m: Map<K, V>, key: K): boolean {
	let i = mapRawGet(m, key);
	if (i < 0) return false;
	const mask: int32 = m.data.length - 1;
	m.counter = m.counter - 1;
	// Back-shift deletion (Knuth V3 Algo 6.4R)
	while (true) {
		m.data[i].hcode = 0;
		const j = i;
		while (true) {
			i = (i + 1) & mask;
			if (m.data[i].hcode === 0) return true;
			const r: int32 = (m.data[i].hcode & (mask as int64)) as int32;
			if ((i >= r && r > j) || (r > j && j > i) || (j > i && i >= r)) {
				continue;
			}
			break;
		}
		m.data[j].hcode = m.data[i].hcode;
		m.data[j].key = m.data[i].key;
		m.data[j].value = m.data[i].value;
	}
	return true;
}

export function size<K, V>(this m: Map<K, V>): int32 {
	return m.counter;
}

export function clear<K, V>(this m: Map<K, V>): void {
	let i: int32 = 0;
	while (i < m.data.length) { m.data[i].hcode = 0; i = i + 1; }
	m.counter = 0;
}

export function keys<K, V>(this m: Map<K, V>): K[] {
	const result: K[] = [];
	let i: int32 = 0;
	while (i < m.data.length) {
		if (m.data[i].hcode !== 0) result.push(m.data[i].key);
		i = i + 1;
	}
	return result;
}

export function values<K, V>(this m: Map<K, V>): V[] {
	const result: V[] = [];
	let i: int32 = 0;
	while (i < m.data.length) {
		if (m.data[i].hcode !== 0) result.push(m.data[i].value);
		i = i + 1;
	}
	return result;
}

// ===== Set<T> =====

export interface SetEntry<T> {
	hcode: int64;
	key: T;
}

export interface Set<T> {
	data: SetEntry<T>[];
	counter: int32;
}

function setRawGet<T>(s: Set<T>, key: T): int32 {
	if (s.data.length === 0) return -1;
	const hc = hashString(key as unknown as string);
	const mask: int32 = s.data.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	while (s.data[h].hcode !== 0) {
		if (s.data[h].hcode === hc && s.data[h].key as unknown as string === key as unknown as string) {
			return h;
		}
		h = (h + 1) & mask;
	}
	return -1 - h;
}

function setEnlarge<T>(s: Set<T>): void {
	const oldData = s.data;
	const newCap = oldData.length * 2;
	const newData: SetEntry<T>[] = new Array(newCap);
	s.data = newData;
	let i: int32 = 0;
	while (i < oldData.length) {
		if (oldData[i].hcode !== 0) {
			const mask: int32 = newCap - 1;
			let j: int32 = (oldData[i].hcode & (mask as int64)) as int32;
			while (newData[j].hcode !== 0) { j = (j + 1) & mask; }
			newData[j].hcode = oldData[i].hcode;
			newData[j].key = oldData[i].key;
		}
		i = i + 1;
	}
}

export function add<T>(this s: Set<T>, value: T): void {
	if (s.data.length === 0) { s.data = new Array(32); }
	const idx = setRawGet(s, value);
	if (idx >= 0) return;
	const hc = hashString(value as unknown as string);
	if (s.data.length < (s.counter + s.counter / 2) || (s.data.length - s.counter) < 4) {
		setEnlarge(s);
	}
	const mask: int32 = s.data.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	while (s.data[h].hcode !== 0) { h = (h + 1) & mask; }
	s.data[h].hcode = hc;
	s.data[h].key = value;
	s.counter = s.counter + 1;
}

export function has<T>(this s: Set<T>, value: T): boolean {
	return setRawGet(s, value) >= 0;
}

export function delete<T>(this s: Set<T>, value: T): boolean {
	let i = setRawGet(s, value);
	if (i < 0) return false;
	const mask: int32 = s.data.length - 1;
	s.counter = s.counter - 1;
	while (true) {
		s.data[i].hcode = 0;
		const j = i;
		while (true) {
			i = (i + 1) & mask;
			if (s.data[i].hcode === 0) return true;
			const r: int32 = (s.data[i].hcode & (mask as int64)) as int32;
			if ((i >= r && r > j) || (r > j && j > i) || (j > i && i >= r)) continue;
			break;
		}
		s.data[j].hcode = s.data[i].hcode;
		s.data[j].key = s.data[i].key;
	}
	return true;
}

export function size<T>(this s: Set<T>): int32 {
	return s.counter;
}

export function clear<T>(this s: Set<T>): void {
	let i: int32 = 0;
	while (i < s.data.length) { s.data[i].hcode = 0; i = i + 1; }
	s.counter = 0;
}
