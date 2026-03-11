.text

# libc stub for ARM64 (aarch64) Linux
# Provides symbol definitions for link-time; runtime uses system libc.so.6

.balign 8
.globl __sysctl
.type __sysctl, %function
__sysctl:
    mov x0, #0
    ret

.balign 8
.globl __libc_start_main
.type __libc_start_main, %function
__libc_start_main:
    mov x0, #0
    ret

.balign 8
.globl abort
.type abort, %function
abort:
    mov x0, #1
    mov x8, #93
    svc #0

.balign 8
.globl getauxval
.type getauxval, %function
getauxval:
    mov x0, #0
    ret

.balign 8
.globl __tls_get_addr
.type __tls_get_addr, %function
__tls_get_addr:
    mov x0, #0
    ret

.balign 8
.globl __errno_location
.type __errno_location, %function
__errno_location:
    mov x0, #0
    ret

.balign 8
.globl memcpy
.type memcpy, %function
memcpy:
    mov x0, #0
    ret

.balign 8
.globl memmove
.type memmove, %function
memmove:
    mov x0, #0
    ret

.balign 8
.globl mmap
.type mmap, %function
mmap:
    mov x0, #0
    ret

.balign 8
.globl mmap64
.type mmap64, %function
mmap64:
    mov x0, #0
    ret

.balign 8
.globl munmap
.type munmap, %function
munmap:
    mov x0, #0
    ret

.balign 8
.globl mremap
.type mremap, %function
mremap:
    mov x0, #0
    ret

.balign 8
.globl msync
.type msync, %function
msync:
    mov x0, #0
    ret

.balign 8
.globl malloc
.type malloc, %function
malloc:
    mov x0, #0
    ret

.balign 8
.globl calloc
.type calloc, %function
calloc:
    mov x0, #0
    ret

.balign 8
.globl realloc
.type realloc, %function
realloc:
    mov x0, #0
    ret

.balign 8
.globl free
.type free, %function
free:
    mov x0, #0
    ret

.balign 8
.globl posix_memalign
.type posix_memalign, %function
posix_memalign:
    mov x0, #0
    ret

.balign 8
.globl malloc_usable_size
.type malloc_usable_size, %function
malloc_usable_size:
    mov x0, #0
    ret

.balign 8
.globl close
.type close, %function
close:
    mov x0, #0
    ret

.balign 8
.globl read
.type read, %function
read:
    mov x0, #0
    ret

.balign 8
.globl write
.type write, %function
write:
    mov x0, #0
    ret

.balign 8
.globl readv
.type readv, %function
readv:
    mov x0, #0
    ret

.balign 8
.globl writev
.type writev, %function
writev:
    mov x0, #0
    ret

.balign 8
.globl openat64
.type openat64, %function
openat64:
    mov x0, #0
    ret

.balign 8
.globl lseek64
.type lseek64, %function
lseek64:
    mov x0, #0
    ret

.balign 8
.globl pread64
.type pread64, %function
pread64:
    mov x0, #0
    ret

.balign 8
.globl pwritev64
.type pwritev64, %function
pwritev64:
    mov x0, #0
    ret

.balign 8
.globl flock
.type flock, %function
flock:
    mov x0, #0
    ret

.balign 8
.globl copy_file_range
.type copy_file_range, %function
copy_file_range:
    mov x0, #0
    ret

.balign 8
.globl sendfile64
.type sendfile64, %function
sendfile64:
    mov x0, #0
    ret

.balign 8
.globl realpath
.type realpath, %function
realpath:
    mov x0, #0
    ret

.balign 8
.globl readlink
.type readlink, %function
readlink:
    mov x0, #0
    ret

.balign 8
.globl getenv
.type getenv, %function
getenv:
    mov x0, #0
    ret

.balign 8
.globl isatty
.type isatty, %function
isatty:
    mov x0, #0
    ret

.balign 8
.globl sysconf
.type sysconf, %function
sysconf:
    mov x0, #0
    ret

.balign 8
.globl sigaction
.type sigaction, %function
sigaction:
    mov x0, #0
    ret

.balign 8
.globl sigemptyset
.type sigemptyset, %function
sigemptyset:
    mov x0, #0
    ret

