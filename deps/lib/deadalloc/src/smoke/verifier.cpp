#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <malloc.h>

struct Record {
  unsigned char *ptr;
  std::size_t len;
  unsigned char fill;
  bool live;
};

static std::uint64_t state = 0xdead0110c0ffee23ULL;

static std::uint32_t next_u32() {
  state = state * 6364136223846793005ULL + 1442695040888963407ULL;
  return static_cast<std::uint32_t>(state >> 32);
}

static int check_records(Record *records, int count) {
  for (int i = 0; i < count; ++i) {
    if (!records[i].live) continue;
    if (malloc_usable_size(records[i].ptr) < records[i].len) return 10;
    for (std::size_t j = 0; j < records[i].len; ++j) {
      if (records[i].ptr[j] != records[i].fill) return 11;
    }
    const std::uintptr_t left_begin = reinterpret_cast<std::uintptr_t>(records[i].ptr);
    const std::uintptr_t left_end = left_begin + records[i].len;
    for (int k = i + 1; k < count; ++k) {
      if (!records[k].live) continue;
      const std::uintptr_t right_begin = reinterpret_cast<std::uintptr_t>(records[k].ptr);
      const std::uintptr_t right_end = right_begin + records[k].len;
      if (left_begin < right_end && right_begin < left_end) return 12;
    }
  }
  return 0;
}

int main() {
  constexpr int count = 64;
  Record records[count] = {};

  for (int step = 0; step < 2048; ++step) {
    const int slot = static_cast<int>(next_u32() % count);
    const int op = static_cast<int>(next_u32() % 100);
    if (op < 50) {
      if (records[slot].live) {
        std::free(records[slot].ptr);
        records[slot] = {};
      }
      const std::size_t len = 1 + (next_u32() % 4096);
      unsigned char *ptr = static_cast<unsigned char *>(std::malloc(len));
      if (ptr == nullptr) return 1;
      const unsigned char fill = static_cast<unsigned char>(step + slot + 1);
      std::memset(ptr, fill, len);
      records[slot] = { ptr, len, fill, true };
    } else if (op < 75) {
      if (!records[slot].live) continue;
      const std::size_t old_len = records[slot].len;
      const unsigned char fill = records[slot].fill;
      const std::size_t new_len = 1 + (next_u32() % 8192);
      unsigned char *ptr = static_cast<unsigned char *>(std::realloc(records[slot].ptr, new_len));
      if (ptr == nullptr) return 2;
      const std::size_t prefix = old_len < new_len ? old_len : new_len;
      for (std::size_t j = 0; j < prefix; ++j) {
        if (ptr[j] != fill) return 3;
      }
      std::memset(ptr, fill, new_len);
      records[slot] = { ptr, new_len, fill, true };
    } else if (op < 90) {
      if (!records[slot].live) continue;
      for (std::size_t j = 0; j < records[slot].len; ++j) {
        if (records[slot].ptr[j] != records[slot].fill) return 4;
      }
      std::free(records[slot].ptr);
      records[slot] = {};
    } else if (op < 95) {
      unsigned char *ptr = static_cast<unsigned char *>(std::calloc(17, 13));
      if (ptr == nullptr) return 5;
      for (std::size_t j = 0; j < 17 * 13; ++j) {
        if (ptr[j] != 0) return 6;
      }
      std::free(ptr);
    } else {
      void *raw = nullptr;
      if (posix_memalign(&raw, 128, 257) != 0) return 7;
      if ((reinterpret_cast<std::uintptr_t>(raw) & 127) != 0) return 8;
      std::memset(raw, 0x5a, 257);
      std::free(raw);
    }
    const int check = check_records(records, count);
    if (check != 0) return check;
  }

  for (int i = 0; i < count; ++i) {
    if (records[i].live) std::free(records[i].ptr);
  }
  return 0;
}
