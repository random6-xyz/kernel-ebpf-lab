// Guest-side raw eBPF program loader/runner for the lab.
// Build: gcc -O2 -static -o bpfload bpfload.c
//
// Usage:
//   bpfload [--type socket|xdp|sched_cls|...] [--log] [--run [N]] [--data HEX]
//           [--data-size N] prog.bin [prog2.bin ...]
//
// Loads each raw BPF program (8-byte bpf_insn stream) via bpf(BPF_PROG_LOAD),
// prints ACCEPT/REJECT plus the verifier log when requested, then optionally
// runs each program N times with BPF_PROG_TEST_RUN and prints the return value.
// Programs listed on one command line are loaded first and then run in order,
// which makes cross-program stack-reuse demonstrations possible.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/bpf.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef BPF_PROG_TEST_RUN
#define BPF_PROG_TEST_RUN 10
#endif

static int bpf(int cmd, union bpf_attr *attr);

#define MAX_MAPS 8
static int map_fds[MAX_MAPS];
static unsigned int map_value_size[MAX_MAPS];
static int is_arena[MAX_MAPS];
static int nr_maps;

static int create_map(const char *spec)
{
	union bpf_attr attr;
	char buf[128];
	char *tok, *save = NULL;
	unsigned long vals[4];
	int n = 0;

	if (nr_maps >= MAX_MAPS) {
		fprintf(stderr, "too many maps\n");
		return -1;
	}
	snprintf(buf, sizeof(buf), "%s", spec);
	for (tok = strtok_r(buf, ":", &save); tok && n < 4; tok = strtok_r(NULL, ":", &save))
		vals[n++] = strtoul(tok, NULL, 0);
	if (n < 2) {
		fprintf(stderr, "bad --map spec: %s\n", spec);
		return -1;
	}
	memset(&attr, 0, sizeof(attr));
	if (!strncmp(spec, "ringbuf", 7)) {
		attr.map_type = BPF_MAP_TYPE_RINGBUF;
		attr.max_entries = vals[1];
		map_value_size[nr_maps] = 0;
	} else if (!strncmp(spec, "array", 5)) {
		if (n < 4) {
			fprintf(stderr, "--map array needs key:value:max: %s\n", spec);
			return -1;
		}
		attr.map_type = BPF_MAP_TYPE_ARRAY;
		attr.key_size = vals[1];
		attr.value_size = vals[2];
		attr.max_entries = vals[3];
		map_value_size[nr_maps] = vals[2];
	} else if (!strncmp(spec, "hash", 4)) {
		if (n < 4) {
			fprintf(stderr, "--map hash needs key:value:max: %s\n", spec);
			return -1;
		}
		attr.map_type = BPF_MAP_TYPE_HASH;
		attr.key_size = vals[1];
		attr.value_size = vals[2];
		attr.max_entries = vals[3];
		map_value_size[nr_maps] = vals[2];
	} else if (!strncmp(spec, "arena", 5)) {
		attr.map_type = BPF_MAP_TYPE_ARENA;
		attr.max_entries = vals[1];          /* pages */
		attr.map_flags = 1U << 10;           /* BPF_F_MMAPABLE */
		map_value_size[nr_maps] = 0;
		is_arena[nr_maps] = 1;
	} else {
		fprintf(stderr, "unsupported map kind: %s\n", spec);
		return -1;
	}
	map_fds[nr_maps] = bpf(BPF_MAP_CREATE, &attr);
	if (map_fds[nr_maps] < 0) {
		fprintf(stderr, "map create (%s): %s\n", spec, strerror(errno));
		return -1;
	}
	if (is_arena[nr_maps]) {
		size_t sz = (size_t)attr.max_entries * 4096;
		void *va = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED,
				map_fds[nr_maps], 0);
		if (va == MAP_FAILED) {
			fprintf(stderr, "arena mmap(%zu): %s\n", sz, strerror(errno));
			return -1;
		}
		map_value_size[nr_maps] = 0;
		/* fault in the first page so BPF-side accesses to offset 0 are backed */
		memset(va, 0, 8);
		printf("map%d: arena user vma %p (%zu bytes)\n", nr_maps, va, sz);
	}
	printf("map%d: %s fd=%d\n", nr_maps, spec, map_fds[nr_maps]);
	return nr_maps++;
}