.balign 8
.globl dl_iterate_phdr
.type dl_iterate_phdr, %function
dl_iterate_phdr:
    mov x0, #0
    ret

.balign 8
.globl getcontext
.type getcontext, %function
getcontext:
    mov x0, #0
    ret

.balign 8
.globl fmod
.type fmod, %function
fmod:
    mov x0, #0
    ret

.balign 8
.globl fmodf
.type fmodf, %function
fmodf:
    mov x0, #0
    ret

.balign 8
.globl trunc
.type trunc, %function
trunc:
    mov x0, #0
    ret

.balign 8
.globl truncf
.type truncf, %function
truncf:
    mov x0, #0
    ret

.balign 8
.globl acosf
.type acosf, %function
acosf:
    mov x0, #0
    ret

.balign 8
.globl acos
.type acos, %function
acos:
    mov x0, #0
    ret

.balign 8
.globl asinf
.type asinf, %function
asinf:
    mov x0, #0
    ret

.balign 8
.globl asin
.type asin, %function
asin:
    mov x0, #0
    ret

.balign 8
.globl atanf
.type atanf, %function
atanf:
    mov x0, #0
    ret

.balign 8
.globl atan
.type atan, %function
atan:
    mov x0, #0
    ret

.balign 8
.globl atan2f
.type atan2f, %function
atan2f:
    mov x0, #0
    ret

.balign 8
.globl atan2
.type atan2, %function
atan2:
    mov x0, #0
    ret

.balign 8
.globl cosf
.type cosf, %function
cosf:
    mov x0, #0
    ret

.balign 8
.globl cos
.type cos, %function
cos:
    mov x0, #0
    ret

.balign 8
.globl sinf
.type sinf, %function
sinf:
    mov x0, #0
    ret

.balign 8
.globl sin
.type sin, %function
sin:
    mov x0, #0
    ret

.balign 8
.globl tanf
.type tanf, %function
tanf:
    mov x0, #0
    ret

.balign 8
.globl tan
.type tan, %function
tan:
    mov x0, #0
    ret

.balign 8
.globl sqrtf
.type sqrtf, %function
sqrtf:
    mov x0, #0
    ret

.balign 8
.globl sqrt
.type sqrt, %function
sqrt:
    mov x0, #0
    ret

.balign 8
.globl powf
.type powf, %function
powf:
    mov x0, #0
    ret

.balign 8
.globl pow
.type pow, %function
pow:
    mov x0, #0
    ret

.balign 8
.globl expf
.type expf, %function
expf:
    mov x0, #0
    ret

.balign 8
.globl exp
.type exp, %function
exp:
    mov x0, #0
    ret

.balign 8
.globl logf
.type logf, %function
logf:
    mov x0, #0
    ret

.balign 8
.globl log
.type log, %function
log:
    mov x0, #0
    ret

.balign 8
.globl log10f
.type log10f, %function
log10f:
    mov x0, #0
    ret

.balign 8
.globl log10
.type log10, %function
log10:
    mov x0, #0
    ret

.balign 8
.globl floorf
.type floorf, %function
floorf:
    mov x0, #0
    ret

.balign 8
.globl floor
.type floor, %function
floor:
    mov x0, #0
    ret

.balign 8
.globl ceilf
.type ceilf, %function
ceilf:
    mov x0, #0
    ret

.balign 8
.globl ceil
.type ceil, %function
ceil:
    mov x0, #0
    ret

.balign 8
.globl fabsf
.type fabsf, %function
fabsf:
    mov x0, #0
    ret

.balign 8
.globl fabs
.type fabs, %function
fabs:
    mov x0, #0
    ret

.balign 8
.globl roundf
.type roundf, %function
roundf:
    mov x0, #0
    ret

.balign 8
.globl round
.type round, %function
round:
    mov x0, #0
    ret

.balign 8
.globl ldexp
.type ldexp, %function
ldexp:
    mov x0, #0
    ret

.balign 8
.globl ldexpf
.type ldexpf, %function
ldexpf:
    mov x0, #0
    ret

