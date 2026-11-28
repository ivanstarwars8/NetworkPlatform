// System DNS configuration, the one thing of the toolbox Swift cannot reach portably (resolv.h is not part of
// the Darwin or Glibc Swift modules). Read-only: nothing is sent on the network.
#ifndef CNETWORKTOOLBOX_H
#define CNETWORKTOOLBOX_H

/// Writes the numeric addresses of the resolvers the system resolver library would ask, separated by NUL
/// bytes, into `buffer` and returns how many were written; -1 when the configuration could not be read.
/// Addresses that do not fit are left out. Apple: IPv4 and IPv6 (`res_getservers`); Linux: IPv4 only.
int np_system_resolvers(char *buffer, int capacity);

#endif
