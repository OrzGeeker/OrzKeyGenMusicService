/**
 * test_v2m_size.cpp — Check V2Synth size vs m_synth buffer
 * Checks if the 3MB synth buffer is big enough
 */
#include <stdio.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// Define the V2 types
typedef int               sInt;
typedef unsigned int      sUInt;
typedef int               sBool;
typedef char              sChar;
typedef signed   char     sS8;
typedef signed   short    sS16;
typedef signed   long     sS32;
typedef unsigned char     sU8;
typedef unsigned short    sU16;
typedef unsigned long     sU32;
typedef float             sF32;
typedef double            sF64;

// Pull in the actual synth header which defines V2Synth via the .cpp
// Instead, compile a simple test that includes the full struct definitions
#include ".wasm-build/src/v2m/synth_core.cpp"

int main() {
    printf("=== V2Synth Size Check ===\n");
    printf("sizeof(V2Synth) = %zu bytes = %.2f MB\n", sizeof(V2Synth), sizeof(V2Synth) / (1024.0*1024.0));
    printf("m_synth[3*1024*1024] = %zu bytes = 3.00 MB\n", (size_t)(3*1024*1024));
    printf("\n");
    if (sizeof(V2Synth) > 3*1024*1024) {
        printf("🔴 OVERFLOW! V2Synth exceeds 3MB buffer by %zu bytes (%.2f KB)!\n",
               sizeof(V2Synth) - 3*1024*1024,
               (sizeof(V2Synth) - 3*1024*1024) / 1024.0);
    } else {
        printf("✅ V2Synth fits in 3MB buffer (%zu bytes / %.2f KB remaining)\n",
               3*1024*1024 - sizeof(V2Synth),
               (3*1024*1024 - sizeof(V2Synth)) / 1024.0);
    }

    printf("\n=== Key substructure sizes ===\n");
    printf("V2Synth::POLY = %d, CHANS = %d\n", V2Synth::POLY, V2Synth::CHANS);
    printf("sizeof(V2Voice) = %zu\n", sizeof(V2Voice));
    printf("sizeof(syVV2) = %zu\n", sizeof(syVV2));
    printf("sizeof(V2Osc) = %zu\n", sizeof(V2Osc));
    printf("sizeof(V2Flt) = %zu\n", sizeof(V2Flt));
    printf("sizeof(V2Env) = %zu\n", sizeof(V2Env));
    printf("sizeof(V2LFO) = %zu\n", sizeof(V2LFO));
    printf("sizeof(V2Dist) = %zu\n", sizeof(V2Dist));
    printf("sizeof(V2DCFilter) = %zu\n", sizeof(V2DCFilter));
    printf("sizeof(V2Chan) = %zu\n", sizeof(V2Chan));
    printf("sizeof(syVChan) = %zu\n", sizeof(syVChan));
    printf("sizeof(V2Instance) = %zu\n", sizeof(V2Instance));
    printf("sizeof(V2Reverb) = %zu\n", sizeof(V2Reverb));
    printf("sizeof(V2ModDel) = %zu\n", sizeof(V2ModDel));
    printf("sizeof(V2Comp) = %zu\n", sizeof(V2Comp));
    printf("sizeof(syWRonan) = %zu\n", sizeof(syWRonan));
    printf("sizeof(V2PatchMap) = %zu\n", sizeof(V2PatchMap));
    printf("sizeof(V2Sound) = %zu (voice=%zu, chan=%zu)\n", sizeof(V2Sound),
           sizeof(((V2Sound*)0)->voice), sizeof(((V2Sound*)0)->chan));
    printf("sizeof(V2Mod) = %zu\n", sizeof(V2Mod));

    printf("\n=== V2Synth large members ===\n");
    printf("maindelbuf[2][32768]: %zu bytes\n", sizeof(((V2Synth*)0)->maindelbuf));
    printf("chandelbuf[16][2][2048]: %zu bytes\n", sizeof(((V2Synth*)0)->chandelbuf));
    printf("ronan.mem[64*1024]: %zu bytes\n", sizeof(((V2Synth*)0)->ronan));
    printf("voicesw[64]: %zu bytes\n", sizeof(((V2Synth*)0)->voicesw));
    printf("voicesv[64] (syVV2): %zu bytes\n", sizeof(((V2Synth*)0)->voicesv));
    printf("instance: %zu bytes\n", sizeof(((V2Synth*)0)->instance));

    return 0;
}
