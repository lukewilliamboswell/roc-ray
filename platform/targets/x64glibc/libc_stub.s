.text

# Original stubs from Roc test platform
.balign 8
.globl __sysctl
.type __sysctl, %function
__sysctl:    xor %rax, %rax
    ret

.balign 8
.globl __libc_start_main
.type __libc_start_main, %function
__libc_start_main:
    xor %rax, %rax
    ret

.balign 8
.globl abort
.type abort, %function
abort:
    mov $1, %rdi
    mov $60, %rax
    syscall

.balign 8
.globl getauxval
.type getauxval, %function
getauxval:
    xor %rax, %rax
    ret

.balign 8
.globl __tls_get_addr
.type __tls_get_addr, %function
__tls_get_addr:
    xor %rax, %rax
    ret

.balign 8
.globl __errno_location
.type __errno_location, %function
__errno_location:
    xor %rax, %rax
    ret

.balign 8
.globl memcpy
.type memcpy, %function
memcpy:
    xor %rax, %rax
    ret

.balign 8
.globl memmove
.type memmove, %function
memmove:
    xor %rax, %rax
    ret

.balign 8
.globl mmap
.type mmap, %function
mmap:
    xor %rax, %rax
    ret

.balign 8
.globl mmap64
.type mmap64, %function
mmap64:
    xor %rax, %rax
    ret

.balign 8
.globl munmap
.type munmap, %function
munmap:
    xor %rax, %rax
    ret

.balign 8
.globl mremap
.type mremap, %function
mremap:
    xor %rax, %rax
    ret

.balign 8
.globl msync
.type msync, %function
msync:
    xor %rax, %rax
    ret

.balign 8
.globl malloc
.type malloc, %function
malloc:
    xor %rax, %rax
    ret

.balign 8
.globl calloc
.type calloc, %function
calloc:
    xor %rax, %rax
    ret

.balign 8
.globl realloc
.type realloc, %function
realloc:
    xor %rax, %rax
    ret

.balign 8
.globl free
.type free, %function
free:
    xor %rax, %rax
    ret

.balign 8
.globl posix_memalign
.type posix_memalign, %function
posix_memalign:
    xor %rax, %rax
    ret

.balign 8
.globl malloc_usable_size
.type malloc_usable_size, %function
malloc_usable_size:
    xor %rax, %rax
    ret

.balign 8
.globl close
.type close, %function
close:
    xor %rax, %rax
    ret

.balign 8
.globl read
.type read, %function
read:
    xor %rax, %rax
    ret

.balign 8
.globl write
.type write, %function
write:
    xor %rax, %rax
    ret

.balign 8
.globl readv
.type readv, %function
readv:
    xor %rax, %rax
    ret

.balign 8
.globl writev
.type writev, %function
writev:
    xor %rax, %rax
    ret

.balign 8
.globl openat64
.type openat64, %function
openat64:
    xor %rax, %rax
    ret

.balign 8
.globl lseek64
.type lseek64, %function
lseek64:
    xor %rax, %rax
    ret

.balign 8
.globl pread64
.type pread64, %function
pread64:
    xor %rax, %rax
    ret

.balign 8
.globl pwritev64
.type pwritev64, %function
pwritev64:
    xor %rax, %rax
    ret

.balign 8
.globl flock
.type flock, %function
flock:
    xor %rax, %rax
    ret

.balign 8
.globl copy_file_range
.type copy_file_range, %function
copy_file_range:
    xor %rax, %rax
    ret

.balign 8
.globl sendfile64
.type sendfile64, %function
sendfile64:
    xor %rax, %rax
    ret

.balign 8
.globl realpath
.type realpath, %function
realpath:
    xor %rax, %rax
    ret

.balign 8
.globl readlink
.type readlink, %function
readlink:
    xor %rax, %rax
    ret

.balign 8
.globl getenv
.type getenv, %function
getenv:
    xor %rax, %rax
    ret

.balign 8
.globl isatty
.type isatty, %function
isatty:
    xor %rax, %rax
    ret

