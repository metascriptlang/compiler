#include <cstdio>
#include <exception>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

struct Tracker {
    int *counter;
    explicit Tracker(int *counter) : counter(counter) {}
    ~Tracker() { ++*counter; }
};

static int destroyed = 0;
static int staticValue = [] { return 7; }();

static int thrower(int depth) {
    Tracker tracker(&destroyed);
    if (depth == 0) throw std::runtime_error("deep");
    return thrower(depth - 1) + 1;
}

int main(int argc, char **) {
    std::vector<int> values;
    for (int i = 0; i < 9 + argc; ++i) values.push_back(i);
    int sum = 0;
    for (int value : values) sum += value;

    std::string caught;
    try {
        thrower(3);
    } catch (const std::exception &error) {
        caught = error.what();
    }

    int threaded = 0;
    std::thread worker([&threaded, &values] { threaded = static_cast<int>(values.size()); });
    worker.join();

    volatile long double base = 1.0L;
    long double wide = base + 0x1p-60L;
    long double delta = wide - base;

    std::printf("cpp sum=%d static=%d caught=%s destroyed=%d thread=%d\n", sum, staticValue, caught.c_str(),
                destroyed, threaded);
    std::printf("long double size=%d delta=%Le\n", static_cast<int>(sizeof(long double)), delta);
    return 0;
}
