typedef enum { CORPUS803_OK = 0, CORPUS803_OOM = -1, CORPUS803_BAD = -2 } Corpus803Result;

static inline Corpus803Result corpus803Ok(void) { return CORPUS803_OK; }
static inline Corpus803Result corpus803Fail(void) { return CORPUS803_BAD; }
static inline int corpus803Take(Corpus803Result r) { return (int)r * 10; }