.balign 8
.globl sysconf
.type sysconf, %function
sysconf:
    xor %rax, %rax
    ret

.balign 8
.globl sigaction
.type sigaction, %function
sigaction:
    xor %rax, %rax
    ret

.balign 8
.globl sigemptyset
.type sigemptyset, %function
sigemptyset:
    xor %rax, %rax
    ret

.balign 8
.globl dl_iterate_phdr
.type dl_iterate_phdr, %function
dl_iterate_phdr:
    xor %rax, %rax
    ret

.balign 8
.globl getcontext
.type getcontext, %function
getcontext:
    xor %rax, %rax
    ret

.balign 8
.globl fmod
.type fmod, %function
fmod:
    xor %rax, %rax
    ret

.balign 8
.globl fmodf
.type fmodf, %function
fmodf:
    xor %rax, %rax
    ret

.balign 8
.globl trunc
.type trunc, %function
trunc:
    xor %rax, %rax
    ret

.balign 8
.globl truncf
.type truncf, %function
truncf:
    xor %rax, %rax
    ret

# Additional stubs needed by raylib

# Math functions
.balign 8
.globl acosf
.type acosf, %function
acosf:
    xor %rax, %rax
    ret

.balign 8
.globl acos
.type acos, %function
acos:
    xor %rax, %rax
    ret

.balign 8
.globl asinf
.type asinf, %function
asinf:
    xor %rax, %rax
    ret

.balign 8
.globl asin
.type asin, %function
asin:
    xor %rax, %rax
    ret

.balign 8
.globl atanf
.type atanf, %function
atanf:
    xor %rax, %rax
    ret

.balign 8
.globl atan
.type atan, %function
atan:
    xor %rax, %rax
    ret

.balign 8
.globl atan2f
.type atan2f, %function
atan2f:
    xor %rax, %rax
    ret

.balign 8
.globl atan2
.type atan2, %function
atan2:
    xor %rax, %rax
    ret

.balign 8
.globl cosf
.type cosf, %function
cosf:
    xor %rax, %rax
    ret

.balign 8
.globl cos
.type cos, %function
cos:
    xor %rax, %rax
    ret

.balign 8
.globl sinf
.type sinf, %function
sinf:
    xor %rax, %rax
    ret

.balign 8
.globl sin
.type sin, %function
sin:
    xor %rax, %rax
    ret

.balign 8
.globl tanf
.type tanf, %function
tanf:
    xor %rax, %rax
    ret

.balign 8
.globl tan
.type tan, %function
tan:
    xor %rax, %rax
    ret

.balign 8
.globl sqrtf
.type sqrtf, %function
sqrtf:
    xor %rax, %rax
    ret

.balign 8
.globl sqrt
.type sqrt, %function
sqrt:
    xor %rax, %rax
    ret

.balign 8
.globl powf
.type powf, %function
powf:
    xor %rax, %rax
    ret

.balign 8
.globl pow
.type pow, %function
pow:
    xor %rax, %rax
    ret

.balign 8
.globl expf
.type expf, %function
expf:
    xor %rax, %rax
    ret

.balign 8
.globl exp
.type exp, %function
exp:
    xor %rax, %rax
    ret

.balign 8
.globl logf
.type logf, %function
logf:
    xor %rax, %rax
    ret

.balign 8
.globl log
.type log, %function
log:
    xor %rax, %rax
    ret

.balign 8
.globl log10f
.type log10f, %function
log10f:
    xor %rax, %rax
    ret

.balign 8
.globl log10
.type log10, %function
log10:
    xor %rax, %rax
    ret

.balign 8
.globl floorf
.type floorf, %function
floorf:
    xor %rax, %rax
    ret

.balign 8
.globl floor
.type floor, %function
floor:
    xor %rax, %rax
    ret

.balign 8
.globl ceilf
.type ceilf, %function
ceilf:
    xor %rax, %rax
    ret

.balign 8
.globl ceil
.type ceil, %function
ceil:
    xor %rax, %rax
    ret

.balign 8
.globl fabsf
.type fabsf, %function
fabsf:
    xor %rax, %rax
    ret