/* Patch BPF_PSEUDO_MAP_FD / BPF_PSEUDO_MAP_VALUE placeholders created by the
 * assembler (imm is the map index) with real fds.
 */
static void patch_map_fds(unsigned char *img, size_t len, const char *path)
{
	size_t i;

	for (i = 0; i + 16 <= len; i += 8) {
		unsigned char code = img[i];
		unsigned char src = img[i + 1] >> 4;
		int imm = (int)(img[i + 4] | (img[i + 5] << 8) | (img[i + 6] << 16) |
				((unsigned)img[i + 7] << 24));

		if (code != (0x18) || (src != 1 && src != 2))
			continue;
		if (imm < 0 || imm >= nr_maps) {
			fprintf(stderr, "%s: map index %d out of range (%d maps)\n",
				path, imm, nr_maps);
			exit(3);
		}
		printf("%s: insn %zu: map%d fd %d -> imm\n", path, i / 8, imm,
		       map_fds[imm]);
		memcpy(&img[i + 4], &map_fds[imm], 4);
		i += 8;
	}
}

static int bpf(int cmd, union bpf_attr *attr)
{
	return syscall(__NR_bpf, cmd, attr, sizeof(*attr));
}

struct type_map {
	const char *name;
	enum bpf_prog_type type;
};

static const struct type_map TYPES[] = {
	{ "socket", BPF_PROG_TYPE_SOCKET_FILTER },
	{ "kprobe", BPF_PROG_TYPE_KPROBE },
	{ "sched_cls", BPF_PROG_TYPE_SCHED_CLS },
	{ "sched_act", BPF_PROG_TYPE_SCHED_ACT },
	{ "tracepoint", BPF_PROG_TYPE_TRACEPOINT },
	{ "xdp", BPF_PROG_TYPE_XDP },
	{ "perf_event", BPF_PROG_TYPE_PERF_EVENT },
	{ "cgroup_skb", BPF_PROG_TYPE_CGROUP_SKB },
	{ "cgroup_sock", BPF_PROG_TYPE_CGROUP_SOCK },
	{ "lwt_in", BPF_PROG_TYPE_LWT_IN },
	{ "lwt_out", BPF_PROG_TYPE_LWT_OUT },
	{ "lwt_xmit", BPF_PROG_TYPE_LWT_XMIT },
	{ "sock_ops", BPF_PROG_TYPE_SOCK_OPS },
	{ "sk_skb", BPF_PROG_TYPE_SK_SKB },
	{ "cgroup_device", BPF_PROG_TYPE_CGROUP_DEVICE },
	{ "sk_msg", BPF_PROG_TYPE_SK_MSG },
	{ "raw_tracepoint", BPF_PROG_TYPE_RAW_TRACEPOINT },
	{ "cgroup_sock_addr", BPF_PROG_TYPE_CGROUP_SOCK_ADDR },
	{ "lirc_mode2", BPF_PROG_TYPE_LIRC_MODE2 },
	{ "sk_reuseport", BPF_PROG_TYPE_SK_REUSEPORT },
	{ "flow_dissector", BPF_PROG_TYPE_FLOW_DISSECTOR },
	{ "cgroup_sysctl", BPF_PROG_TYPE_CGROUP_SYSCTL },
	{ "raw_tracepoint_writable", BPF_PROG_TYPE_RAW_TRACEPOINT_WRITABLE },
	{ "cgroup_sockopt", BPF_PROG_TYPE_CGROUP_SOCKOPT },
	{ "tracing", BPF_PROG_TYPE_TRACING },
	{ "struct_ops", BPF_PROG_TYPE_STRUCT_OPS },
	{ "ext", BPF_PROG_TYPE_EXT },
	{ "lsm", BPF_PROG_TYPE_LSM },
	{ "sk_lookup", BPF_PROG_TYPE_SK_LOOKUP },
	{ "syscall", BPF_PROG_TYPE_SYSCALL },
	{ "netfilter", BPF_PROG_TYPE_NETFILTER },
};

static enum bpf_prog_type parse_type(const char *s)
{
	size_t i;

	for (i = 0; i < sizeof(TYPES) / sizeof(TYPES[0]); i++)
		if (!strcmp(TYPES[i].name, s))
			return TYPES[i].type;
	if (s[0] >= '0' && s[0] <= '9')
		return (enum bpf_prog_type)atoi(s);
	fprintf(stderr, "unknown prog type: %s\n", s);
	exit(2);
}

