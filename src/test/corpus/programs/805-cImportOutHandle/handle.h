typedef struct Corpus805Impl* Corpus805Handle;
typedef struct { int base; } Corpus805Config;
struct Corpus805Raw;

int corpus805New(const Corpus805Config* cfg, Corpus805Handle* out);
int corpus805Value(Corpus805Handle h);
void corpus805Free(Corpus805Handle h);
int corpus805NewRaw(struct Corpus805Raw** out);
int corpus805RawValue(struct Corpus805Raw* r);
void corpus805RawFree(struct Corpus805Raw* r);