.balign 8
.globl fabs
.type fabs, %function
fabs:
    xor %rax, %rax
    ret

.balign 8
.globl roundf
.type roundf, %function
roundf:
    xor %rax, %rax
    ret

.balign 8
.globl round
.type round, %function
round:
    xor %rax, %rax
    ret

.balign 8
.globl ldexp
.type ldexp, %function
ldexp:
    xor %rax, %rax
    ret

.balign 8
.globl ldexpf
.type ldexpf, %function
ldexpf:
    xor %rax, %rax
    ret

.balign 8
.globl frexp
.type frexp, %function
frexp:
    xor %rax, %rax
    ret

.balign 8
.globl frexpf
.type frexpf, %function
frexpf:
    xor %rax, %rax
    ret

# String functions
.balign 8
.globl strlen
.type strlen, %function
strlen:
    xor %rax, %rax
    ret

.balign 8
.globl strcpy
.type strcpy, %function
strcpy:
    xor %rax, %rax
    ret

.balign 8
.globl strncpy
.type strncpy, %function
strncpy:
    xor %rax, %rax
    ret

.balign 8
.globl strcat
.type strcat, %function
strcat:
    xor %rax, %rax
    ret

.balign 8
.globl strncat
.type strncat, %function
strncat:
    xor %rax, %rax
    ret

.balign 8
.globl strcmp
.type strcmp, %function
strcmp:
    xor %rax, %rax
    ret

.balign 8
.globl strncmp
.type strncmp, %function
strncmp:
    xor %rax, %rax
    ret

.balign 8
.globl strchr
.type strchr, %function
strchr:
    xor %rax, %rax
    ret

.balign 8
.globl strrchr
.type strrchr, %function
strrchr:
    xor %rax, %rax
    ret

.balign 8
.globl strstr
.type strstr, %function
strstr:
    xor %rax, %rax
    ret

.balign 8
.globl strtok
.type strtok, %function
strtok:
    xor %rax, %rax
    ret

.balign 8
.globl strtol
.type strtol, %function
strtol:
    xor %rax, %rax
    ret

.balign 8
.globl strtod
.type strtod, %function
strtod:
    xor %rax, %rax
    ret

.balign 8
.globl memset
.type memset, %function
memset:
    xor %rax, %rax
    ret

.balign 8
.globl memcmp
.type memcmp, %function
memcmp:
    xor %rax, %rax
    ret

# File I/O
.balign 8
.globl fopen
.type fopen, %function
fopen:
    xor %rax, %rax
    ret

.balign 8
.globl fopen64
.type fopen64, %function
fopen64:
    xor %rax, %rax
    ret

.balign 8
.globl fclose
.type fclose, %function
fclose:
    xor %rax, %rax
    ret

.balign 8
.globl fread
.type fread, %function
fread:
    xor %rax, %rax
    ret

.balign 8
.globl fwrite
.type fwrite, %function
fwrite:
    xor %rax, %rax
    ret

.balign 8
.globl fseek
.type fseek, %function
fseek:
    xor %rax, %rax
    ret

.balign 8
.globl ftell
.type ftell, %function
ftell:
    xor %rax, %rax
    ret

.balign 8
.globl fflush
.type fflush, %function
fflush:
    xor %rax, %rax
    ret

.balign 8
.globl fgets
.type fgets, %function
fgets:
    xor %rax, %rax
    ret

.balign 8
.globl fputs
.type fputs, %function
fputs:
    xor %rax, %rax
    ret

.balign 8
.globl feof
.type feof, %function
feof:
    xor %rax, %rax
    ret

.balign 8
.globl ferror
.type ferror, %function
ferror:
    xor %rax, %rax
    ret

.balign 8
.globl rewind
.type rewind, %function
rewind:
    xor %rax, %rax
    ret

.balign 8
.globl remove
.type remove, %function
remove:
    xor %rax, %rax
    ret

.balign 8
.globl rename
.type rename, %function
rename:
    xor %rax, %rax
    ret

# printf/scanf family
.balign 8
.globl printf
.type printf, %function
printf:
    xor %rax, %rax
    ret