static int hexval(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

static unsigned char *parse_hex(const char *s, size_t *out_len)
{
	size_t n = strlen(s), len = 0, i;
	unsigned char *buf = malloc(n / 2 + 1);

	if (!buf)
		exit(1);
	for (i = 0; i + 1 < n; i += 2) {
		int hi = hexval(s[i]), lo = hexval(s[i + 1]);

		if (hi < 0 || lo < 0) {
			/* tolerate ':' and spaces between bytes */
			i -= 1;
			continue;
		}
		buf[len++] = (hi << 4) | lo;
	}
	*out_len = len;
	return buf;
}

static unsigned char *read_file(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	unsigned char *buf;
	long sz;

	if (!f) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return NULL;
	}
	if (fseek(f, 0, SEEK_END) || (sz = ftell(f)) < 0 || fseek(f, 0, SEEK_SET)) {
		fprintf(stderr, "size %s: %s\n", path, strerror(errno));
		fclose(f);
		return NULL;
	}
	buf = malloc(sz ? sz : 1);
	if (fread(buf, 1, sz, f) != (size_t)sz) {
		fprintf(stderr, "read %s failed\n", path);
		free(buf);
		fclose(f);
		return NULL;
	}
	fclose(f);
	*len = sz;
	return buf;
}

static int load_one(const char *path, enum bpf_prog_type type, int log,
		    char **log_out)
{
	static char logbuf[1 << 20];
	size_t len = 0, insn_cnt;
	unsigned char *img = read_file(path, &len);
	union bpf_attr attr;
	int fd;

	if (!img)
		return -1;
	if (len == 0 || len % 8) {
		fprintf(stderr, "%s: bad image size %zu (must be a multiple of 8)\n",
			path, len);
		free(img);
		return -1;
	}
	insn_cnt = len / 8;
	patch_map_fds(img, len, path);
	memset(&attr, 0, sizeof(attr));
	attr.prog_type = type;
	attr.insn_cnt = insn_cnt;
	attr.insns = (uint64_t)(uintptr_t)img;
	attr.license = (uint64_t)(uintptr_t)"GPL";
	attr.log_level = log ? 2 : (getenv("BPFLOAD_LOG_ON_FAIL") ? 1 : 0);
	if (attr.log_level) {
		attr.log_buf = (uint64_t)(uintptr_t)logbuf;
		attr.log_size = sizeof(logbuf);
	}
	logbuf[0] = 0;

	fd = bpf(BPF_PROG_LOAD, &attr);
	printf("%s: %s", path, fd >= 0 ? "ACCEPT" : "REJECT");
	if (fd < 0)
		printf(" (%s)", strerror(errno));
	else
		printf("  fd=%d", fd);
	printf("  insns=%zu\n", insn_cnt);
	if (logbuf[0])
		printf("--- verifier log ---\n%s--- end log ---\n", logbuf);
	if (log_out)
		*log_out = logbuf[0] ? strdup(logbuf) : NULL;
	free(img);
	return fd;
}

static int run_one(int fd, enum bpf_prog_type type, unsigned char *data,
		   size_t data_len, unsigned int *retval)
{
	static unsigned char out[1 << 16];
	union bpf_attr attr;

	memset(&attr, 0, sizeof(attr));
	attr.test.prog_fd = fd;
	attr.test.data_in = (uint64_t)(uintptr_t)data;
	attr.test.data_out = (uint64_t)(uintptr_t)out;
	attr.test.data_size_in = data_len;
	attr.test.data_size_out = sizeof(out);
	attr.test.repeat = 1;
	if (bpf(BPF_PROG_TEST_RUN, &attr) < 0)
		return -1;
	*retval = attr.test.retval;
	return 0;
}