.balign 8
.globl frexp
.type frexp, %function
frexp:
    mov x0, #0
    ret

.balign 8
.globl frexpf
.type frexpf, %function
frexpf:
    mov x0, #0
    ret

.balign 8
.globl strlen
.type strlen, %function
strlen:
    mov x0, #0
    ret

.balign 8
.globl strcpy
.type strcpy, %function
strcpy:
    mov x0, #0
    ret

.balign 8
.globl strncpy
.type strncpy, %function
strncpy:
    mov x0, #0
    ret

.balign 8
.globl strcat
.type strcat, %function
strcat:
    mov x0, #0
    ret

.balign 8
.globl strncat
.type strncat, %function
strncat:
    mov x0, #0
    ret

.balign 8
.globl strcmp
.type strcmp, %function
strcmp:
    mov x0, #0
    ret

.balign 8
.globl strncmp
.type strncmp, %function
strncmp:
    mov x0, #0
    ret

.balign 8
.globl strchr
.type strchr, %function
strchr:
    mov x0, #0
    ret

.balign 8
.globl strrchr
.type strrchr, %function
strrchr:
    mov x0, #0
    ret

.balign 8
.globl strstr
.type strstr, %function
strstr:
    mov x0, #0
    ret

.balign 8
.globl strtok
.type strtok, %function
strtok:
    mov x0, #0
    ret

.balign 8
.globl strtol
.type strtol, %function
strtol:
    mov x0, #0
    ret

.balign 8
.globl strtod
.type strtod, %function
strtod:
    mov x0, #0
    ret

.balign 8
.globl memset
.type memset, %function
memset:
    mov x0, #0
    ret

.balign 8
.globl memcmp
.type memcmp, %function
memcmp:
    mov x0, #0
    ret

.balign 8
.globl fopen
.type fopen, %function
fopen:
    mov x0, #0
    ret

.balign 8
.globl fopen64
.type fopen64, %function
fopen64:
    mov x0, #0
    ret

.balign 8
.globl fclose
.type fclose, %function
fclose:
    mov x0, #0
    ret

.balign 8
.globl fread
.type fread, %function
fread:
    mov x0, #0
    ret

.balign 8
.globl fwrite
.type fwrite, %function
fwrite:
    mov x0, #0
    ret

.balign 8
.globl fseek
.type fseek, %function
fseek:
    mov x0, #0
    ret

.balign 8
.globl ftell
.type ftell, %function
ftell:
    mov x0, #0
    ret

.balign 8
.globl fflush
.type fflush, %function
fflush:
    mov x0, #0
    ret

.balign 8
.globl fgets
.type fgets, %function
fgets:
    mov x0, #0
    ret

.balign 8
.globl fputs
.type fputs, %function
fputs:
    mov x0, #0
    ret

.balign 8
.globl feof
.type feof, %function
feof:
    mov x0, #0
    ret

.balign 8
.globl ferror
.type ferror, %function
ferror:
    mov x0, #0
    ret

.balign 8
.globl rewind
.type rewind, %function
rewind:
    mov x0, #0
    ret

.balign 8
.globl remove
.type remove, %function
remove:
    mov x0, #0
    ret

.balign 8
.globl rename
.type rename, %function
rename:
    mov x0, #0
    ret

.balign 8
.globl printf
.type printf, %function
printf:
    mov x0, #0
    ret

.balign 8
.globl fprintf
.type fprintf, %function
fprintf:
    mov x0, #0
    ret

.balign 8
.globl sprintf
.type sprintf, %function
sprintf:
    mov x0, #0
    ret

.balign 8
.globl snprintf
.type snprintf, %function
snprintf:
    mov x0, #0
    ret

.balign 8
.globl vprintf
.type vprintf, %function
vprintf:
    mov x0, #0
    ret

.balign 8
.globl vfprintf
.type vfprintf, %function
vfprintf:
    mov x0, #0
    ret

.balign 8
.globl vsprintf
.type vsprintf, %function
vsprintf:
    mov x0, #0
    ret

.balign 8
.globl vsnprintf
.type vsnprintf, %function
vsnprintf:
    mov x0, #0
    ret

