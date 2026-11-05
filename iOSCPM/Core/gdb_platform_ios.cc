/*
 * The parts of cpmemu's platform layer that gdbstub.cc uses, for iOS, Mac
 * Catalyst and macOS apps.  See gdb_platform_ios.h.
 *
 * The socket functions are the same code as romwbw_emu's gdb_platform.cc, with
 * the same return values (cpmemu's os/platform.h says which), except that every
 * wait is a poll in slices of 100 ms that looks at the cancel flag.  There is
 * no console: the app's input arrives through the view, not stdin, so
 * is_terminal() is false and console_getchar() has nothing to read.
 */

#include "os/platform.h"
#include "gdb_platform_ios.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

namespace {

thread_local const volatile bool* t_cancel = nullptr;
thread_local char t_listen_error[128] = "";

const int kSliceMs = 100;

bool cancelled() { return t_cancel && *t_cancel; }

}  // namespace

void gdb_platform_set_cancel(const volatile bool* flag) { t_cancel = flag; }

const char* gdb_platform_last_error() { return t_listen_error; }

namespace platform {

bool is_terminal() { return false; }

int console_getchar() { return -1; }

int termination_requested() { return cancelled() ? 1 : 0; }

socket_t net_listen(uint32_t addr, int port, int* bound_port) {
  t_listen_error[0] = 0;
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) {
    fprintf(stderr, "gdb stub: socket: %s\n", strerror(errno));
    snprintf(t_listen_error, sizeof t_listen_error, "%s", strerror(errno));
    return kNoSocket;
  }
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(addr);
  a.sin_port = htons((unsigned short)port);
  if (bind(s, (struct sockaddr*)&a, sizeof a) != 0 || listen(s, 1) != 0) {
    fprintf(stderr, "gdb stub: cannot listen on %u.%u.%u.%u:%d: %s\n",
            (unsigned)(addr >> 24), (unsigned)(addr >> 16) & 255u,
            (unsigned)(addr >> 8) & 255u, (unsigned)addr & 255u, port, strerror(errno));
    snprintf(t_listen_error, sizeof t_listen_error, "%s", strerror(errno));
    close(s);
    return kNoSocket;
  }
  socklen_t len = sizeof a;
  if (getsockname(s, (struct sockaddr*)&a, &len) != 0) {
    fprintf(stderr, "gdb stub: getsockname: %s\n", strerror(errno));
    close(s);
    return kNoSocket;
  }
  if (bound_port) *bound_port = ntohs(a.sin_port);
  return (socket_t)s;
}

socket_t net_listen_local(int port, int* bound_port) {
  return net_listen(INADDR_LOOPBACK, port, bound_port);
}

socket_t net_accept(socket_t listener) {
  for (;;) {
    if (cancelled()) return kNoSocket;
    struct pollfd p;
    p.fd = (int)listener;
    p.events = POLLIN;
    p.revents = 0;
    int n = poll(&p, 1, kSliceMs);
    if (n < 0) {
      if (errno == EINTR) continue;
      fprintf(stderr, "gdb stub: poll: %s\n", strerror(errno));
      return kNoSocket;
    }
    if (n == 0) continue;
    int c = accept((int)listener, NULL, NULL);
    if (c >= 0) {
      int one = 1;
      setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef SO_NOSIGPIPE
      setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
      return (socket_t)c;
    }
    if (errno == EINTR || errno == ECONNABORTED || errno == EAGAIN) continue;
    fprintf(stderr, "gdb stub: accept: %s\n", strerror(errno));
    return kNoSocket;
  }
}

// timeout_ms < 0 waits for ever, in slices that look at the cancel flag.  A
// cancelled wait answers 0, "the peer closed", which is what makes the stub
// give the program back.
int net_recv(socket_t s, void* buf, int len, int timeout_ms) {
  if (cancelled()) return 0;
  int waited = 0;
  while (timeout_ms != 0) {
    int slice = timeout_ms < 0 ? kSliceMs : (timeout_ms - waited < kSliceMs ? timeout_ms - waited : kSliceMs);
    struct pollfd p;
    p.fd = (int)s;
    p.events = POLLIN;
    p.revents = 0;
    int n = poll(&p, 1, slice);
    if (n < 0) return errno == EINTR ? -3 : -1;
    if (n > 0) break;
    if (cancelled()) return 0;
    if (timeout_ms > 0) {
      waited += slice;
      if (waited >= timeout_ms) return -2;
    }
  }
  if (timeout_ms == 0) {
    // A poll with no wait: is there a byte now?
    struct pollfd p;
    p.fd = (int)s;
    p.events = POLLIN;
    p.revents = 0;
    int n = poll(&p, 1, 0);
    if (n < 0) return errno == EINTR ? -3 : -1;
    if (n == 0) return -2;
  }
  ssize_t n = recv((int)s, buf, (size_t)len, 0);
  if (n > 0) return (int)n;
  if (n == 0) return 0;
  return errno == EINTR ? -3 : -1;
}

bool net_send_all(socket_t s, const void* buf, int len) {
  const char* p = (const char*)buf;
#ifdef MSG_NOSIGNAL
  const int flags = MSG_NOSIGNAL;
#else
  const int flags = 0;
#endif
  while (len > 0) {
    ssize_t n = send((int)s, p, (size_t)len, flags);
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    p += n;
    len -= (int)n;
  }
  return true;
}

void net_close(socket_t s) {
  if (s != kNoSocket) close((int)s);
}

// Only gdbstub.cc's own console wait uses this, and this port installs no
// console wait.  It waits for the socket and reports the socket alone.
int wait_console_or_socket(socket_t s, int timeout_ms) {
  if (s == kNoSocket) return 0;
  int waited = 0;
  for (;;) {
    if (cancelled()) return -1;
    int slice = timeout_ms < 0 ? kSliceMs : (timeout_ms - waited < kSliceMs ? timeout_ms - waited : kSliceMs);
    struct pollfd p;
    p.fd = (int)s;
    p.events = POLLIN;
    p.revents = 0;
    int n = poll(&p, 1, slice);
    if (n < 0) return -1;
    if (n > 0) return 2;
    if (timeout_ms >= 0) {
      waited += slice;
      if (waited >= timeout_ms) return 0;
    }
  }
}

}  // namespace platform