static void do_lookup(const char *spec)
{
	union bpf_attr attr;
	unsigned char key[64] = {0}, val[4096];
	char key_hex[64];
	unsigned long idx;
	char *colon;
	int i, ret, klen, vlen;
	static char rbuf[512];

	colon = strchr(spec, ':');
	if (!colon) {
		fprintf(stderr, "--lookup wants <map_idx>:<key_hex>\n");
		return;
	}
	idx = strtoul(spec, NULL, 0);
	if (idx >= (unsigned long)nr_maps) {
		fprintf(stderr, "--lookup: map index %lu out of range\n", idx);
		return;
	}
	strlcat(key_hex, colon + 1, sizeof(key_hex));
	klen = (int)(strlen(key_hex) / 2);
	for (i = 0; i < klen && i < (int)sizeof(key); i++)
		sscanf(key_hex + 2 * i, "%2hhx", &key[i]);
	memset(&attr, 0, sizeof(attr));
	attr.map_fd = map_fds[idx];
	attr.key = (uint64_t)(uintptr_t)key;
	attr.value = (uint64_t)(uintptr_t)val;
	attr.value_size = map_value_size[idx];
	attr.flags = 0;
	ret = bpf(BPF_MAP_LOOKUP_ELEM, &attr);
	if (ret < 0) {
		printf("lookup map%lu key=%s: %s\n", idx, key_hex, strerror(errno));
		return;
	}
	(void)vlen;
	printf("lookup map%lu key=%s: ret=%d value=", idx, key_hex, ret);
	vlen = map_value_size[idx] > 32 ? 32 : (int)map_value_size[idx];
	for (i = 0; i < vlen; i++)
		printf("%02x", val[i]);
	printf("\n");
}

/* --insert <map_idx>:<key_hex>[:<value_hex>] -- populate a map before loading
 * a program, so PoCs can rely on a hit/miss pattern from bpf_map_lookup_elem().
 */
static void do_insert(const char *spec)
{
	union bpf_attr attr;
	unsigned char key[64] = {0}, val[4096] = {0};
	char key_hex[64] = "", val_hex[4096] = "";
	unsigned long idx;
	char *colon, *colon2;
	int i, klen, vlen;

	colon = strchr(spec, ':');
	if (!colon) {
		fprintf(stderr, "--insert wants <map_idx>:<key_hex>[:<value_hex>]\n");
		return;
	}
	idx = strtoul(spec, NULL, 0);
	if (idx >= (unsigned long)nr_maps) {
		fprintf(stderr, "--insert: map index %lu out of range\n", idx);
		return;
	}
	colon2 = strchr(colon + 1, ':');
	if (colon2) {
		strlcat(key_hex, colon + 1,
			sizeof(key_hex) < (size_t)(colon2 - colon - 1) ?
			sizeof(key_hex) : (size_t)(colon2 - colon - 1));
		strlcat(val_hex, colon2 + 1, sizeof(val_hex));
	} else {
		strlcat(key_hex, colon + 1, sizeof(key_hex));
	}

	klen = (int)(strlen(key_hex) / 2);
	for (i = 0; i < klen && i < (int)sizeof(key); i++)
		sscanf(key_hex + 2 * i, "%2hhx", &key[i]);
	vlen = (int)(strlen(val_hex) / 2);
	for (i = 0; i < vlen && i < (int)sizeof(val); i++)
		sscanf(val_hex + 2 * i, "%2hhx", &val[i]);
	if (!vlen)
		vlen = (int)map_value_size[idx] <= (int)sizeof(val) ?
			map_value_size[idx] : (int)sizeof(val);

	memset(&attr, 0, sizeof(attr));
	attr.map_fd = map_fds[idx];
	attr.key = (uint64_t)(uintptr_t)key;
	attr.value = (uint64_t)(uintptr_t)val;
	attr.flags = 0;
	if (bpf(BPF_MAP_UPDATE_ELEM, &attr) < 0)
		printf("insert map%lu key=%s: FAILED %s\n", idx, key_hex,
		       strerror(errno));
	else
		printf("insert map%lu key=%s value_size=%d: ok\n", idx, key_hex,
		       vlen);
}