.balign 8
.globl scanf
.type scanf, %function
scanf:
    mov x0, #0
    ret

.balign 8
.globl sscanf
.type sscanf, %function
sscanf:
    mov x0, #0
    ret

.balign 8
.globl exit
.type exit, %function
exit:
    mov x8, #93
    svc #0

.balign 8
.globl _exit
.type _exit, %function
_exit:
    mov x8, #93
    svc #0

.balign 8
.globl atoi
.type atoi, %function
atoi:
    mov x0, #0
    ret

.balign 8
.globl atof
.type atof, %function
atof:
    mov x0, #0
    ret

.balign 8
.globl qsort
.type qsort, %function
qsort:
    mov x0, #0
    ret

.balign 8
.globl bsearch
.type bsearch, %function
bsearch:
    mov x0, #0
    ret

.balign 8
.globl rand
.type rand, %function
rand:
    mov x0, #0
    ret

.balign 8
.globl srand
.type srand, %function
srand:
    mov x0, #0
    ret

.balign 8
.globl time
.type time, %function
time:
    mov x0, #0
    ret

.balign 8
.globl clock
.type clock, %function
clock:
    mov x0, #0
    ret

.balign 8
.globl clock_gettime
.type clock_gettime, %function
clock_gettime:
    mov x0, #0
    ret

.balign 8
.globl nanosleep
.type nanosleep, %function
nanosleep:
    mov x0, #0
    ret

.balign 8
.globl usleep
.type usleep, %function
usleep:
    mov x0, #0
    ret

.balign 8
.globl gettimeofday
.type gettimeofday, %function
gettimeofday:
    mov x0, #0
    ret

.balign 8
.globl pthread_create
.type pthread_create, %function
pthread_create:
    mov x0, #0
    ret

.balign 8
.globl pthread_join
.type pthread_join, %function
pthread_join:
    mov x0, #0
    ret

.balign 8
.globl pthread_mutex_init
.type pthread_mutex_init, %function
pthread_mutex_init:
    mov x0, #0
    ret

.balign 8
.globl pthread_mutex_destroy
.type pthread_mutex_destroy, %function
pthread_mutex_destroy:
    mov x0, #0
    ret

.balign 8
.globl pthread_mutex_lock
.type pthread_mutex_lock, %function
pthread_mutex_lock:
    mov x0, #0
    ret

.balign 8
.globl pthread_mutex_unlock
.type pthread_mutex_unlock, %function
pthread_mutex_unlock:
    mov x0, #0
    ret

.balign 8
.globl pthread_getspecific
.type pthread_getspecific, %function
pthread_getspecific:
    mov x0, #0
    ret

.balign 8
.globl pthread_setspecific
.type pthread_setspecific, %function
pthread_setspecific:
    mov x0, #0
    ret

.balign 8
.globl pthread_key_create
.type pthread_key_create, %function
pthread_key_create:
    mov x0, #0
    ret

.balign 8
.globl pthread_key_delete
.type pthread_key_delete, %function
pthread_key_delete:
    mov x0, #0
    ret

.balign 8
.globl pthread_once
.type pthread_once, %function
pthread_once:
    mov x0, #0
    ret

.balign 8
.globl pthread_self
.type pthread_self, %function
pthread_self:
    mov x0, #0
    ret

.balign 8
.globl dlopen
.type dlopen, %function
dlopen:
    mov x0, #0
    ret

.balign 8
.globl dlclose
.type dlclose, %function
dlclose:
    mov x0, #0
    ret

.balign 8
.globl dlsym
.type dlsym, %function
dlsym:
    mov x0, #0
    ret

.balign 8
.globl dlerror
.type dlerror, %function
dlerror:
    mov x0, #0
    ret

.balign 8
.globl setlocale
.type setlocale, %function
setlocale:
    mov x0, #0
    ret

.balign 8
.globl localeconv
.type localeconv, %function
localeconv:
    mov x0, #0
    ret

.balign 8
.globl getpid
.type getpid, %function
getpid:
    mov x8, #172
    svc #0
    ret

.balign 8
.globl open
.type open, %function
open:
    mov x0, #0
    ret

