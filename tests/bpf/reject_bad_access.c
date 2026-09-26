#define SEC(name) __attribute__((section(name), used))

/*
 * Negative case: the load from an unchecked scalar address can never be
 * verified, so the verifier must reject this program and emit a reason.
 * The volatile qualifier keeps clang from folding the load away.
 */
SEC("tracepoint/syscalls/sys_enter_nanosleep")
int reject_bad_access(void *ctx)
{
    volatile unsigned long *unchecked = (volatile unsigned long *)0xdeadbeefUL;

    (void)ctx;
    return (int)*unchecked;
}

char LICENSE[] SEC("license") = "GPL";
