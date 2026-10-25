static inline int32_t corpusApplyCallback(msClosure cb, int32_t x) { return ((int32_t (*)(int32_t))cb.fn)(x); }
