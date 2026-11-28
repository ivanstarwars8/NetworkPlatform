#include "CNetworkToolbox.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <resolv.h>
#include <string.h>
#include <sys/socket.h>

static int append(char *buffer, int capacity, int *used, const char *text) {
    int length = (int)strlen(text);
    if (length == 0 || *used + length + 1 > capacity) {
        return 0;
    }
    memcpy(buffer + *used, text, (size_t)length);
    buffer[*used + length] = '\0';
    *used += length + 1;
    return 1;
}

int np_system_resolvers(char *buffer, int capacity) {
    if (buffer == NULL || capacity <= 0) {
        return -1;
    }
    struct __res_state state;
    memset(&state, 0, sizeof(state));
    if (res_ninit(&state) != 0) {
        return -1;
    }
    int used = 0;
    int count = 0;
    char text[INET6_ADDRSTRLEN];
#if defined(__APPLE__)
    union res_sockaddr_union servers[MAXNS];
    int found = res_getservers(&state, servers, MAXNS);
    for (int i = 0; i < found; i++) {
        const char *ok = NULL;
        if (servers[i].sin.sin_family == AF_INET) {
            ok = inet_ntop(AF_INET, &servers[i].sin.sin_addr, text, sizeof(text));
        } else if (servers[i].sin6.sin6_family == AF_INET6) {
            ok = inet_ntop(AF_INET6, &servers[i].sin6.sin6_addr, text, sizeof(text));
        }
        if (ok != NULL && append(buffer, capacity, &used, text)) {
            count++;
        }
    }
    res_ndestroy(&state);
#else
    for (int i = 0; i < state.nscount && i < MAXNS; i++) {
        if (state.nsaddr_list[i].sin_family != AF_INET) {
            continue;
        }
        if (inet_ntop(AF_INET, &state.nsaddr_list[i].sin_addr, text, sizeof(text)) != NULL
            && append(buffer, capacity, &used, text)) {
            count++;
        }
    }
    res_nclose(&state);
#endif
    return count;
}