.balign 8
.globl open64
.type open64, %function
open64:
    mov x0, #0
    ret

.balign 8
.globl stat
.type stat, %function
stat:
    mov x0, #0
    ret

.balign 8
.globl stat64
.type stat64, %function
stat64:
    mov x0, #0
    ret

.balign 8
.globl fstat
.type fstat, %function
fstat:
    mov x0, #0
    ret

.balign 8
.globl fstat64
.type fstat64, %function
fstat64:
    mov x0, #0
    ret

.balign 8
.globl lstat
.type lstat, %function
lstat:
    mov x0, #0
    ret

.balign 8
.globl lstat64
.type lstat64, %function
lstat64:
    mov x0, #0
    ret

.balign 8
.globl access
.type access, %function
access:
    mov x0, #0
    ret

.balign 8
.globl getcwd
.type getcwd, %function
getcwd:
    mov x0, #0
    ret

.balign 8
.globl chdir
.type chdir, %function
chdir:
    mov x0, #0
    ret

.balign 8
.globl mkdir
.type mkdir, %function
mkdir:
    mov x0, #0
    ret

.balign 8
.globl rmdir
.type rmdir, %function
rmdir:
    mov x0, #0
    ret

.balign 8
.globl unlink
.type unlink, %function
unlink:
    mov x0, #0
    ret

.balign 8
.globl fcntl
.type fcntl, %function
fcntl:
    mov x0, #0
    ret

.balign 8
.globl fcntl64
.type fcntl64, %function
fcntl64:
    mov x0, #0
    ret

.balign 8
.globl ioctl
.type ioctl, %function
ioctl:
    mov x0, #0
    ret

.balign 8
.globl poll
.type poll, %function
poll:
    mov x0, #0
    ret

.balign 8
.globl select
.type select, %function
select:
    mov x0, #0
    ret

.balign 8
.globl pipe
.type pipe, %function
pipe:
    mov x0, #0
    ret

.balign 8
.globl dup
.type dup, %function
dup:
    mov x0, #0
    ret

.balign 8
.globl dup2
.type dup2, %function
dup2:
    mov x0, #0
    ret

.balign 8
.globl socket
.type socket, %function
socket:
    mov x0, #0
    ret

.balign 8
.globl connect
.type connect, %function
connect:
    mov x0, #0
    ret

.balign 8
.globl bind
.type bind, %function
bind:
    mov x0, #0
    ret

.balign 8
.globl listen
.type listen, %function
listen:
    mov x0, #0
    ret

.balign 8
.globl accept
.type accept, %function
accept:
    mov x0, #0
    ret

.balign 8
.globl send
.type send, %function
send:
    mov x0, #0
    ret

.balign 8
.globl recv
.type recv, %function
recv:
    mov x0, #0
    ret

.balign 8
.globl setsockopt
.type setsockopt, %function
setsockopt:
    mov x0, #0
    ret

.balign 8
.globl getsockopt
.type getsockopt, %function
getsockopt:
    mov x0, #0
    ret

.balign 8
.globl shutdown
.type shutdown, %function
shutdown:
    mov x0, #0
    ret

.balign 8
.globl isalpha
.type isalpha, %function
isalpha:
    mov x0, #0
    ret

.balign 8
.globl isdigit
.type isdigit, %function
isdigit:
    mov x0, #0
    ret

.balign 8
.globl isalnum
.type isalnum, %function
isalnum:
    mov x0, #0
    ret

.balign 8
.globl isspace
.type isspace, %function
isspace:
    mov x0, #0
    ret

.balign 8
.globl isupper
.type isupper, %function
isupper:
    mov x0, #0
    ret

.balign 8
.globl islower
.type islower, %function
islower:
    mov x0, #0
    ret

.balign 8
.globl toupper
.type toupper, %function
toupper:
    mov x0, #0
    ret

.balign 8
.globl tolower
.type tolower, %function
tolower:
    mov x0, #0
    ret

.balign 8
.globl XOpenDisplay
.type XOpenDisplay, %function
XOpenDisplay:
    mov x0, #0
    ret

.balign 8
.globl XCloseDisplay
.type XCloseDisplay, %function
XCloseDisplay:
    mov x0, #0
    ret