.balign 8
.globl fprintf
.type fprintf, %function
fprintf:
    xor %rax, %rax
    ret

.balign 8
.globl sprintf
.type sprintf, %function
sprintf:
    xor %rax, %rax
    ret

.balign 8
.globl snprintf
.type snprintf, %function
snprintf:
    xor %rax, %rax
    ret

.balign 8
.globl vprintf
.type vprintf, %function
vprintf:
    xor %rax, %rax
    ret

.balign 8
.globl vfprintf
.type vfprintf, %function
vfprintf:
    xor %rax, %rax
    ret

.balign 8
.globl vsprintf
.type vsprintf, %function
vsprintf:
    xor %rax, %rax
    ret

.balign 8
.globl vsnprintf
.type vsnprintf, %function
vsnprintf:
    xor %rax, %rax
    ret

.balign 8
.globl scanf
.type scanf, %function
scanf:
    xor %rax, %rax
    ret

.balign 8
.globl sscanf
.type sscanf, %function
sscanf:
    xor %rax, %rax
    ret

# Stdlib functions
.balign 8
.globl exit
.type exit, %function
exit:
    mov $60, %rax
    syscall

.balign 8
.globl _exit
.type _exit, %function
_exit:
    mov $60, %rax
    syscall

.balign 8
.globl atoi
.type atoi, %function
atoi:
    xor %rax, %rax
    ret

.balign 8
.globl atof
.type atof, %function
atof:
    xor %rax, %rax
    ret

.balign 8
.globl qsort
.type qsort, %function
qsort:
    xor %rax, %rax
    ret

.balign 8
.globl bsearch
.type bsearch, %function
bsearch:
    xor %rax, %rax
    ret

.balign 8
.globl rand
.type rand, %function
rand:
    xor %rax, %rax
    ret

.balign 8
.globl srand
.type srand, %function
srand:
    xor %rax, %rax
    ret

# Time functions
.balign 8
.globl time
.type time, %function
time:
    xor %rax, %rax
    ret

.balign 8
.globl clock
.type clock, %function
clock:
    xor %rax, %rax
    ret

.balign 8
.globl clock_gettime
.type clock_gettime, %function
clock_gettime:
    xor %rax, %rax
    ret

.balign 8
.globl nanosleep
.type nanosleep, %function
nanosleep:
    xor %rax, %rax
    ret

.balign 8
.globl usleep
.type usleep, %function
usleep:
    xor %rax, %rax
    ret

.balign 8
.globl gettimeofday
.type gettimeofday, %function
gettimeofday:
    xor %rax, %rax
    ret

# pthread functions
.balign 8
.globl pthread_create
.type pthread_create, %function
pthread_create:
    xor %rax, %rax
    ret

.balign 8
.globl pthread_join
.type pthread_join, %function
pthread_join:
    xor %rax, %rax
    ret

.balign 8
.globl pthread_mutex_init
.type pthread_mutex_init, %function
pthread_mutex_init:
    xor %rax, %rax
    ret

.balign 8
.globl pthread_mutex_destroy
.type pthread_mutex_destroy, %function
pthread_mutex_destroy:
    xor %rax, %rax
    ret

.balign 8
.globl pthread_mutex_lock
.type pthread_mutex_lock, %function
pthread_mutex_lock:
    xor %rax, %rax
    ret

.balign 8
.globl pthread_mutex_unlock
.type pthread_mutex_unlock, %function
pthread_mutex_unlock:
    xor %rax, %rax
    ret

.balign 8
.globl pthread_getspecific
.type pthread_getspecific, %function
pthread_getspecific:
    xor %rax, %rax
    ret

.balign 8
.globl pthread_setspecific
.type pthread_setspecific, %function
pthread_setspecific:
    xor %rax, %rax
    ret

.balign 8
.globl pthread_key_create
.type pthread_key_create, %function
pthread_key_create:
    xor %rax, %rax
    ret

.balign 8
.globl pthread_key_delete
.type pthread_key_delete, %function
pthread_key_delete:
    xor %rax, %rax
    ret

