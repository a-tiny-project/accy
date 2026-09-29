#include <cstdint>
#include <cstring>
#include <malloc.h>
#include <new>

extern "C" void *__libc_malloc(std::size_t);
extern "C" void *__libc_calloc(std::size_t, std::size_t);
extern "C" void __libc_free(void *);

int main() {
  char *array = new char[64];
  for (int i = 0; i < 64; ++i) array[i] = static_cast<char>(i);
  for (int i = 0; i < 64; ++i) if (array[i] != static_cast<char>(i)) return 1;
  delete[] array;

  void *scalar = ::operator new(37);
  if (scalar == nullptr) return 2;
  std::memset(scalar, 0x5a, 37);
  ::operator delete(scalar);

  char *nothrow_array = new (std::nothrow) char[33];
  if (nothrow_array == nullptr) return 3;
  nothrow_array[0] = 7;
  delete[] nothrow_array;

  void *aligned_scalar = ::operator new(57, std::align_val_t(64));
  if ((reinterpret_cast<std::uintptr_t>(aligned_scalar) & 63) != 0) return 4;
  ::operator delete(aligned_scalar, std::align_val_t(64));

  char *aligned_nothrow_array = new (std::align_val_t(128), std::nothrow) char[65];
  if (aligned_nothrow_array == nullptr) return 5;
  if ((reinterpret_cast<std::uintptr_t>(aligned_nothrow_array) & 127) != 0) return 6;
  ::operator delete[](aligned_nothrow_array, std::align_val_t(128), std::nothrow);

  void *libc_scalar = __libc_malloc(48);
  if (libc_scalar == nullptr) return 7;
  if (malloc_usable_size(libc_scalar) == 0) return 8;
  std::memset(libc_scalar, 0x33, 48);
  __libc_free(libc_scalar);

  unsigned char *libc_zeroed = static_cast<unsigned char *>(__libc_calloc(5, 8));
  if (libc_zeroed == nullptr) return 9;
  if (malloc_usable_size(libc_zeroed) == 0) return 10;
  for (int i = 0; i < 40; ++i) if (libc_zeroed[i] != 0) return 11;
  __libc_free(libc_zeroed);
  return 0;
}
