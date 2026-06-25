// Acceso a la liblzma del sistema. Apple **no** incluye `lzma.h` en el SDK, pero sí el
// stub enlazable `liblzma.tbd` (→ -llzma). Como con `Carchive`, declaramos a mano solo lo
// que usamos. La API/ABI de liblzma es estable desde hace años: `lzma_stream` está congelada
// (incluidos sus campos reservados, que DEBEN estar para que el tamaño del struct coincida;
// si faltaran, `lzma_easy_encoder` escribiría más allá de la estructura → corrupción).
#ifndef CLZMA_SHIM_H
#define CLZMA_SHIM_H

#include <stdint.h>
#include <stddef.h>

// Estado del codificador en streaming. Transcripción exacta de <lzma/base.h>.
typedef struct {
    const uint8_t *next_in;
    size_t avail_in;
    uint64_t total_in;

    uint8_t *next_out;
    size_t avail_out;
    uint64_t total_out;

    const void *allocator;   // const lzma_allocator * (no lo usamos: NULL)
    void *internal;          // lzma_internal *

    void *reserved_ptr1;
    void *reserved_ptr2;
    void *reserved_ptr3;
    void *reserved_ptr4;
    uint64_t reserved_int1;
    uint64_t reserved_int2;
    size_t reserved_int3;
    size_t reserved_int4;
    int reserved_enum1;      // lzma_reserved_enum (tamaño int)
    int reserved_enum2;
} lzma_stream;

// Inicializa un codificador `.xz` con un preset 0–9 (opcionalmente | 0x80000000 EXTREME) y
// un tipo de comprobación de integridad (4 = CRC64, el de xz por defecto). `lzma_ret`,
// `lzma_action` y `lzma_check` son enums de tamaño int en la ABI.
int lzma_easy_encoder(lzma_stream *strm, uint32_t preset, int check);
int lzma_code(lzma_stream *strm, int action);
void lzma_end(lzma_stream *strm);

#endif