.balign 8
.globl pthread_once
.type pthread_once, %function
pthread_once:
    xor %rax, %rax
    ret

.balign 8
.globl pthread_self
.type pthread_self, %function
pthread_self:
    xor %rax, %rax
    ret

# Dynamic loading
.balign 8
.globl dlopen
.type dlopen, %function
dlopen:
    xor %rax, %rax
    ret

.balign 8
.globl dlclose
.type dlclose, %function
dlclose:
    xor %rax, %rax
    ret

.balign 8
.globl dlsym
.type dlsym, %function
dlsym:
    xor %rax, %rax
    ret

.balign 8
.globl dlerror
.type dlerror, %function
dlerror:
    xor %rax, %rax
    ret

# Misc
.balign 8
.globl setlocale
.type setlocale, %function
setlocale:
    xor %rax, %rax
    ret

.balign 8
.globl localeconv
.type localeconv, %function
localeconv:
    xor %rax, %rax
    ret

.balign 8
.globl getpid
.type getpid, %function
getpid:
    mov $39, %rax
    syscall
    ret

.balign 8
.globl open
.type open, %function
open:
    xor %rax, %rax
    ret

.balign 8
.globl open64
.type open64, %function
open64:
    xor %rax, %rax
    ret

.balign 8
.globl stat
.type stat, %function
stat:
    xor %rax, %rax
    ret

.balign 8
.globl stat64
.type stat64, %function
stat64:
    xor %rax, %rax
    ret

.balign 8
.globl fstat
.type fstat, %function
fstat:
    xor %rax, %rax
    ret

.balign 8
.globl fstat64
.type fstat64, %function
fstat64:
    xor %rax, %rax
    ret

.balign 8
.globl lstat
.type lstat, %function
lstat:
    xor %rax, %rax
    ret

.balign 8
.globl lstat64
.type lstat64, %function
lstat64:
    xor %rax, %rax
    ret

.balign 8
.globl access
.type access, %function
access:
    xor %rax, %rax
    ret

.balign 8
.globl getcwd
.type getcwd, %function
getcwd:
    xor %rax, %rax
    ret

.balign 8
.globl chdir
.type chdir, %function
chdir:
    xor %rax, %rax
    ret

.balign 8
.globl mkdir
.type mkdir, %function
mkdir:
    xor %rax, %rax
    ret

.balign 8
.globl rmdir
.type rmdir, %function
rmdir:
    xor %rax, %rax
    ret

.balign 8
.globl unlink
.type unlink, %function
unlink:
    xor %rax, %rax
    ret

.balign 8
.globl fcntl
.type fcntl, %function
fcntl:
    xor %rax, %rax
    ret

.balign 8
.globl fcntl64
.type fcntl64, %function
fcntl64:
    xor %rax, %rax
    ret

.balign 8
.globl ioctl
.type ioctl, %function
ioctl:
    xor %rax, %rax
    ret

.balign 8
.globl poll
.type poll, %function
poll:
    xor %rax, %rax
    ret

.balign 8
.globl select
.type select, %function
select:
    xor %rax, %rax
    ret

.balign 8
.globl pipe
.type pipe, %function
pipe:
    xor %rax, %rax
    ret

.balign 8
.globl dup
.type dup, %function
dup:
    xor %rax, %rax
    ret

.balign 8
.globl dup2
.type dup2, %function
dup2:
    xor %rax, %rax
    ret

.balign 8
.globl socket
.type socket, %function
socket:
    xor %rax, %rax
    ret

.balign 8
.globl connect
.type connect, %function
connect:
    xor %rax, %rax
    ret

.balign 8
.globl bind
.type bind, %function
bind:
    xor %rax, %rax
    ret

.balign 8
.globl listen
.type listen, %function
listen:
    xor %rax, %rax
    ret

.balign 8
.globl accept
.type accept, %function
accept:
    xor %rax, %rax
    ret

.balign 8
.globl send
.type send, %function
send:
    xor %rax, %rax
    ret