int main(int argc, char **argv)
{
	enum bpf_prog_type type = BPF_PROG_TYPE_SOCKET_FILTER;
	int log = 0, runs = 0, i, nprogs = 0, *fds;
	char **progs;
	unsigned char *data = NULL;
	size_t data_len = 0;
	const char *data_hex = NULL;
	const char *lookup_spec = NULL;
	const char *insert_specs[8];
	int ninserts = 0, ins;
	const char *pin_specs[8];
	int npins = 0, p;
	const char *prog_pin = NULL;

	progs = calloc(argc + 1, sizeof(*progs));
	fds = calloc(argc + 1, sizeof(*fds));

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--type") && i + 1 < argc) {
			type = parse_type(argv[++i]);
		} else if (!strcmp(argv[i], "--log")) {
			log = 1;
		} else if (!strcmp(argv[i], "--run")) {
			runs = 1;
			if (i + 1 < argc && argv[i + 1][0] >= '0' && argv[i + 1][0] <= '9')
				runs = atoi(argv[++i]);
		} else if (!strcmp(argv[i], "--map") && i + 1 < argc) {
			if (create_map(argv[++i]) < 0)
				return 2;
		} else if (!strcmp(argv[i], "--lookup") && i + 1 < argc) {
			lookup_spec = argv[++i];
		} else if (!strcmp(argv[i], "--insert") && i + 1 < argc) {
			if (ninserts < (int)(sizeof(insert_specs) / sizeof(insert_specs[0])))
				insert_specs[ninserts++] = argv[++i];
			else
				i++;
		} else if (!strcmp(argv[i], "--pin") && i + 1 < argc) {
			pin_specs[npins++] = argv[++i];
		} else if (!strcmp(argv[i], "--pin-prog") && i + 1 < argc) {
			prog_pin = argv[++i];
		} else if (!strcmp(argv[i], "--data") && i + 1 < argc) {
			data_hex = argv[++i];
		} else if (!strcmp(argv[i], "--help")) {
			printf("usage: %s [--type T] [--log] [--run [N]] [--data HEX]\n"
			       "       [--map SPEC]... [--insert IDX:KEYHEX[:VALHEX]]...\n"
			       "       [--lookup IDX:KEYHEX] [--pin IDX:/sys/fs/bpf/name]\n"
			       "       [--pin-prog /sys/fs/bpf/name] prog.bin...\n",
			       argv[0]);
			return 0;
		} else {
			progs[nprogs++] = argv[i];
		}
	}
	if (!nprogs) {
		fprintf(stderr, "no program files given\n");
		return 2;
	}
	if (data_hex) {
		data = parse_hex(data_hex, &data_len);
	} else {
		data_len = 64;
		data = calloc(1, data_len);
	}

	for (ins = 0; ins < ninserts; ins++)
		do_insert(insert_specs[ins]);

	for (i = 0; i < nprogs; i++) {
		fds[i] = load_one(progs[i], type, log, NULL);
		if (fds[i] < 0)
			return 1;
	}

	if (prog_pin && fds[0] >= 0) {
		union bpf_attr pattr;

		memset(&pattr, 0, sizeof(pattr));
		pattr.pathname = (uint64_t)(uintptr_t)prog_pin;
		pattr.bpf_fd = fds[0];
		if (bpf(BPF_OBJ_PIN, &pattr) < 0)
			printf("pin-prog %s: FAILED %s\n", prog_pin,
			       strerror(errno));
		else
			printf("pinned prog0 to %s\n", prog_pin);
	}

	if (runs) {
		unsigned int retval;
		int r;

		for (i = 0; i < nprogs; i++) {
			for (r = 0; r < runs; r++) {
				if (run_one(fds[i], type, data, data_len, &retval) < 0) {
					printf("prog%d run%d: TEST_RUN failed: %s\n",
					       i, r, strerror(errno));
					return 1;
				}
				printf("prog%d build=%d run%d: retval=%u (0x%x)\n",
				       i, i, r, retval, retval);
			}
		}
	}
	for (p = 0; p < npins; p++) {
		union bpf_attr pattr;
		unsigned long midx;
		char *colon2 = strchr(pin_specs[p], ':');

		if (!colon2) {
			fprintf(stderr, "--pin wants <map_idx>:<path>\n");
			continue;
		}
		midx = strtoul(pin_specs[p], NULL, 0);
		if (midx >= (unsigned long)nr_maps) {
			fprintf(stderr, "--pin: bad map index %lu\n", midx);
			continue;
		}
		memset(&pattr, 0, sizeof(pattr));
		pattr.pathname = (uint64_t)(uintptr_t)(colon2 + 1);
		pattr.bpf_fd = map_fds[midx];
		if (bpf(BPF_OBJ_PIN, &pattr) < 0)
			printf("pin map%lu -> %s: %s\n", midx, colon2 + 1, strerror(errno));
		else
			printf("pin map%lu -> %s: ok\n", midx, colon2 + 1);
	}
	if (lookup_spec)
		do_lookup(lookup_spec);
	printf("done: %d program(s)\n", nprogs);
	return 0;
}
