// Smoke test and crossing-cost measurement for the C ABI of the Mihomo bridge, linked against the c-archive
// on Linux. Same structure as Cores/Bridge/cabi/ctest/abi_test.c; the configuration is Clash YAML.
// Build and run with Cores/BuildScripts/mihomo-linux-cabi-test.sh.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "libnpmihomo.h"

static int failures = 0;

#define CHECK(cond, ...)                                  \
    do {                                                  \
        if (!(cond)) {                                    \
            failures++;                                   \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);   \
            printf(__VA_ARGS__);                          \
            printf("\n");                                 \
        }                                                 \
    } while (0)

static int code_of(const char *json) {
    const char *p = strstr(json, "\"code\":");
    return p ? atoi(p + 7) : -1;
}

static double now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e9 + ts.tv_nsec;
}

static const char *CONFIG =
    "mode: rule\nlog-level: info\nrules:\n  - MATCH,REJECT\n"
    "tun:\n  enable: true\n  stack: mips\n  mtu: 1500\n";
static const char *OPTIONS = "{\"tun\":{\"mode\":\"flow\"},\"memory\":{\"limitBytes\":41943040,\"gcPercent\":50}}";

// Appends one frame holding a packet of `size` bytes whose version nibble is neither 4 nor 6: the stack
// rejects it in its first branch, so what is timed is the call, the hand-off to the stack's reader goroutine
// and the frame walk, not packet handling.
static int put_frame(uint8_t *buf, int off, int size) {
    buf[off] = (uint8_t)(size & 0xff);
    buf[off + 1] = (uint8_t)(size >> 8);
    memset(buf + off + 2, 0, (size_t)size);
    return off + 2 + size;
}

static void bench(int per_call, int size, long total_packets) {
    static uint8_t buf[256 * 1024];
    int len = 0;
    for (int i = 0; i < per_call; i++) len = put_frame(buf, len, size);
    long calls = total_packets / per_call;
    double t0 = now_ns();
    long accepted = 0;
    for (long i = 0; i < calls; i++) {
        int32_t n = npb_tun_write(buf, len);
        if (n > 0) accepted += n;
    }
    double dt = now_ns() - t0;
    printf("BENCH tun_write packet=%dB batch=%-3d : %7.1f ns/call  %6.1f ns/packet  (%ld packets)\n",
           size, per_call, dt / calls, dt / (calls * (double)per_call), accepted);
    CHECK(accepted == calls * per_call, "accepted %ld of %ld", accepted, calls * per_call);
}