.balign 8
.globl recv
.type recv, %function
recv:
    xor %rax, %rax
    ret

.balign 8
.globl setsockopt
.type setsockopt, %function
setsockopt:
    xor %rax, %rax
    ret

.balign 8
.globl getsockopt
.type getsockopt, %function
getsockopt:
    xor %rax, %rax
    ret

.balign 8
.globl shutdown
.type shutdown, %function
shutdown:
    xor %rax, %rax
    ret

# ctype functions
.balign 8
.globl isalpha
.type isalpha, %function
isalpha:
    xor %rax, %rax
    ret

.balign 8
.globl isdigit
.type isdigit, %function
isdigit:
    xor %rax, %rax
    ret

.balign 8
.globl isalnum
.type isalnum, %function
isalnum:
    xor %rax, %rax
    ret

.balign 8
.globl isspace
.type isspace, %function
isspace:
    xor %rax, %rax
    ret

.balign 8
.globl isupper
.type isupper, %function
isupper:
    xor %rax, %rax
    ret

.balign 8
.globl islower
.type islower, %function
islower:
    xor %rax, %rax
    ret

.balign 8
.globl toupper
.type toupper, %function
toupper:
    xor %rax, %rax
    ret

.balign 8
.globl tolower
.type tolower, %function
tolower:
    xor %rax, %rax
    ret

# X11 related that raylib needs
.balign 8
.globl XOpenDisplay
.type XOpenDisplay, %function
XOpenDisplay:
    xor %rax, %rax
    ret

.balign 8
.globl XCloseDisplay
.type XCloseDisplay, %function
XCloseDisplay:
    xor %rax, %rax
    ret

# Data section
.data
_IO_stdin_used: .quad 1
.globl environ
.type environ, %object
environ: .quad 0

.globl stdout
.type stdout, %object
stdout: .quad 0

.globl stdin
.type stdin, %object
stdin: .quad 0

.globl stderr
.type stderr, %object
stderr: .quad 0

.globl __stack_chk_guard
.type __stack_chk_guard, %object
__stack_chk_guard: .quad 0

# Stack check failure stub
.text
.balign 8
.globl __stack_chk_fail
.type __stack_chk_fail, %function
__stack_chk_fail:
    mov $1, %rdi
    mov $60, %rax
    syscall

# Additional missing symbols for raylib/glfw

# C23 function aliases
.balign 8
.globl __isoc23_strtol
.type __isoc23_strtol, %function
__isoc23_strtol:
    xor %rax, %rax
    ret

.balign 8
.globl __isoc23_sscanf
.type __isoc23_sscanf, %function
__isoc23_sscanf:
    xor %rax, %rax
    ret

.balign 8
.globl __isoc23_strtoul
.type __isoc23_strtoul, %function
__isoc23_strtoul:
    xor %rax, %rax
    ret

# String functions
.balign 8
.globl strcspn
.type strcspn, %function
strcspn:
    xor %rax, %rax
    ret

.balign 8
.globl strspn
.type strspn, %function
strspn:
    xor %rax, %rax
    ret

.balign 8
.globl strdup
.type strdup, %function
strdup:
    xor %rax, %rax
    ret

.balign 8
.globl strerror
.type strerror, %function
strerror:
    xor %rax, %rax
    ret

# Math functions
.balign 8
.globl hypotf
.type hypotf, %function
hypotf:
    xor %rax, %rax
    ret

.balign 8
.globl hypot
.type hypot, %function
hypot:
    xor %rax, %rax
    ret

# Poll/select
.balign 8
.globl ppoll
.type ppoll, %function
ppoll:
    xor %rax, %rax
    ret

# Regex
.balign 8
.globl regexec
.type regexec, %function
regexec:
    xor %rax, %rax
    ret

.balign 8
.globl regcomp
.type regcomp, %function
regcomp:
    xor %rax, %rax
    ret

.balign 8
.globl regfree
.type regfree, %function
regfree:
    xor %rax, %rax
    ret

# inotify
.balign 8
.globl inotify_init1
.type inotify_init1, %function
inotify_init1:
    xor %rax, %rax
    ret

