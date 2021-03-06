#include <cstdio>
#include <cstring>
#include <cassert>

#include "fixnum/warp_fixnum.cu"
#include "array/fixnum_array.h"
#include "functions/modexp.cu"

using namespace std;

template< typename fixnum >
struct mul_lo {
    __device__ void operator()(fixnum &r, fixnum a) {
        fixnum s;
        fixnum::mul_lo(s, a, a);
        r = s;
    }
};

template< typename fixnum >
struct mul_wide {
    __device__ void operator()(fixnum &r, fixnum a) {
        fixnum rr, ss;
        fixnum::mul_wide(ss, rr, a, a);
        r = ss;
    }
};

template< typename fixnum >
struct my_modexp {
    __device__ void operator()(fixnum &z, fixnum x) {
        fixnum zz;
        modexp<fixnum> me(x, x);
        me(zz, x);
        z = zz;
    };
};

template< int fn_bytes, typename word_fixnum, template <typename> class Func >
void bench(int nelts) {
    typedef warp_fixnum<fn_bytes, word_fixnum> fixnum;
    typedef fixnum_array<fixnum> fixnum_array;

    uint8_t *input = new uint8_t[fn_bytes * nelts];
    for (int i = 0; i < fn_bytes * nelts; ++i)
        input[i] = (i * 17 + 11) % 256;

    fixnum_array *res, *in;
    in = fixnum_array::create(input, fn_bytes * nelts, fn_bytes);
    res = fixnum_array::create(nelts);

    // warm up
    fixnum_array::template map<Func>(res, in);

    clock_t c = clock();
    fixnum_array::template map<Func>(res, in);
    c = clock() - c;

    double secinv = (double)CLOCKS_PER_SEC / c;
    double total_MiB = fixnum::BYTES * (double)nelts / (1 << 20);
    printf(" %4d   %3d    %6.1f   %7.3f  %12.1f\n",
           fixnum::BITS, fixnum::digit::BITS, total_MiB,
           1/secinv, nelts * 1e-3 * secinv);

    delete in;
    delete res;
    delete[] input;
}

template< template <typename> class Func >
void bench_func(const char *fn_name, int nelts) {
    printf("Function: %s, #elts: %de3\n", fn_name, (int)(nelts * 1e-3));
    printf("fixnum digit  total data   time       Kops/s\n");
    printf(" bits  bits     (MiB)    (seconds)\n");
    bench<4, u32_fixnum, Func>(nelts);
    bench<8, u32_fixnum, Func>(nelts);
    bench<16, u32_fixnum, Func>(nelts);
    bench<32, u32_fixnum, Func>(nelts);
    bench<64, u32_fixnum, Func>(nelts);
    bench<128, u32_fixnum, Func>(nelts);
    puts("");

    bench<8, u64_fixnum, Func>(nelts);
    bench<16, u64_fixnum, Func>(nelts);
    bench<32, u64_fixnum, Func>(nelts);
    bench<64, u64_fixnum, Func>(nelts);
    bench<128, u64_fixnum, Func>(nelts);
    bench<256, u64_fixnum, Func>(nelts);
    puts("");
}

int main(int argc, char *argv[]) {
    long m = 1;
    if (argc > 1)
        m = atol(argv[1]);

    bench_func<mul_lo>("mul_lo", m);
    puts("");
    bench_func<mul_wide>("mul_wide", m);
    puts("");
    bench_func<my_modexp>("modexp", m / 100);

    return 0;
}