.balign 8
.globl __stack_chk_fail
.type __stack_chk_fail, %function
__stack_chk_fail:
    mov x0, #1
    mov x8, #93
    svc #0

.balign 8
.globl __isoc23_strtol
.type __isoc23_strtol, %function
__isoc23_strtol:
    mov x0, #0
    ret

.balign 8
.globl __isoc23_sscanf
.type __isoc23_sscanf, %function
__isoc23_sscanf:
    mov x0, #0
    ret

.balign 8
.globl __isoc23_strtoul
.type __isoc23_strtoul, %function
__isoc23_strtoul:
    mov x0, #0
    ret

.balign 8
.globl strcspn
.type strcspn, %function
strcspn:
    mov x0, #0
    ret

.balign 8
.globl strspn
.type strspn, %function
strspn:
    mov x0, #0
    ret

.balign 8
.globl strdup
.type strdup, %function
strdup:
    mov x0, #0
    ret

.balign 8
.globl strerror
.type strerror, %function
strerror:
    mov x0, #0
    ret

.balign 8
.globl hypotf
.type hypotf, %function
hypotf:
    mov x0, #0
    ret

.balign 8
.globl hypot
.type hypot, %function
hypot:
    mov x0, #0
    ret

.balign 8
.globl ppoll
.type ppoll, %function
ppoll:
    mov x0, #0
    ret

.balign 8
.globl regexec
.type regexec, %function
regexec:
    mov x0, #0
    ret

.balign 8
.globl regcomp
.type regcomp, %function
regcomp:
    mov x0, #0
    ret

.balign 8
.globl regfree
.type regfree, %function
regfree:
    mov x0, #0
    ret

.balign 8
.globl inotify_init1
.type inotify_init1, %function
inotify_init1:
    mov x0, #0
    ret

.balign 8
.globl inotify_add_watch
.type inotify_add_watch, %function
inotify_add_watch:
    mov x0, #0
    ret

.balign 8
.globl inotify_rm_watch
.type inotify_rm_watch, %function
inotify_rm_watch:
    mov x0, #0
    ret

.balign 8
.globl opendir
.type opendir, %function
opendir:
    mov x0, #0
    ret

.balign 8
.globl readdir
.type readdir, %function
readdir:
    mov x0, #0
    ret

.balign 8
.globl closedir
.type closedir, %function
closedir:
    mov x0, #0
    ret

.balign 8
.globl readdir64
.type readdir64, %function
readdir64:
    mov x0, #0
    ret

.balign 8
.globl fgetc
.type fgetc, %function
fgetc:
    mov x0, #0
    ret

.balign 8
.globl ungetc
.type ungetc, %function
ungetc:
    mov x0, #0
    ret

.balign 8
.globl getc
.type getc, %function
getc:
    mov x0, #0
    ret

.balign 8
.globl putc
.type putc, %function
putc:
    mov x0, #0
    ret

.balign 8
.globl putchar
.type putchar, %function
putchar:
    mov x0, #0
    ret

.balign 8
.globl getchar
.type getchar, %function
getchar:
    mov x0, #0
    ret

.balign 8
.globl puts
.type puts, %function
puts:
    mov x0, #0
    ret

.balign 8
.globl fileno
.type fileno, %function
fileno:
    mov x0, #0
    ret

.balign 8
.globl fdopen
.type fdopen, %function
fdopen:
    mov x0, #0
    ret

.balign 8
.globl freopen
.type freopen, %function
freopen:
    mov x0, #0
    ret

.balign 8
.globl setvbuf
.type setvbuf, %function
setvbuf:
    mov x0, #0
    ret

.balign 8
.globl setbuf
.type setbuf, %function
setbuf:
    mov x0, #0
    ret

.balign 8
.globl XInitThreads
.type XInitThreads, %function
XInitThreads:
    mov x0, #0
    ret

.balign 8
.globl getuid
.type getuid, %function
getuid:
    mov x0, #0
    ret

.balign 8
.globl geteuid
.type geteuid, %function
geteuid:
    mov x0, #0
    ret