.balign 8
.globl inotify_add_watch
.type inotify_add_watch, %function
inotify_add_watch:
    xor %rax, %rax
    ret

.balign 8
.globl inotify_rm_watch
.type inotify_rm_watch, %function
inotify_rm_watch:
    xor %rax, %rax
    ret

# Directory functions
.balign 8
.globl opendir
.type opendir, %function
opendir:
    xor %rax, %rax
    ret

.balign 8
.globl readdir
.type readdir, %function
readdir:
    xor %rax, %rax
    ret

.balign 8
.globl closedir
.type closedir, %function
closedir:
    xor %rax, %rax
    ret

.balign 8
.globl readdir64
.type readdir64, %function
readdir64:
    xor %rax, %rax
    ret

# File I/O
.balign 8
.globl fgetc
.type fgetc, %function
fgetc:
    xor %rax, %rax
    ret

.balign 8
.globl ungetc
.type ungetc, %function
ungetc:
    xor %rax, %rax
    ret

.balign 8
.globl getc
.type getc, %function
getc:
    xor %rax, %rax
    ret

.balign 8
.globl putc
.type putc, %function
putc:
    xor %rax, %rax
    ret

.balign 8
.globl putchar
.type putchar, %function
putchar:
    xor %rax, %rax
    ret

.balign 8
.globl getchar
.type getchar, %function
getchar:
    xor %rax, %rax
    ret

.balign 8
.globl puts
.type puts, %function
puts:
    xor %rax, %rax
    ret

.balign 8
.globl fileno
.type fileno, %function
fileno:
    xor %rax, %rax
    ret

.balign 8
.globl fdopen
.type fdopen, %function
fdopen:
    xor %rax, %rax
    ret

.balign 8
.globl freopen
.type freopen, %function
freopen:
    xor %rax, %rax
    ret

.balign 8
.globl setvbuf
.type setvbuf, %function
setvbuf:
    xor %rax, %rax
    ret

.balign 8
.globl setbuf
.type setbuf, %function
setbuf:
    xor %rax, %rax
    ret

# X11 specific
.balign 8
.globl XInitThreads
.type XInitThreads, %function
XInitThreads:
    xor %rax, %rax
    ret

# Misc system
.balign 8
.globl getuid
.type getuid, %function
getuid:
    xor %rax, %rax
    ret

.balign 8
.globl geteuid
.type geteuid, %function
geteuid:
    xor %rax, %rax
    ret

.balign 8
.globl getgid
.type getgid, %function
getgid:
    xor %rax, %rax
    ret

.balign 8
.globl getegid
.type getegid, %function
getegid:
    xor %rax, %rax
    ret

.balign 8
.globl getpwuid_r
.type getpwuid_r, %function
getpwuid_r:
    xor %rax, %rax
    ret

.balign 8
.globl setenv
.type setenv, %function
setenv:
    xor %rax, %rax
    ret

.balign 8
.globl unsetenv
.type unsetenv, %function
unsetenv:
    xor %rax, %rax
    ret

.balign 8
.globl uname
.type uname, %function
uname:
    xor %rax, %rax
    ret

.balign 8
.globl mprotect
.type mprotect, %function
mprotect:
    xor %rax, %rax
    ret

.balign 8
.globl ftruncate
.type ftruncate, %function
ftruncate:
    xor %rax, %rax
    ret

.balign 8
.globl ftruncate64
.type ftruncate64, %function
ftruncate64:
    xor %rax, %rax
    ret

.balign 8
.globl sched_yield
.type sched_yield, %function
sched_yield:
    xor %rax, %rax
    ret

.balign 8
.globl sched_getaffinity
.type sched_getaffinity, %function
sched_getaffinity:
    xor %rax, %rax
    ret

.balign 8
.globl __cxa_atexit
.type __cxa_atexit, %function
__cxa_atexit:
    xor %rax, %rax
    ret

.balign 8
.globl atexit
.type atexit, %function
atexit:
    xor %rax, %rax
    ret

