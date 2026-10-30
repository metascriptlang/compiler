static inline msUint8Array corpusBrandMake(int64_t n) {
	msUint8Payload* p = (msUint8Payload*)msMemAlloc(sizeof(msUint8Payload) + (size_t)n);
	p->cap = n;
	for (int64_t i = 0; i < n; i++) p->data[i] = (uint8_t)(i + 1);
	return (msUint8Array){n, p};
}
