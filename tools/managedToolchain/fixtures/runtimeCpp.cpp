#include <cstdio>
#include <mutex>
#include <span>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <libunwind.h>

static int sum(std::span<const int> values) {
    int total = 0;
    for (int value : values) total += value;
    return total;
}

int main() {
    std::vector<int> values{10, 14, 18};
    std::mutex lock;
    int shared = 0;
    std::thread worker([&] { std::lock_guard<std::mutex> guard(lock); shared = sum(values); });
    worker.join();
    try {
        throw std::runtime_error("boom");
    } catch (const std::runtime_error &error) {
        std::printf("cpp sum=%d what=%s\n", shared, std::string(error.what()).c_str());
        return 0;
    }
    return 1;
}
