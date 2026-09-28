; Store through a scalar pointer: the verifier must reject this.
r1 = 0
r2 = 0
*(u64 *)(r1 + 0) = r2
r0 = 0
exit