# errno
.balign 8
.globl __h_errno_location
.type __h_errno_location, %function
__h_errno_location:
    xor %rax, %rax
    ret

# wide char
.balign 8
.globl wcslen
.type wcslen, %function
wcslen:
    xor %rax, %rax
    ret

.balign 8
.globl wcscpy
.type wcscpy, %function
wcscpy:
    xor %rax, %rax
    ret

.balign 8
.globl wcsncpy
.type wcsncpy, %function
wcsncpy:
    xor %rax, %rax
    ret

.balign 8
.globl mbstowcs
.type mbstowcs, %function
mbstowcs:
    xor %rax, %rax
    ret

.balign 8
.globl wcstombs
.type wcstombs, %function
wcstombs:
    xor %rax, %rax
    ret

# semaphore/futex
.balign 8
.globl sem_init
.type sem_init, %function
sem_init:
    xor %rax, %rax
    ret

.balign 8
.globl sem_destroy
.type sem_destroy, %function
sem_destroy:
    xor %rax, %rax
    ret

.balign 8
.globl sem_wait
.type sem_wait, %function
sem_wait:
    xor %rax, %rax
    ret

.balign 8
.globl sem_post
.type sem_post, %function
sem_post:
    xor %rax, %rax
    ret

# getaddrinfo/hostname
.balign 8
.globl getaddrinfo
.type getaddrinfo, %function
getaddrinfo:
    xor %rax, %rax
    ret

.balign 8
.globl freeaddrinfo
.type freeaddrinfo, %function
freeaddrinfo:
    xor %rax, %rax
    ret

.balign 8
.globl gethostname
.type gethostname, %function
gethostname:
    xor %rax, %rax
    ret

.balign 8
.globl gai_strerror
.type gai_strerror, %function
gai_strerror:
    xor %rax, %rax
    ret

# More file I/O
.balign 8
.globl preadv64
.type preadv64, %function
preadv64:
    xor %rax, %rax
    ret

.balign 8
.globl pwritev64v2
.type pwritev64v2, %function
pwritev64v2:
    xor %rax, %rax
    ret

# Process control
.balign 8
.globl system
.type system, %function
system:
    xor %rax, %rax
    ret

.balign 8
.globl fork
.type fork, %function
fork:
    xor %rax, %rax
    ret

.balign 8
.globl execve
.type execve, %function
execve:
    xor %rax, %rax
    ret

.balign 8
.globl waitpid
.type waitpid, %function
waitpid:
    xor %rax, %rax
    ret

# String
.balign 8
.globl strpbrk
.type strpbrk, %function
strpbrk:
    xor %rax, %rax
    ret

# Additional symbols needed
.balign 8
.globl __isoc99_sscanf
.type __isoc99_sscanf, %function
__isoc99_sscanf:
    xor %rax, %rax
    ret

.balign 8
.globl strtoul
.type strtoul, %function
strtoul:
    xor %rax, %rax
    ret

# glibc FORTIFY_SOURCE functions (needed by raylib compiled with glibc)
.balign 8
.globl __assert_fail
.type __assert_fail, %function
__assert_fail:
    xor %rax, %rax
    ret

.balign 8
.globl __vfprintf_chk
.type __vfprintf_chk, %function
__vfprintf_chk:
    xor %rax, %rax
    ret

.balign 8
.globl __fprintf_chk
.type __fprintf_chk, %function
__fprintf_chk:
    xor %rax, %rax
    ret

.balign 8
.globl __printf_chk
.type __printf_chk, %function
__printf_chk:
    xor %rax, %rax
    ret

.balign 8
.globl __sprintf_chk
.type __sprintf_chk, %function
__sprintf_chk:
    xor %rax, %rax
    ret

.balign 8
.globl __snprintf_chk
.type __snprintf_chk, %function
__snprintf_chk:
    xor %rax, %rax
    ret

.balign 8
.globl __vsnprintf_chk
.type __vsnprintf_chk, %function
__vsnprintf_chk:
    xor %rax, %rax
    ret

.balign 8
.globl __xstat
.type __xstat, %function
__xstat:
    xor %rax, %rax
    ret