.balign 8
.globl getgid
.type getgid, %function
getgid:
    mov x0, #0
    ret

.balign 8
.globl getegid
.type getegid, %function
getegid:
    mov x0, #0
    ret

.balign 8
.globl getpwuid_r
.type getpwuid_r, %function
getpwuid_r:
    mov x0, #0
    ret

.balign 8
.globl setenv
.type setenv, %function
setenv:
    mov x0, #0
    ret

.balign 8
.globl unsetenv
.type unsetenv, %function
unsetenv:
    mov x0, #0
    ret

.balign 8
.globl uname
.type uname, %function
uname:
    mov x0, #0
    ret

.balign 8
.globl mprotect
.type mprotect, %function
mprotect:
    mov x0, #0
    ret

.balign 8
.globl ftruncate
.type ftruncate, %function
ftruncate:
    mov x0, #0
    ret

.balign 8
.globl ftruncate64
.type ftruncate64, %function
ftruncate64:
    mov x0, #0
    ret

.balign 8
.globl sched_yield
.type sched_yield, %function
sched_yield:
    mov x0, #0
    ret

.balign 8
.globl sched_getaffinity
.type sched_getaffinity, %function
sched_getaffinity:
    mov x0, #0
    ret

.balign 8
.globl __cxa_atexit
.type __cxa_atexit, %function
__cxa_atexit:
    mov x0, #0
    ret

.balign 8
.globl atexit
.type atexit, %function
atexit:
    mov x0, #0
    ret

.balign 8
.globl __h_errno_location
.type __h_errno_location, %function
__h_errno_location:
    mov x0, #0
    ret

.balign 8
.globl wcslen
.type wcslen, %function
wcslen:
    mov x0, #0
    ret

.balign 8
.globl wcscpy
.type wcscpy, %function
wcscpy:
    mov x0, #0
    ret

.balign 8
.globl wcsncpy
.type wcsncpy, %function
wcsncpy:
    mov x0, #0
    ret

.balign 8
.globl mbstowcs
.type mbstowcs, %function
mbstowcs:
    mov x0, #0
    ret

.balign 8
.globl wcstombs
.type wcstombs, %function
wcstombs:
    mov x0, #0
    ret

.balign 8
.globl sem_init
.type sem_init, %function
sem_init:
    mov x0, #0
    ret

.balign 8
.globl sem_destroy
.type sem_destroy, %function
sem_destroy:
    mov x0, #0
    ret

.balign 8
.globl sem_wait
.type sem_wait, %function
sem_wait:
    mov x0, #0
    ret

.balign 8
.globl sem_post
.type sem_post, %function
sem_post:
    mov x0, #0
    ret

.balign 8
.globl getaddrinfo
.type getaddrinfo, %function
getaddrinfo:
    mov x0, #0
    ret

.balign 8
.globl freeaddrinfo
.type freeaddrinfo, %function
freeaddrinfo:
    mov x0, #0
    ret

.balign 8
.globl gethostname
.type gethostname, %function
gethostname:
    mov x0, #0
    ret

.balign 8
.globl gai_strerror
.type gai_strerror, %function
gai_strerror:
    mov x0, #0
    ret

.balign 8
.globl preadv64
.type preadv64, %function
preadv64:
    mov x0, #0
    ret

.balign 8
.globl pwritev64v2
.type pwritev64v2, %function
pwritev64v2:
    mov x0, #0
    ret

.balign 8
.globl system
.type system, %function
system:
    mov x0, #0
    ret

.balign 8
.globl fork
.type fork, %function
fork:
    mov x0, #0
    ret

.balign 8
.globl execve
.type execve, %function
execve:
    mov x0, #0
    ret

.balign 8
.globl waitpid
.type waitpid, %function
waitpid:
    mov x0, #0
    ret

.balign 8
.globl strpbrk
.type strpbrk, %function
strpbrk:
    mov x0, #0
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


# Additional symbols needed
.balign 8
.globl __isoc99_sscanf
.type __isoc99_sscanf, %function
__isoc99_sscanf:
    mov x0, #0
    ret

.balign 8
.globl strtoul
.type strtoul, %function
strtoul:
    mov x0, #0
    ret
