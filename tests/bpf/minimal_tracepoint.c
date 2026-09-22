#define SEC(name) __attribute__((section(name), used))

SEC("tracepoint/syscalls/sys_enter_nanosleep")
int ebpf_lab_tracepoint(void *ctx)
{
    (void)ctx;
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
