#include <cstdio>

struct Base {
    virtual ~Base() {}
    virtual int value() const { return 1; }
};

struct Derived : Base {
    int value() const override { return 2; }
};

/* With no argument (argc is 1) a Base object is called as a Derived: UBSan's vptr check reports the member call at this
   file and line, and a build with -fno-sanitize-recover=undefined exits nonzero before the marker. */
int main(int argc, char **) {
    Base *object = argc == 1 ? new Base : new Derived;
    int result = static_cast<Derived *>(object)->value();
    std::printf("sanitizer vptr unreachable %d\n", result);
    delete object;
    return 0;
}
