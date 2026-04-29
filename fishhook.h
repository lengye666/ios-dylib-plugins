// Copyright (c) Meta Platforms, Inc. and affiliates.
// BSD License - https://github.com/facebook/fishhook/blob/main/LICENSE

#ifndef fishhook_h
#define fishhook_h

#include <stddef.h>
#include <stdint.h>

struct rebinding {
  const char *name;
  void *replacement;
  void **replaced;
};

/**
 * Rebind symbols in all loaded images.
 * rebindings: array of {symbol_name, replacement_ptr, original_ptr_out}
 * rebindings_nel: number of elements in rebindings
 */
int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);

/**
 * Thread-safe rebind (acquires dyld lock).
 */
int rebind_symbols_image(void *header,
                         intptr_t slide,
                         struct rebinding rebindings[],
                         size_t rebindings_nel);

#endif
