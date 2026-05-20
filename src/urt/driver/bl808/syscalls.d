/// BL808 newlib syscall stubs and POSIX networking stubs
///
/// _write routes stdout/stderr to UART0.
/// Network stubs return -1 until replaced by XRAM WiFi IPC.
module urt.driver.bl808.syscalls;

import urt.driver.bl808.uart;

private:

extern(C) extern __gshared {
    pragma(mangle, "_bss_end") void* _bss_end_ptr;
    pragma(mangle, "__heap_end") void* _heap_end_ptr;
}

public:

// ================================================================
// newlib syscall stubs
// ================================================================

extern(C) int _close(int fd) @nogc nothrow { return -1; }
extern(C) int _read(int fd, void* buf, size_t n) @nogc nothrow { return 0; }

extern(C) int _write(int fd, const(void)* buf, size_t n) @nogc nothrow
{
    if (fd == 1 || fd == 2)
        uart0_hw_puts((cast(const(char)*) buf)[0 .. n]);
    return cast(int) n;
}

extern(C) int _lseek(int fd, int offset, int whence) @nogc nothrow { return 0; }
extern(C) int _fstat(int fd, void* st) @nogc nothrow { return 0; }
extern(C) int _isatty(int fd) @nogc nothrow { return 1; }

extern(C) void* _sbrk(int incr) @nogc nothrow
{
    __gshared char* heap = null;
    if (heap is null)
        heap = cast(char*)&_bss_end_ptr;
    char* new_heap = heap + incr;
    if (new_heap > cast(char*)&_heap_end_ptr)
        return cast(void*)-1; // ENOMEM
    char* prev = heap;
    heap = new_heap;
    return prev;
}

extern(C) void _exit(int code) @nogc nothrow { while (true) {} }
extern(C) int _kill(int pid, int sig) @nogc nothrow { return -1; }
extern(C) int _getpid() @nogc nothrow { return 1; }

// newlib time() calls gettimeofday(). No RTC yet -- return 0 (epoch).
// Wall-clock-dependent code (cert expiry, etc.) sees Jan 1 1970 until M0 syncs time over IPC.
struct timeval { long tv_sec; long tv_usec; }
extern(C) int gettimeofday(timeval* tv, void* tz) @nogc nothrow
{
    if (tv !is null)
    {
        tv.tv_sec = 0;
        tv.tv_usec = 0;
    }
    return 0;
}

// ================================================================
// POSIX networking stubs (replaced by XRAM WiFi IPC when ready)
// ================================================================

extern(C) int socket(int domain, int type, int protocol) @nogc nothrow { return -1; }
extern(C) int close(int fd) @nogc nothrow { return -1; }
extern(C) int poll(void* fds, uint nfds, int timeout) @nogc nothrow { return -1; }
extern(C) int _accept(int fd, void* addr, void* len) @nogc nothrow { return -1; }
extern(C) ptrdiff_t _recv(int fd, void* buf, size_t len, int flags) @nogc nothrow { return -1; }
extern(C) ptrdiff_t _recvfrom(int fd, void* buf, size_t len, int flags, void* src, void* al) @nogc nothrow { return -1; }
extern(C) ptrdiff_t _sendmsg(int fd, const(void)* msg, int flags) @nogc nothrow { return -1; }
extern(C) int _shutdown(int fd, int how) @nogc nothrow { return -1; }
extern(C) int _bind(int fd, const(void)* addr, uint len) @nogc nothrow { return -1; }
extern(C) int _listen(int fd, int backlog) @nogc nothrow { return -1; }
extern(C) int _connect(int fd, const(void)* addr, uint len) @nogc nothrow { return -1; }
extern(C) int setsockopt(int fd, int level, int name, const(void)* val, uint len) @nogc nothrow { return -1; }
extern(C) int getsockname(int fd, void* addr, uint* len) @nogc nothrow { return -1; }
extern(C) int getpeername(int fd, void* addr, uint* len) @nogc nothrow { return -1; }
extern(C) int getaddrinfo(const(char)* node, const(char)* service, const(void)* hints, void** res) @nogc nothrow { return -1; }
extern(C) void freeaddrinfo(void* res) @nogc nothrow {}