int main(void) {
    char *r;

    CHECK(npb_abi_version() == 1, "abi version %d", npb_abi_version());
    r = npb_version();
    printf("version: %s\n", r);
    CHECK(code_of(r) == 0 && strstr(r, "\"core\"") && strstr(r, "\"engine\":\"mihomo\""), "version reply");
    npb_free(r);

    CHECK(npb_state() == 0, "initial state %d", npb_state());
    CHECK(npb_tun_write((uint8_t *)"\x01\x00\x00", 3) == -11, "tun write while idle");

    r = npb_validate("mode: [", 7, NULL, 0);
    CHECK(code_of(r) == 3, "validate garbage: %s", r);
    npb_free(r);
    r = npb_validate((char *)CONFIG, (int32_t)strlen(CONFIG), (char *)OPTIONS, (int32_t)strlen(OPTIONS));
    printf("validate: %s\n", r);
    CHECK(code_of(r) == 0 && strstr(r, "\"depth\":\"parse\""), "validate good");
    npb_free(r);
    r = npb_start((char *)CONFIG, (int32_t)strlen(CONFIG), "{\"nope\":1}", 10);
    CHECK(code_of(r) == 1, "start with bad options: %s", r);
    npb_free(r);

    for (int round = 0; round < 3; round++) {
        r = npb_start((char *)CONFIG, (int32_t)strlen(CONFIG), (char *)OPTIONS, (int32_t)strlen(OPTIONS));
        CHECK(code_of(r) == 0, "start: %s", r);
        npb_free(r);
        CHECK(npb_state() == 2, "state after start %d", npb_state());
        r = npb_start((char *)CONFIG, (int32_t)strlen(CONFIG), NULL, 0);
        CHECK(code_of(r) == 2, "double start: %s", r);
        npb_free(r);

        if (round == 0) {
            // one real packet: UDP 10.8.0.2:12345 -> 10.9.0.1:53, 4 bytes of payload, checksum 0 (none)
            uint8_t pkt[2 + 32] = {32, 0, 0x45, 0, 0, 32, 0, 1, 0, 0, 64, 17, 0, 0, 10, 8, 0, 2, 10, 9, 0, 1,
                                   0x30, 0x39, 0, 53, 0, 12, 0, 0, 'p', 'i', 'n', 'g'};
            CHECK(npb_tun_write(pkt, sizeof pkt) == 1, "real packet");
            uint8_t bad[5] = {0xff, 0xff, 1, 2, 3};
            CHECK(npb_tun_write(bad, sizeof bad) == -1, "oversized frame");
            uint8_t out[4096];
            CHECK(npb_tun_read(out, sizeof out, 20) >= 0, "read after a rejected UDP flow");
            CHECK(npb_tun_read(out, 0, 0) == -1, "zero capacity");

            bench(1, 40, 2000000);
            bench(8, 40, 4000000);
            bench(64, 40, 8000000);
            bench(1, 1400, 2000000);
            bench(64, 1400, 8000000);

            char logs[16384];
            int32_t n = npb_log_read(logs, sizeof logs, 200);
            CHECK(n > 0, "log read %d", n);
            if (n > 0) printf("first log line: %.*s", (int)(strchr(logs, '\n') - logs + 1), logs);
            CHECK(npb_log_read(logs, 100, 0) == -12, "small log buffer");

            r = npb_stats();
            printf("stats: %s\n", r);
            CHECK(code_of(r) == 0 && strstr(r, "\"total\"") && strstr(r, "\"rxPackets\""), "stats");
            npb_free(r);
            r = npb_observe();
            printf("observe: %s\n", r);
            CHECK(code_of(r) == 0 && strstr(r, "\"groups\":"), "observe: %s", r);
            npb_free(r);
            r = npb_select("no-such-group", 13, NULL, 0);
            CHECK(code_of(r) == 1, "select unknown group: %s", r);
            npb_free(r);
            r = npb_connections(10);
            printf("connections: %s\n", r);
            CHECK(code_of(r) == 0 && strstr(r, "\"items\":"), "connections: %s", r);
            npb_free(r);
            r = npb_memory();
            printf("memory: %s\n", r);
            CHECK(code_of(r) == 0 && strstr(r, "\"limit\":41943040"), "memory");
            npb_free(r);
        }
        r = npb_health();
        if (round == 0) printf("health: %s\n", r);
        CHECK(code_of(r) == 0 && strstr(r, "\"state\":\"running\""), "health: %s", r);
        npb_free(r);

        if (round == 1) {
            r = npb_reload((char *)CONFIG, (int32_t)strlen(CONFIG));
            CHECK(code_of(r) == 0, "reload: %s", r);
            npb_free(r);
            r = npb_reload("mode: [", 7);
            CHECK(code_of(r) == 3, "reload garbage: %s", r);
            npb_free(r);
            CHECK(npb_state() == 2, "state after refused reload %d", npb_state());
        }
        r = npb_stop(5000);
        CHECK(code_of(r) == 0, "stop: %s", r);
        npb_free(r);
        CHECK(npb_state() == 0, "state after stop %d", npb_state());
    }
    r = npb_stop(0);
    CHECK(code_of(r) == 0, "stop while idle: %s", r);
    npb_free(r);
    r = npb_observe();
    CHECK(code_of(r) == 11, "observe while idle: %s", r);
    npb_free(r);
    r = npb_stats();
    CHECK(code_of(r) == 11, "stats while idle: %s", r);
    npb_free(r);
    r = npb_connections(10);
    CHECK(code_of(r) == 11, "connections while idle: %s", r);
    npb_free(r);

    printf(failures ? "C ABI TEST FAILED (%d)\n" : "C ABI TEST PASSED\n", failures);
    return failures ? 1 : 0;
}
