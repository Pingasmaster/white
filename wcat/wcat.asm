; -----------------------------------------------------------------------------
; wcat – minimalist GNU cat clone written in amd64 assembly.
;
; Supported GNU options: -n, -b, -s, -v, -E/-T and the composites -A/-e/-t,
; plus long options --number, --number-nonblank, --squeeze-blank, --show-ends,
; --show-tabs, --show-nonprinting, and --show-all.
; All other flags fall back to the same error message GNU cat would print.
; -----------------------------------------------------------------------------

; --- Linux syscall numbers we rely on ----------------------------------------
%define SYS_read        0              ; Linux x86-64 syscall number for read()
%define SYS_write       1              ; syscall number for write()
%define SYS_close       3              ; syscall number for close()
%define SYS_lseek       8              ; syscall number for lseek()
%define SYS_mmap        9              ; syscall number for mmap()
%define SYS_munmap      11             ; syscall number for munmap()
%define SYS_fstat       5              ; syscall number for fstat()
%define SYS_ftruncate   77             ; syscall number for ftruncate()
%define SYS_sendfile    40             ; syscall number for sendfile()
%define SYS_exit        60             ; syscall number for exit()
%define SYS_openat      257            ; syscall number for openat()
%define SYS_memfd_create 319           ; syscall number for memfd_create()
%define SYS_copy_file_range 326        ; syscall number for copy_file_range()
%define SYS_fadvise64   221            ; syscall number for posix_fadvise()
%define SYS_splice      275            ; syscall number for splice()
%define SYS_pipe2       293            ; syscall number for pipe2()

%define EINTR           4              ; errno for interrupted syscall
%define EAGAIN          11             ; errno for would-block / try again
%define EIO             5              ; errno for I/O error
%define EBADF           9              ; errno for bad file descriptor
%define ENOMEM          12             ; errno for out of memory
%define EINVAL          22             ; errno for invalid argument
%define ESPIPE          29             ; errno for illegal seek on pipe
%define ENOSYS          38             ; errno for function not implemented
%define EOPNOTSUPP      95             ; errno for operation not supported
%define EXDEV           18             ; errno for cross-device link
%define ENOENT          2              ; errno for missing file / path
%define EACCES          13             ; errno for permission denied
%define EPIPE           32             ; errno for broken pipe
%define ENOTDIR         20             ; errno for component not a directory
%define EISDIR          21             ; errno for path is a directory
%define ENAMETOOLONG    36             ; errno for pathname too long
%define ELOOP           40             ; errno for too many symlinks
%define ENFILE          23             ; errno for system-wide file table full
%define EMFILE          24             ; errno for process fd table full
%define EROFS           30             ; errno for read-only filesystem
%define EFBIG           27             ; errno for file too large
%define ENOSPC          28             ; errno for no space left on device

%define PROT_READ       1              ; mmap protection: read
%define MAP_SHARED      1              ; mmap mapping: shared
%define MAP_PRIVATE     2              ; mmap mapping: private

%define SEEK_SET        0              ; lseek: from start
%define SEEK_CUR        1              ; lseek: from current position
%define SEEK_END        2              ; lseek: from end

; --- Misc constants ----------------------------------------------------------
%define AT_FDCWD        -100          ; openat() “current working dir”
%define BUFFER_SIZE     262144        ; I/O buffer size (256 KiB chunk to cut syscalls)
%define SENDFILE_CHUNK  1048576       ; how much we ask kernel to move at once
%define CFR_CHUNK_MIN   262144        ; minimum chunk size for copy_file_range path (256 KiB)
%define CFR_CHUNK_MAX   1048576       ; maximum chunk size for copy_file_range path
%define SPLICE_CHUNK    1048576       ; chunk size for splice() operations
%define POSIX_FADV_SEQUENTIAL 2       ; fadvise: sequential access pattern
%define POSIX_FADV_DONTNEED    4      ; fadvise: pages can be dropped after use
%define SPLICE_F_MOVE   1             ; splice flag: move pages instead of copy
%define O_CLOEXEC       0x00080000    ; open flag: close-on-exec
%define STAT_MODE_OFFSET 24           ; offset of st_mode inside struct stat
%define STAT_SIZE_OFFSET 48           ; offset of st_size in struct stat
%define STAT_BLKSIZE_OFFSET 56        ; offset of st_blksize in struct stat
%define S_IFMT          0xF000        ; mask for file type bits
%define S_IFREG         0x8000        ; regular file bit pattern
%define S_IFCHR         0x2000        ; character device bit pattern
%define S_IFIFO         0x1000        ; FIFO / pipe bit pattern
%define S_IFSOCK        0xC000        ; socket bit pattern

; Bit-mask flags describing requested output decorations
%define OPT_NUMBER            1       ; -n: number all lines
%define OPT_SHOW_ENDS         2       ; -E: show $ at line ends
%define OPT_SHOW_TABS         4       ; -T: show tabs as ^I
%define OPT_NUMBER_NONBLANK   8       ; -b: number nonblank lines only
%define OPT_SQUEEZE_BLANK    16       ; -s: squeeze multiple blank lines
%define OPT_SHOW_NONPRINTING 32       ; -v: show nonprinting chars visibly

; --- Read-only data ----------------------------------------------------------
section .rodata                  ; read-only data section
err_prefix      db "cat: ",0                 ; common diagnostics prefix
err_open_sep    db ": ",0                    ; separator before strerror text
err_enoent      db "No such file or directory",0
err_eacces      db "Permission denied",0
err_eisdir      db "Is a directory",0
err_enotdir     db "Not a directory",0
err_eloop       db "Too many levels of symbolic links",0
err_enametoolong db "File name too long",0
err_emfile      db "Too many open files",0
err_enfile      db "Too many open files in system",0
err_erofs       db "Read-only file system",0
err_eio         db "Input/output error",0
err_enospc      db "No space left on device",0
err_einval      db "Invalid argument",0
err_ebadf       db "Bad file descriptor",0
err_efbig       db "File too large",0
err_enomem      db "Cannot allocate memory",0
err_unknown     db "Unknown error",0
err_write_prefix db "cat: write error: ",0
err_invalid_option_mid db ": invalid option -- '",0
err_unrecognized_option_mid db ": unrecognized option '",0
err_option_close db "'",10,0
err_try_prefix db "Try '",0
err_try_suffix db " --help' for more information.",10,0
err_option_arg_mid db ": option '",0
err_option_arg_dashes db "--",0
err_option_arg_tail db "' doesn't allow an argument",10,0
newline         db 10,0                     ; newline string
help_keyword    db "help",0                 ; "--help" keyword
version_keyword db "version",0              ; "--version" keyword
long_number     db "number",0
long_number_nonblank db "number-nonblank",0
long_squeeze_blank db "squeeze-blank",0
long_show_ends  db "show-ends",0
long_show_tabs  db "show-tabs",0
long_show_nonprinting db "show-nonprinting",0
long_show_all   db "show-all",0
help_text       db "Usage: wcat [OPTION]... [FILE]...",10             ; help text header
                db "Concatenate FILEs, or standard input, to standard output.",10,10
                db "  -b        number nonempty output lines",10
                db "  -n        number all output lines",10
                db "  -s        squeeze multiple blank lines",10
                db "  -E        show $ at end of each line",10
                db "  -T        show TAB characters as ^I",10
                db "  -v        use ^ and M- notation, -A/-e/-t behave like GNU cat",10
                db "  -u        (ignored for compatibility)",10
                db "      --help     display this help and exit",10
                db "      --version  output version information and exit",10,0
version_text    db "wcat 0.1  (November 2025)",10,0  ; version string
stdin_label     db "-",0                            ; label used for stdin
memfd_name      db "wcat-fast",0                    ; name for memfd_create()
align 16                                           ; align following data to 16 bytes
newline_vec     times 16 db 10                     ; 16 newlines (vector-friendly)
align 16                                           ; align to 16 bytes
tab_vec         times 16 db 9                      ; 16 tabs (vector-friendly)
align 16                                           ; align to 16 bytes
digit_pairs:                                       ; table of decimal digit pairs 00..99
%assign __dp 0                                     ; macro counter initialization
%rep 100                                           ; repeat 100 times
    db '0' + (__dp / 10), '0' + (__dp % 10)        ; two ASCII digits for value __dp
%assign __dp __dp + 1                              ; increment macro counter
%endrep                                            ; end macro repetition

; --- Mutable state -----------------------------------------------------------
section .bss                        ; zero-initialized data
alignb 16                           ; 16-byte alignment
buffer       resb BUFFER_SIZE         ; raw data from read()
outbuf       resb BUFFER_SIZE         ; buffered stdout writer
outpos       resq 1                   ; current byte count in outbuf
errflag      resb 1                   ; latched open/IO error indicator
opt_flags    resb 1                   ; combination of OPT_* bits
options_done resb 1                   ; set once “--” or first operand seen
files_seen   resb 1                   ; track whether we got any file args
line_start   resb 1                   ; true iff we’re at beginning of a line
line_blank   resb 1                   ; true while current line has no bytes yet
prev_blank   resb 1                   ; remembers whether previous line was blank
alignb 8                             ; align next qword
line_no      resq 1                   ; next line number for -n
numbuf       resb 64                  ; scratch buffer for decimal rendering
tmp_char     resb 1                   ; preserves AL across buffer flushes
opt_char_buf resb 2                   ; single-char buffer for option errors
prog_name   resq 1                   ; argv[0] pointer for option diagnostics
line_ascii   resb 7                   ; cached "######" string with trailing tab
alignb 16                            ; 16-byte alignment
stat_in      resb 144                 ; struct stat scratch for fast paths (input)
stat_out     resb 144                 ; struct stat scratch for fast paths (output)

; --- Text segment ------------------------------------------------------------
section .text                        ; code segment
global _start                        ; program entry point

_start:
    ; argc/argv arrive on the initial stack: [rsp] = argc, argv starts right
    ; after it.  Keep them in callee-saved registers because we iterate often.
    mov r12, [rsp]              ; r12 = argc
    lea r13, [rsp + 8]          ; r13 = &argv[0]
    mov rax, [r13]              ; argv[0]
    mov [rel prog_name], rax    ; stash program name pointer

    ; Default runtime state mirrors GNU cat startup.
    mov byte [rel errflag], 0        ; clear error flag
    mov byte [rel opt_flags], 0      ; clear options bitmask
    mov byte [rel options_done], 0   ; not done parsing options yet
    mov byte [rel files_seen], 0     ; no file operands seen yet
    mov byte [rel line_start], 1     ; start at beginning of a line
    mov byte [rel line_blank], 1     ; current line considered blank initially
    mov byte [rel prev_blank], 0     ; previous line not blank yet
    mov qword [rel line_no], 1       ; start numbering at line 1
    mov dword [rel line_ascii], 0x20202020 ; "    "
    mov word  [rel line_ascii + 4], 0x3120  ; " 1"
    mov byte  [rel line_ascii + 6], 9       ; trailing tab
    mov qword [rel outpos], 0        ; output buffer is empty

    ; Fast path: “wcat” with no extra args just copies stdin.
    cmp r12, 1                   ; argc == 1 ?
    jg  .process_args            ; if >1, go parse args

    xor edi, edi                ; edi = 0 (stdin fd)
    lea rsi, [rel stdin_label]  ; rsi = "-" label for diagnostics
    call copy_fd                ; copy stdin to stdout
    jmp .finish                 ; then finish

.process_args:
    ; Pass 1: parse options (GNU-style permutation; operands do not stop parsing).
    mov rbx, 1                  ; argv index
    mov byte [rel options_done], 0
.pass1_loop:
    cmp rbx, r12
    jge .pass1_done
    mov rsi, [r13 + rbx*8]      ; rsi = argv[rbx]
    cmp byte [rel options_done], 0
    jne .pass1_done             ; stop parsing after "--"
    mov al, [rsi]
    cmp al, '-'
    jne .pass1_next             ; non-option operand
    cmp byte [rsi+1], '-'
    jne .pass1_short
    cmp byte [rsi+2], 0
    je  .pass1_end_options
    mov rdi, rsi
    call parse_long_option
    jmp .pass1_next
.pass1_short:
    cmp byte [rsi+1], 0
    je  .pass1_next             ; "-" operand
    mov rdi, rsi
    call parse_option_string
    jmp .pass1_next
.pass1_end_options:
    mov byte [rel options_done], 1
    jmp .pass1_done
.pass1_next:
    inc rbx
    jmp .pass1_loop
.pass1_done:
    ; Pass 2: process operands in original order.
    mov rbx, 1
    mov byte [rel options_done], 0
    mov byte [rel files_seen], 0
.pass2_loop:
    cmp rbx, r12
    jge .post_args
    mov rsi, [r13 + rbx*8]      ; rsi = argv[rbx]
    cmp byte [rel options_done], 0
    jne .pass2_operand
    mov al, [rsi]
    cmp al, '-'
    jne .pass2_operand
    cmp byte [rsi+1], '-'
    jne .pass2_short_or_dash
    cmp byte [rsi+2], 0
    je  .pass2_end_options
    jmp .pass2_next             ; long option, already parsed
.pass2_short_or_dash:
    cmp byte [rsi+1], 0
    je  .pass2_operand          ; "-" operand
    jmp .pass2_next             ; short option, already parsed
.pass2_end_options:
    mov byte [rel options_done], 1
    jmp .pass2_next
.pass2_operand:
    mov byte [rel files_seen], 1
    cmp byte [rsi], '-'
    jne .proc_file
    cmp byte [rsi+1], 0
    je  .proc_stdin
.proc_file:
    mov eax, SYS_openat             ; openat syscall
    mov edi, AT_FDCWD               ; dirfd = current working directory
    ; rsi already points to the pathname
    xor edx, edx                    ; O_RDONLY (flags=0)
    xor r10d, r10d                  ; mode = 0 (unused)
    syscall                         ; openat(AT_FDCWD, path, 0, 0)
    cmp rax, 0
    jl  .open_failed_operands       ; error -> report

    mov r14, rax                    ; save fd
    mov edi, eax                    ; edi = fd
    ; rsi already operand pointer for diagnostics
    call copy_fd                    ; copy file

.close_retry_operands:
    mov eax, SYS_close
    mov edi, r14d
    syscall
    cmp eax, 0
    jge .pass2_next
    cmp eax, -EINTR
    je  .close_retry_operands
    cmp eax, -EAGAIN
    je  .close_retry_operands
    neg eax
    mov edx, eax
    call fatal_write_error

.open_failed_operands:
    neg rax
    mov edx, eax
    call report_open_error
    jmp .pass2_next

.proc_stdin:
    xor edi, edi                ; fd 0
    ; rsi already "-"
    call copy_fd

.pass2_next:
    inc rbx
    jmp .pass2_loop

.post_args:
    cmp byte [rel files_seen], 0 ; did we see any file operands?
    jne .finish                 ; yes -> done

    ; No file operands?  GNU cat falls back to stdin.
    xor edi, edi                ; fd 0
    lea rsi, [rel stdin_label]  ; label "-"
    call copy_fd                ; copy stdin
    jmp .finish                 ; then finish

.finish:
    call flush_outbuf           ; ensure buffered output is written
    movzx edi, byte [rel errflag] ; edi = exit status (0 or 1)
    call exit_with_code         ; exit program

; ----------------------------------------------------------------------------- 
; parse_option_string
;   Input : rdi -> string that begins with '-'
;   Effect: updates opt_flags or exits on unsupported switches.
; -----------------------------------------------------------------------------
parse_option_string:
    push rbx                    ; save rbx (caller-saved)
    mov rdx, rdi                ; keep original pointer for diagnostics
    lea rsi, [rdi + 1]          ; rsi = pointer past leading '-'
.opt_loop:
    mov al, byte [rsi]          ; load current option character
    cmp al, 0                   ; end of string?
    je  .opt_done               ; yes -> done

    cmp al, 'n'                 ; "-n"?
    je  .set_number
    cmp al, 'b'                 ; "-b"?
    je  .set_number_nonblank
    cmp al, 's'                 ; "-s"?
    je  .set_squeeze
    cmp al, 'v'                 ; "-v"?
    je  .set_show_nonprint
    cmp al, 'u'                 ; "-u"?
    je  .ignore_unbuffered
    cmp al, 'A'                 ; "-A"?
    je  .set_show_all
    cmp al, 'e'                 ; "-e"?
    je  .set_show_nonprint_ends
    cmp al, 't'                 ; "-t"?
    je  .set_show_nonprint_tabs
    cmp al, 'E'                 ; "-E"?
    je  .set_show_ends
    cmp al, 'T'                 ; "-T"?
    je  .set_show_tabs

    mov dil, al                 ; offending option character
    call report_bad_short_option ; unknown option -> error and exit
    jmp .opt_done               ; unreachable, but keeps flow clear

.set_number:
    mov bl, [rel opt_flags]
    test bl, OPT_NUMBER_NONBLANK ; if -b already set, keep it overriding -n
    jnz .skip_set_number
    or  bl, OPT_NUMBER           ; enable numbering all lines
    mov [rel opt_flags], bl
.skip_set_number:
    inc rsi                      ; move to next option char
    jmp .opt_loop                ; continue parsing

.set_number_nonblank:
    mov bl, [rel opt_flags]      ; load current flags
    or  bl, OPT_NUMBER_NONBLANK  ; set nonblank-numbering flag
    and bl, ~OPT_NUMBER          ; clear plain numbering flag (GNU semantics)
    mov [rel opt_flags], bl      ; store updated flags
    inc rsi                      ; next char
    jmp .opt_loop                ; loop

.set_squeeze:
    or  byte [rel opt_flags], OPT_SQUEEZE_BLANK ; set squeeze flag
    inc rsi                      ; next char
    jmp .opt_loop                ; loop

.set_show_nonprint:
    or  byte [rel opt_flags], OPT_SHOW_NONPRINTING ; show nonprinting chars
    inc rsi                      ; next char
    jmp .opt_loop                ; loop

.set_show_all:
    or  byte [rel opt_flags], OPT_SHOW_NONPRINTING | OPT_SHOW_ENDS | OPT_SHOW_TABS ; -A behaviour
    inc rsi                      ; next char
    jmp .opt_loop                ; loop

.set_show_nonprint_ends:
    or  byte [rel opt_flags], OPT_SHOW_NONPRINTING | OPT_SHOW_ENDS ; -e behaviour
    inc rsi                      ; next char
    jmp .opt_loop                ; loop

.set_show_nonprint_tabs:
    or  byte [rel opt_flags], OPT_SHOW_NONPRINTING | OPT_SHOW_TABS ; -t behaviour
    inc rsi                      ; next char
    jmp .opt_loop                ; loop

.ignore_unbuffered:
    ; GNU cat accepts -u but ignores it; do the same.
    inc rsi                      ; skip this char
    jmp .opt_loop                ; continue

.set_show_ends:
    or  byte [rel opt_flags], OPT_SHOW_ENDS ; show '$' at line ends
    inc rsi                      ; next char
    jmp .opt_loop                ; loop

.set_show_tabs:
    or  byte [rel opt_flags], OPT_SHOW_TABS ; show tabs as ^I
    inc rsi                      ; next char
    jmp .opt_loop                ; loop

.opt_done:
    pop rbx                      ; restore rbx
    ret                          ; return

; -----------------------------------------------------------------------------
; parse_long_option
;   Input : rdi -> string that begins with "--"
;   Effect: updates opt_flags or exits on unsupported long switches.
; -----------------------------------------------------------------------------
parse_long_option:
    push rbx                     ; save rbx
    push r12                     ; save r12
    mov r12, rdi                 ; r12 = full argument pointer
    lea r14, [r12 + 2]           ; r14 = pointer after "--"
    xor r11d, r11d               ; r11 = 0 means no '='
    mov rdi, r14
.plo_eq_scan:
    mov al, [rdi]
    cmp al, 0
    je  .plo_eq_done
    cmp al, '='
    je  .plo_eq_found
    inc rdi
    jmp .plo_eq_scan
.plo_eq_found:
    mov r11, rdi                 ; r11 = pointer to '='
.plo_eq_done:

    mov rdi, r14                 ; option name pointer
    mov rsi, help_keyword        ; "help"
    call str_compare
    test eax, eax
    jne .check_version
    test r11, r11
    jne .bad_long_arg
    jmp print_help_and_exit

.check_version:
    mov rdi, r14
    mov rsi, version_keyword     ; "version"
    call str_compare
    test eax, eax
    jne .check_number
    test r11, r11
    jne .bad_long_arg
    jmp print_version_and_exit

.check_number:
    mov rdi, r14
    mov rsi, long_number
    call str_compare
    test eax, eax
    jne .check_number_nonblank
    test r11, r11
    jne .bad_long_arg
    mov r10b, [rel opt_flags]
    test r10b, OPT_NUMBER_NONBLANK
    jnz .return
    or  r10b, OPT_NUMBER
    mov [rel opt_flags], r10b
    jmp .return

.check_number_nonblank:
    mov rdi, r14
    mov rsi, long_number_nonblank
    call str_compare
    test eax, eax
    jne .check_squeeze
    test r11, r11
    jne .bad_long_arg
    mov r10b, [rel opt_flags]
    or  r10b, OPT_NUMBER_NONBLANK
    and r10b, ~OPT_NUMBER
    mov [rel opt_flags], r10b
    jmp .return

.check_squeeze:
    mov rdi, r14
    mov rsi, long_squeeze_blank
    call str_compare
    test eax, eax
    jne .check_show_ends
    test r11, r11
    jne .bad_long_arg
    or  byte [rel opt_flags], OPT_SQUEEZE_BLANK
    jmp .return

.check_show_ends:
    mov rdi, r14
    mov rsi, long_show_ends
    call str_compare
    test eax, eax
    jne .check_show_tabs
    test r11, r11
    jne .bad_long_arg
    or  byte [rel opt_flags], OPT_SHOW_ENDS
    jmp .return

.check_show_tabs:
    mov rdi, r14
    mov rsi, long_show_tabs
    call str_compare
    test eax, eax
    jne .check_show_nonprinting
    test r11, r11
    jne .bad_long_arg
    or  byte [rel opt_flags], OPT_SHOW_TABS
    jmp .return

.check_show_nonprinting:
    mov rdi, r14
    mov rsi, long_show_nonprinting
    call str_compare
    test eax, eax
    jne .check_show_all
    test r11, r11
    jne .bad_long_arg
    or  byte [rel opt_flags], OPT_SHOW_NONPRINTING
    jmp .return

.check_show_all:
    mov rdi, r14
    mov rsi, long_show_all
    call str_compare
    test eax, eax
    jne .unknown
    test r11, r11
    jne .bad_long_arg
    or  byte [rel opt_flags], OPT_SHOW_NONPRINTING | OPT_SHOW_ENDS | OPT_SHOW_TABS
    jmp .return

.unknown:
    mov rsi, r12                 ; rsi = full option string
    call report_bad_long_option

.return:
    pop r12                      ; restore r12
    pop rbx                      ; restore rbx
    ret

.bad_long_arg:
    mov rsi, r14                 ; rsi = option name (after "--")
    call report_long_option_argument

; -----------------------------------------------------------------------------
; copy_fd
;   Input : rdi = file descriptor
;   Effect: streams fd -> stdout using BUFFER_SIZE chunks while feeding
;           process_buffer for decoration / numbering.
; -----------------------------------------------------------------------------
copy_fd:
    push rbx                     ; save rbx
    push r15                     ; save r15
    mov rbx, rdi                 ; rbx = source fd
    mov r15, rsi                 ; r15 = label pointer (path/ "-" ) for errors
    mov al, [rel opt_flags]      ; al = option flags
    test al, al                  ; any flags set?
    jne .decorated_path          ; yes -> decorated path
    call copy_fd_plain           ; zero-overhead path when no transforms needed
    jmp .leave                   ; done

.decorated_path:
.decorated_full_path:            ; (label alias) decorated path entry
.decorated_fast_try:
    mov eax, SYS_fstat           ; hint sequential reads for fallback path
    mov edi, ebx                 ; fd = source
    lea rsi, [rel stat_in]       ; &stat_in
    syscall
    cmp rax, 0                   ; ignore failures
    jl  .decorated_read_loop
    mov eax, [rel stat_in + STAT_MODE_OFFSET]
    and eax, S_IFMT
    cmp eax, S_IFREG             ; only hint regular files
    jne .decorated_read_loop
    mov eax, SYS_fadvise64       ; posix_fadvise(fd, 0, 0, SEQUENTIAL)
    mov edi, ebx
    xor rsi, rsi
    xor rdx, rdx
    xor r10d, r10d
    mov r10d, POSIX_FADV_SEQUENTIAL
    syscall
    jmp .decorated_read_loop     ; otherwise stream via read()
.decorated_read_loop:
    mov eax, SYS_read            ; read() syscall
    mov edi, ebx                 ; edi = source fd
    lea rsi, [rel buffer]        ; rsi = buffer
    mov edx, BUFFER_SIZE         ; edx = buffer size
    syscall                      ; read(fd, buffer, BUFFER_SIZE)
    cmp rax, 0                   ; rax <= 0?
    je  .decorated_done          ; 0 -> EOF, done
    jl  .decorated_read_check    ; <0 -> error, handle

    mov rcx, rax                 ; rcx = bytes read
    lea rsi, [rel buffer]        ; rsi = buffer start
    test byte [rel opt_flags], OPT_SHOW_NONPRINTING
    je  .decorated_process
    mov rdx, rcx                 ; save length
    push rcx
    push rsi
    call chunk_all_printable     ; returns eax=1 if safe to pass through
    pop rsi
    pop rcx
    test eax, eax
    je  .decorated_process
    mov al, [rel opt_flags]      ; al = current flags (includes OPT_SHOW_NONPRINTING)
    mov r8b, al                  ; r8b = original flags
    mov r9b, al
    and r9b, ~OPT_SHOW_NONPRINTING ; strip -v for fast chunk
    test r9b, r9b
    jne .decorated_printable_decorate
    mov rdx, rcx                 ; only -v set -> raw write is safe
    lea rsi, [rel buffer]
    call write_direct_stdout
    jmp .decorated_read_loop
.decorated_printable_decorate:
    mov [rel opt_flags], r9b     ; clear -v bit temporarily
    push r8                      ; preserve original flags across call
    mov rcx, rdx                 ; rcx = length
    lea rsi, [rel buffer]
    call process_buffer          ; use faster non- -v paths
    pop r8
    mov [rel opt_flags], r8b     ; restore flags
    jmp .decorated_read_loop

.decorated_process:
    call process_buffer          ; decorate and emit
    jmp .decorated_read_loop     ; continue reading

.decorated_done:
    call flush_outbuf            ; flush any pending output
    jmp .leave                   ; exit

.decorated_read_check:
    cmp rax, -EINTR              ; interrupted?
    je  .decorated_read_loop     ; retry
    cmp rax, -EAGAIN             ; would block?
    je  .decorated_read_loop     ; retry
    jmp .decorated_io_error      ; other error

.decorated_io_error:
    neg rax                      ; rax = errno
    mov edx, eax                 ; edx = errno
    call flush_outbuf            ; flush whatever we have
    mov rsi, r15                 ; rsi = label for diagnostics
    call report_read_error       ; report error for this file

.leave:
    pop r15                      ; restore r15
    pop rbx                      ; restore rbx
    ret                          ; return

; -----------------------------------------------------------------------------
; copy_fd_plain
;   Fast path used when there are zero decoration flags.  Streams bytes using a
;   large buffer and lets the kernel take over via sendfile() whenever regular
;   files are involved.
;   Inputs: rbx = source fd, r15 = label for diagnostics.
; -----------------------------------------------------------------------------
copy_fd_plain:
    push r12                     ; save r12
    push r13                     ; save r13
    push r14                     ; save r14
    lea r12, [rel buffer]        ; r12 = address of buffer
    call flush_outbuf            ; ensure output buffer is empty
    call maybe_sendfile_plain    ; try sendfile fast path
    test eax, eax                ; eax == 0 => done
    jne .try_splice_plain        ; if 1, try splice
    jmp .plain_done              ; success via sendfile

.try_splice_plain:
    call maybe_splice_plain      ; try splice fast path
    test eax, eax                ; eax == 0 => done
    jne .plain_stream            ; if 1, fall back to read/write
    jmp .plain_done              ; success via splice

.plain_stream:
    xor r9, r9                   ; r9 = bytes processed for DONTNEED hints
    xor r11d, r11d               ; r11b = 0 -> unknown / non-regular
    mov eax, SYS_fstat           ; fstat input fd
    mov edi, ebx                 ; edi = source fd
    lea rsi, [rel stat_in]       ; rsi = &stat_in
    syscall
    cmp rax, 0                   ; error?
    jl  .plain_read_loop         ; ignore error and just stream
    mov eax, [rel stat_in + STAT_MODE_OFFSET] ; eax = st_mode
    and eax, S_IFMT              ; mask file type bits
    cmp eax, S_IFREG             ; is regular file?
    jne .plain_read_loop         ; if not, go to read loop
    mov r11b, 1                  ; mark input as regular
    mov eax, SYS_fadvise64       ; posix_fadvise
    mov edi, ebx                 ; fd
    xor rsi, rsi                 ; offset = 0
    xor rdx, rdx                 ; len = 0 (entire file)
    xor r10d, r10d               ; clear r10d first
    mov r10d, POSIX_FADV_SEQUENTIAL ; hint sequential access
    syscall
    jne .plain_read_loop         ; ignore error, go to streaming
    mov r11b, 1                  ; keep regular flag set
    mov eax, SYS_fadvise64       ; (duplicated, but harmless)
    mov edi, ebx                 ; fd
    xor rsi, rsi                 ; offset 0
    xor rdx, rdx                 ; len 0
    xor r10d, r10d               ; clear r10d
    mov r10d, POSIX_FADV_SEQUENTIAL ; hint sequential
    syscall

.plain_read_loop:
    mov eax, SYS_read            ; read() syscall
    mov edi, ebx                 ; source fd
    mov rsi, r12                 ; buffer address
    mov edx, BUFFER_SIZE         ; size
    syscall
    cmp rax, 0                   ; EOF or error?
    je  .plain_done              ; 0 -> EOF
    jl  .plain_read_check        ; <0 -> error

    mov r14, rax                 ; r14 = bytes read
    mov r13, r12                 ; r13 = current output pointer into buffer
.plain_write_loop:
    mov rdx, r14                 ; rdx = remaining bytes to write
    mov eax, SYS_write           ; write() syscall
    mov edi, 1                   ; stdout fd
    mov rsi, r13                 ; buffer pointer
    syscall
    cmp rax, 0                   ; error?
    jl  .plain_write_check       ; handle error
    je  .plain_write_loop        ; 0 bytes? try again
    cmp rax, rdx                 ; all bytes written?
    je  .plain_chunk_account     ; yes -> update hints
    sub r14, rax                 ; reduce remaining
    add r13, rax                 ; move pointer
    jmp .plain_write_loop        ; continue writing

.plain_chunk_account:
    test r11b, r11b              ; was input regular?
    je  .plain_advise_skip       ; if not, skip DONTNEED
    mov eax, SYS_fadvise64       ; posix_fadvise
    mov edi, ebx                 ; fd
    mov rsi, r9                  ; offset where chunk started
    mov rdx, r14                 ; length = bytes written
    mov r10d, POSIX_FADV_DONTNEED ; pages can be dropped
    syscall
.plain_advise_skip:
    add r9, r14                  ; advance processed bytes
    jmp .plain_read_loop         ; read next chunk

.plain_read_check:
    cmp rax, -EINTR              ; interrupted?
    je  .plain_read_loop         ; retry
    cmp rax, -EAGAIN             ; would block?
    je  .plain_read_loop         ; retry
    neg rax                      ; rax = errno
    mov edx, eax                 ; edx = errno for reporter
    call flush_outbuf            ; flush outbuf before error
    mov rsi, r15                 ; rsi = label for error
    call report_read_error       ; print read error
    jmp .plain_done              ; exit path

.plain_write_check:
    cmp rax, -EINTR              ; interrupted write?
    je  .plain_write_loop        ; retry
    cmp rax, -EAGAIN             ; would block?
    je  .plain_write_loop        ; retry
    cmp rax, -EPIPE              ; broken pipe?
    je  .plain_sigpipe
    neg rax
    mov edx, eax
    call fatal_write_error       ; other errors fatal
.plain_sigpipe:
    call handle_sigpipe

.plain_done:
    pop r14                      ; restore r14
    pop r13                      ; restore r13
    pop r12                      ; restore r12
    ret                          ; return

; -----------------------------------------------------------------------------
; decorated_try_mmap
;   When input is a regular file, mmap the whole thing and run process_buffer
;   in one shot to skip per-chunk read() overhead. Returns 0 on success (all
;   bytes processed) or 1 to let callers fall back to the usual streaming path.
; -----------------------------------------------------------------------------
decorated_try_mmap:
    push r12
    push r13
    mov r12d, edi                ; r12d = source fd
    mov eax, SYS_fstat           ; fstat(source)
    mov edi, r12d
    lea rsi, [rel stat_in]
    syscall
    cmp rax, 0
    jl  .dtm_fallback            ; fstat failed
    mov eax, [rel stat_in + STAT_MODE_OFFSET]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .dtm_fallback            ; only mmap regular files
    mov r13, [rel stat_in + STAT_SIZE_OFFSET] ; r13 = file size
    test r13, r13
    je  .dtm_success             ; empty file -> nothing to do
    mov eax, SYS_mmap
    xor edi, edi                 ; addr = NULL
    mov rsi, r13                 ; length = file size
    mov edx, PROT_READ
    mov r10d, MAP_PRIVATE        ; private, read-only mapping
    mov r8d, r12d                ; fd
    xor r9d, r9d                 ; offset = 0
    syscall
    cmp rax, 0
    jl  .dtm_fallback            ; mmap failed
    mov r12, rax                 ; r12 = mapped base
    mov rcx, r13                 ; rcx = length
    mov rsi, r12                 ; rsi = base pointer
    call process_buffer
    mov eax, SYS_munmap          ; unmap mapping
    mov rdi, r12
    mov rsi, r13
    syscall
    xor eax, eax                 ; signal success
    jmp .dtm_done

.dtm_success:
    xor eax, eax                 ; nothing to process but still success
    jmp .dtm_done

.dtm_fallback:
    mov eax, 1                   ; ask caller to fall back

.dtm_done:
    pop r13
    pop r12
    ret

; -----------------------------------------------------------------------------
; decorated_zero_copy
;   Tries to service decorated workloads without read() loops by chunking the
;   stream through copy_file_range + memfd + mmap. Input: rdi = source fd,
;   rsi = label used for diagnostics. Returns 0 when all data already went
;   through process_buffer, 1 to fall back to the classic read loop.
; -----------------------------------------------------------------------------
decorated_zero_copy:
    push rbx                     ; save rbx
    push r12                     ; save r12
    push r13                     ; save r13
    push r14                     ; save r14
    push r15                     ; save r15
    mov r12d, edi                ; r12d = source fd
    mov r13, rsi                 ; r13 = label pointer
    mov edi, r12d                ; edi = source fd (arg to helper)
    mov rsi, r13                 ; rsi = label
    call decorated_try_cfr_chunks ; attempt copy_file_range+memfd path
    test eax, eax                ; eax == 0 => success
    je  .dz_success              ; all data processed
    mov eax, 1                   ; on failure, request fallback
    jmp .dz_done                 ; return

.dz_success:
    xor eax, eax                 ; eax = 0 (success)
.dz_done:
    pop r15                      ; restore r15
    pop r14                      ; restore r14
    pop r13                      ; restore r13
    pop r12                      ; restore r12
    pop rbx                      ; restore rbx
    ret                          ; return

; decorated_try_cfr_chunks
;   Uses copy_file_range into a reusable memfd chunk, mmap'ing it per iteration so
;   decorated output can stay zero-copy-friendly even for pipes/FIFOs.
;   rdi = source fd, rsi = label pointer.
decorated_try_cfr_chunks:
    push rbp                     ; save rbp (used as byte counter)
    push rbx                     ; save rbx
    push r12                     ; save r12
    push r13                     ; save r13
    push r14                     ; save r14
    push r15                     ; save r15
    mov r12d, edi                ; r12d = source fd
    mov r13, rsi                 ; r13 = label
    xor rbp, rbp                 ; rbp = 0 (bytes processed for DONTNEED)
    xor r11d, r11d               ; r11b = 0 (assume non-regular input)
    mov eax, SYS_fstat           ; fstat(source)
    mov edi, r12d                ; fd
    lea rsi, [rel stat_in]       ; &stat_in
    syscall
    cmp rax, 0                   ; error?
    jl  .dtcc_fallback           ; on error, fallback
    mov eax, [rel stat_in + STAT_MODE_OFFSET] ; st_mode
    and eax, S_IFMT              ; mask file type
    cmp eax, S_IFREG             ; regular file?
    jne .dtcc_calc_chunk         ; if not, skip DONTNEED hints
    mov r11b, 1                  ; mark as regular input
.dtcc_calc_chunk:
    mov rdx, [rel stat_in + STAT_BLKSIZE_OFFSET] ; rdx = st_blksize
    mov r15, rdx                 ; r15 = suggested chunk size
    cmp r15, CFR_CHUNK_MIN       ; too small?
    jge .dtcc_chunk_hi           ; if >= min, OK
    mov r15, CFR_CHUNK_MIN       ; else clamp to minimum
.dtcc_chunk_hi:
    cmp r15, CFR_CHUNK_MAX       ; too large?
    jle .dtcc_chunk_ready        ; if <= max, OK
    mov r15, CFR_CHUNK_MAX       ; else clamp to max
.dtcc_chunk_ready:
    mov eax, SYS_memfd_create    ; create anonymous in-memory fd
    lea rdi, [rel memfd_name]    ; name "wcat-fast"
    xor esi, esi                 ; flags = 0
    syscall
    cmp rax, 0                   ; error?
    jl  .dtcc_fallback           ; cannot create memfd -> fallback
    mov r14d, eax                ; r14d = memfd
    mov eax, SYS_ftruncate       ; resize memfd to chunk size
    mov edi, r14d                ; memfd
    mov rsi, r15                 ; new size
    syscall
    cmp rax, 0                   ; error?
    jl  .dtcc_close_fail         ; on failure, close and fallback
    mov eax, SYS_mmap            ; mmap memfd read-only
    xor edi, edi                 ; addr = NULL (kernel chooses)
    mov rsi, r15                 ; length = chunk size
    mov edx, PROT_READ           ; PROT_READ
    mov r10d, MAP_SHARED         ; shared mapping
    mov r8d, r14d                ; fd = memfd
    xor r9d, r9d                 ; offset = 0
    syscall
    cmp rax, 0                   ; error?
    jl  .dtcc_close_fail         ; close and fallback
    mov rbx, rax                 ; rbx = mapped base address
    test r11b, r11b              ; input regular?
    je  .dtcc_copy_loop          ; if not, skip SEQUENTIAL hint
    mov eax, SYS_fadvise64       ; posix_fadvise
    mov edi, r12d                ; source fd
    xor rsi, rsi                 ; offset 0
    xor rdx, rdx                 ; len 0 (whole file)
    xor r10d, r10d               ; clear
    mov r10d, POSIX_FADV_SEQUENTIAL ; hint sequential
    syscall

.dtcc_copy_loop:
    sub rsp, 8                   ; allocate space for offset arg (unused)
    mov qword [rsp], 0           ; initialize offset pointer to 0
    mov eax, SYS_copy_file_range ; copy_file_range syscall
    mov edi, r12d                ; fd_in
    xor esi, esi                 ; off_in = NULL (use current)
    mov edx, r14d                ; fd_out = memfd
    lea r10, [rsp]               ; off_out pointer (ignored by kernel)
    mov r8, r15                  ; len = chunk size
    xor r9d, r9d                 ; flags = 0
    syscall
    add rsp, 8                   ; pop temporary space
    cmp rax, 0                   ; 0 => EOF
    je  .dtcc_success            ; done successfully
    jl  .dtcc_cfr_error          ; negative => error
    mov rcx, rax                 ; rcx = bytes copied
    mov rsi, rbx                 ; rsi = mapped memfd base
    sub rsp, 16                  ; reserve space (len + saved flags)
    mov [rsp], rcx               ; stash chunk length for DONTNEED/offsets
    test byte [rel opt_flags], OPT_SHOW_NONPRINTING
    je  .dtcc_process_chunk      ; no -v -> straight to processor

    push rcx
    push rsi
    call chunk_all_printable     ; check if chunk is fully printable
    pop rsi
    pop rcx
    test eax, eax
    je  .dtcc_process_chunk      ; not all printable -> normal path

    mov al, [rel opt_flags]      ; al = current flags
    mov r9b, al                  ; r9b = working flags
    and r9b, ~OPT_SHOW_NONPRINTING ; clear -v to reuse faster decorators
    mov [rsp + 8], al            ; save original flags
    test r9b, r9b
    jne .dtcc_printable_decorate
    mov rdx, rcx                 ; only -v set -> write chunk directly
    call write_direct_stdout
    jmp .dtcc_after_chunk_pop

.dtcc_printable_decorate:
    mov [rel opt_flags], r9b
    call process_buffer
    mov al, byte [rsp + 8]       ; restore original flags
    mov [rel opt_flags], al
    jmp .dtcc_after_chunk_pop

.dtcc_process_chunk:
    call process_buffer          ; decorate/emit this chunk

.dtcc_after_chunk_pop:
    mov r8, [rsp]                ; r8 = chunk length
    add rsp, 16                  ; release locals
    test r11b, r11b              ; regular input?
    je  .dtcc_after_chunk        ; if not, skip DONTNEED
    mov eax, SYS_fadvise64       ; posix_fadvise
    mov edi, r12d                ; source fd
    mov rsi, rbp                 ; offset of this chunk in file
    mov rdx, r8                  ; length = bytes copied
    mov r10d, POSIX_FADV_DONTNEED ; release pages after use
    syscall
    add rbp, r8                  ; track processed bytes
.dtcc_after_chunk:
    jmp .dtcc_copy_loop          ; copy next chunk

.dtcc_cfr_error:
    cmp rax, -EINTR              ; interrupted?
    je  .dtcc_copy_loop          ; retry
    cmp rax, -EAGAIN             ; would block?
    je  .dtcc_copy_loop          ; retry
    cmp rax, -EOPNOTSUPP         ; operation not supported?
    je  .dtcc_cleanup_fallback   ; fallback path
    cmp rax, -ENOSYS             ; syscall not implemented?
    je  .dtcc_cleanup_fallback   ; fallback
    cmp rax, -EINVAL             ; invalid args?
    je  .dtcc_cleanup_fallback   ; fallback
    cmp rax, -EXDEV              ; cross-device?
    je  .dtcc_cleanup_fallback   ; fallback
    cmp rax, -EBADF              ; bad fd?
    je  .dtcc_cleanup_fallback   ; fallback
    cmp rax, -ESPIPE             ; not seekable?
    je  .dtcc_cleanup_fallback   ; fallback
    neg rax                      ; errno -> positive
    mov edx, eax                 ; save errno
    call flush_outbuf            ; flush before error
    mov rsi, r13                 ; rsi = label
    call report_read_error       ; report read error
    xor eax, eax                 ; consider handled (no fallback)
    jmp .dtcc_cleanup            ; cleanup and return

.dtcc_success:
    xor eax, eax                 ; eax = 0 (success)
    jmp .dtcc_cleanup            ; clean up resources

.dtcc_cleanup_fallback:
    mov eax, 1                   ; signal caller to fallback

.dtcc_cleanup:
    mov r10d, eax                ; save return code in r10d
    mov eax, SYS_munmap          ; unmap memfd mapping
    mov rdi, rbx                 ; address
    mov rsi, r15                 ; length (chunk size)
    syscall
    mov eax, SYS_close           ; close memfd
    mov edi, r14d                ; memfd
    syscall
    mov eax, r10d                ; restore result
    jmp .dtcc_done               ; finalize

.dtcc_close_fail:
    mov eax, SYS_close           ; close memfd on failure
    mov edi, r14d                ; memfd
    syscall
    mov eax, 1                   ; request fallback
    jmp .dtcc_done               ; finish

.dtcc_fallback:
    mov eax, 1                   ; cannot use this path -> fallback

.dtcc_done:
    pop r15                      ; restore r15
    pop r14                      ; restore r14
    pop r13                      ; restore r13
    pop r12                      ; restore r12
    pop rbx                      ; restore rbx
    pop rbp                      ; restore rbp
    ret                          ; return to caller

; -----------------------------------------------------------------------------
; maybe_sendfile_plain
;   Attempt a zero-copy handoff for copy_fd_plain by verifying that input is a
;   regular file and stdout is something the kernel accepts, then loop on
;   sendfile().  Returns 0 on success (file already copied) or 1 to signal the
;   caller to fall back to manual read/write.
; -----------------------------------------------------------------------------
maybe_sendfile_plain:
    push r14                     ; save r14 (used for chunk size)
    mov eax, SYS_fstat           ; fstat(source)
    mov edi, ebx                 ; fd = source
    lea rsi, [rel stat_in]       ; &stat_in
    syscall
    cmp rax, 0                   ; error?
    jl  .sf_fallback             ; fallback if fstat fails
    mov eax, [rel stat_in + STAT_MODE_OFFSET] ; st_mode
    and eax, S_IFMT              ; mask file type bits
    cmp eax, S_IFREG             ; regular file?
    jne .sf_fallback             ; if not regular, fallback

    mov eax, SYS_fstat           ; fstat(stdout)
    mov edi, 1                   ; fd = 1 (stdout)
    lea rsi, [rel stat_out]      ; &stat_out
    syscall
    cmp rax, 0                   ; error?
    jl  .sf_fallback             ; fallback on error
    mov eax, [rel stat_out + STAT_MODE_OFFSET] ; st_mode
    and eax, S_IFMT              ; file type mask
    cmp eax, S_IFREG             ; regular stdout?
    je  .sf_try                  ; yes -> sendfile allowed
    cmp eax, S_IFIFO             ; FIFO?
    je  .sf_try                  ; yes
    cmp eax, S_IFSOCK            ; socket?
    je  .sf_try                  ; yes
    cmp eax, S_IFCHR             ; character device (e.g., terminal)?
    je  .sf_try                  ; yes
    jmp .sf_fallback             ; unsupported output -> fallback

.sf_try:
    mov r14d, SENDFILE_CHUNK     ; initial requested chunk size
.sf_loop:
    mov eax, SYS_sendfile        ; sendfile syscall
    mov edi, 1                   ; out_fd = stdout
    mov esi, ebx                 ; in_fd = source
    xor edx, edx                 ; off = NULL (use current offset)
    mov r10d, r14d               ; count = chunk size
    syscall
    cmp rax, 0                   ; 0 => EOF
    je  .sf_success              ; all done
    jl  .sf_error                ; error -> handle
    jmp .sf_loop                 ; positive => more to copy

.sf_error:
    cmp rax, -EINTR              ; interrupted?
    je  .sf_loop                 ; retry
    cmp rax, -EAGAIN             ; would block?
    je  .sf_loop                 ; retry
    cmp rax, -EPIPE              ; broken pipe?
    jne .sf_error_other
    pop r14
    call handle_sigpipe
.sf_error_other:
    cmp rax, -EINVAL             ; invalid args?
    je  .sf_fallback             ; fallback
    cmp rax, -EOPNOTSUPP         ; not supported?
    je  .sf_fallback             ; fallback
    cmp rax, -ENOSYS             ; syscall missing?
    je  .sf_fallback             ; fallback
    cmp rax, -ESPIPE             ; non-seekable (e.g., pipe input)?
    je  .sf_fallback             ; fallback
    neg rax
    mov edx, eax
    call fatal_write_error       ; unhandled error -> fatal

.sf_success:
    xor eax, eax                 ; eax = 0 (success)
    jmp .sf_done                 ; finish

.sf_fallback:
    mov eax, 1                   ; request fallback to manual copy

.sf_done:
    pop r14                      ; restore r14
    ret                          ; return

; -----------------------------------------------------------------------------
; maybe_splice_plain
;   When stdout is a pipe/FIFO/socket, stream via splice()+pipe to avoid user
;   space copies. Returns 0 if the entire stream was handled, 1 to fall back.
; -----------------------------------------------------------------------------
maybe_splice_plain:
    push r12                     ; save r12
    push r13                     ; save r13
    push r14                     ; save r14
    push r15                     ; save r15
    mov eax, SYS_fstat           ; fstat(stdout)
    mov edi, 1                   ; fd=1
    lea rsi, [rel stat_out]      ; &stat_out
    syscall
    cmp rax, 0                   ; error?
    jl  .msp_fallback            ; fallback if fstat fails
    mov eax, [rel stat_out + STAT_MODE_OFFSET] ; st_mode
    and eax, S_IFMT              ; file type
    cmp eax, S_IFIFO             ; FIFO?
    je  .msp_setup               ; yes -> can use splice
    cmp eax, S_IFSOCK            ; socket?
    je  .msp_setup               ; yes -> splice works
    mov eax, 1                   ; otherwise signal fallback
    jmp .msp_done                ; return

.msp_setup:
    sub rsp, 16                  ; reserve space for pipe fds[2]
    mov eax, SYS_pipe2           ; pipe2 syscall
    lea rdi, [rsp]               ; rdi = &pipefd[0]
    mov esi, O_CLOEXEC           ; CLOEXEC on both ends
    syscall
    cmp rax, 0                   ; error?
    jl  .msp_pipe_fail           ; cleanup and fallback
    mov r13d, [rsp]        ; pipe read end
    mov r14d, [rsp+4]      ; pipe write end
.msp_loop:
    mov eax, SYS_splice          ; splice from source fd to pipe write end
    mov edi, ebx                 ; fd_in = source
    xor esi, esi                 ; off_in = NULL
    mov edx, r14d                ; fd_out = pipe write end
    xor r10d, r10d               ; off_out = NULL
    mov r8d, SPLICE_CHUNK        ; len = chunk size
    mov r9d, SPLICE_F_MOVE       ; flags = move pages
    syscall
    cmp rax, 0                   ; 0 => EOF
    je  .msp_success             ; done
    jl  .msp_splice_error        ; handle errors
    mov r15, rax                 ; r15 = bytes to drain to stdout
.msp_drain:
    mov eax, SYS_splice          ; splice from pipe read end to stdout
    mov edi, r13d                ; fd_in = pipe read
    xor esi, esi                 ; off_in = NULL
    mov edx, 1                   ; fd_out = stdout
    xor r10d, r10d               ; off_out = NULL
    mov r8, r15                  ; len = remaining bytes
    mov r9d, SPLICE_F_MOVE       ; flags = move
    syscall
    cmp rax, 0                   ; error or nothing?
    jl  .msp_splice_error        ; handle errors
    je  .msp_drain_zero          ; avoid infinite loop on zero progress
    cmp rax, r15                 ; wrote all?
    je  .msp_loop                ; yes -> read more from source
    sub r15, rax                 ; else reduce remaining bytes
    jmp .msp_drain               ; continue draining pipe

.msp_drain_zero:
    lea r12, [rel buffer]        ; use scratch buffer to drain pipe
    mov r11, r15                 ; r11 = bytes remaining
.msp_drain_zero_read:
    test r11, r11
    je  .msp_loop
    mov rdx, r11
    cmp rdx, BUFFER_SIZE
    jbe .msp_drain_read
    mov rdx, BUFFER_SIZE
.msp_drain_read:
    mov eax, SYS_read
    mov edi, r13d                ; pipe read end
    mov rsi, r12
    syscall
    cmp rax, 0
    jl  .msp_drain_read_error
    je  .msp_splice_error        ; unexpected EOF
    mov r10, rax                 ; r10 = bytes read
    mov r8, rax                  ; r8 = bytes to write
    mov rsi, r12
.msp_drain_write_loop:
    mov rdx, r8
    mov eax, SYS_write
    mov edi, 1                   ; stdout
    syscall
    cmp rax, 0
    jl  .msp_drain_write_error
    je  .msp_drain_write_loop
    cmp rax, rdx
    je  .msp_drain_write_done
    sub r8, rax
    add rsi, rax
    jmp .msp_drain_write_loop
.msp_drain_write_done:
    sub r11, r10
    jmp .msp_drain_zero_read

.msp_drain_read_error:
    cmp rax, -EINTR
    je  .msp_drain_read
    cmp rax, -EAGAIN
    je  .msp_drain_read
    neg rax
    mov edx, eax
    call fatal_write_error

.msp_drain_write_error:
    cmp rax, -EINTR
    je  .msp_drain_write_loop
    cmp rax, -EAGAIN
    je  .msp_drain_write_loop
    cmp rax, -EPIPE
    je  .msp_drain_sigpipe
    neg rax
    mov edx, eax
    call fatal_write_error
.msp_drain_sigpipe:
    call handle_sigpipe

.msp_splice_error:
    cmp rax, -EINTR              ; interrupted?
    je  .msp_loop                ; retry
    cmp rax, -EAGAIN             ; would block?
    je  .msp_loop                ; retry
    cmp rax, -EPIPE              ; broken pipe?
    je  .msp_sigpipe
    mov eax, 1                   ; other error -> fallback
    jmp .msp_cleanup             ; cleanup pipe fds

.msp_sigpipe:
    call handle_sigpipe

.msp_success:
    xor eax, eax                 ; success -> eax=0

.msp_cleanup:
    mov r15d, eax                ; save result in r15d
    mov edx, [rsp]               ; edx = pipe read end
    mov ecx, [rsp+4]             ; ecx = pipe write end
    mov eax, SYS_close           ; close read end
    mov edi, edx
    syscall
    mov eax, SYS_close           ; close write end
    mov edi, ecx
    syscall
    add rsp, 16                  ; free space of pipe fds
    mov eax, r15d                ; restore result
    jmp .msp_done                ; go to epilogue

.msp_pipe_fail:
    add rsp, 16                  ; clean stack if pipe2 failed
.msp_fallback:
    mov eax, 1                   ; signal fallback to caller

.msp_done:
    pop r15                      ; restore r15
    pop r14                      ; restore r14
    pop r13                      ; restore r13
    pop r12                      ; restore r12
    ret                          ; return to caller

; -----------------------------------------------------------------------------
; process_buffer
;   Inputs: rsi points to raw data, rcx = byte count
;   Uses  : line_start to decide where numbering kicks in,
;           opt_flags to decorate tabs/newlines.
; -----------------------------------------------------------------------------
process_buffer:
    push rbx                     ; save rbx
    push r12                     ; save r12
    push r13                     ; save r13
    push r14                     ; save r14
    push r15                     ; save r15
    mov r12, rsi                 ; r12 = pointer to current position
    mov r13, rcx                 ; r13 = remaining byte count
    lea rbx, [r12 + r13]         ; rbx = end pointer for remaining calculation
    mov r15b, [rel opt_flags]    ; r15b = options flags
    test r15b, OPT_SHOW_NONPRINTING
    jne .visible_path            ; -v variants
    test r15b, OPT_SHOW_TABS
    jne .tabs_path               ; -T/-t/-A fast path

; --- Fast path when only newlines need decoration (-n/-E/-s) ---------------
.newline_loop:
    mov r14, [rel outpos]        ; keep outpos hot in r14
    lea r10, [rel outbuf]        ; base pointer for outbuf
.nl_loop:
    mov r13, rbx                 ; remaining = end - current
    sub r13, r12
    cmp r13, 0
    jle .nl_store_outpos

    ; Blank line at start of line (handles -s)
    cmp byte [rel line_start], 1
    jne .nl_after_start
    mov al, [r12]
    cmp al, 10
    jne .nl_nonblank_start
    test r15b, OPT_SQUEEZE_BLANK
    je  .nl_blank_emit
    cmp byte [rel prev_blank], 1
    jne .nl_blank_emit
    inc r12
    dec r13
    jmp .nl_loop

.nl_blank_emit:
    mov byte [rel line_start], 0
    test r15b, OPT_NUMBER
    je  .nl_blank_no_number
    mov rax, [rel line_no]
    cmp rax, 1000000
    jae .nl_blank_number_slow
    mov eax, BUFFER_SIZE - 9
    cmp r14d, eax
    jle .nl_blank_space_ok
    mov [rel outpos], r14
    call flush_outbuf
    mov r14, [rel outpos]
.nl_blank_space_ok:
    mov eax, [rel line_ascii]
    mov [r10 + r14], eax
    mov ax, [rel line_ascii + 4]
    mov [r10 + r14 + 4], ax
    mov al, [rel line_ascii + 6]
    mov [r10 + r14 + 6], al
    add r14, 7
    call bump_line_ascii
    jmp .nl_blank_no_number
.nl_blank_number_slow:
    mov [rel outpos], r14
    call emit_line_number
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
    mov eax, BUFFER_SIZE - 2
    cmp r14d, eax
    jle .nl_blank_no_number
    mov [rel outpos], r14
    call flush_outbuf
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
.nl_blank_no_number:
    test r15b, OPT_SHOW_ENDS
    je  .nl_blank_no_dollar
    mov byte [r10 + r14], '$'
    inc r14
.nl_blank_no_dollar:
    mov byte [r10 + r14], 10
    inc r14
    mov byte [rel prev_blank], 1
    mov byte [rel line_start], 1
    mov byte [rel line_blank], 1
    inc r12
    dec r13
    jmp .nl_loop

.nl_nonblank_start:
    mov byte [rel line_start], 0
    mov byte [rel line_blank], 0
    test r15b, (OPT_NUMBER | OPT_NUMBER_NONBLANK)
    je  .nl_after_number
    mov rax, [rel line_no]
    cmp rax, 1000000
    jae .nl_number_slow
    mov eax, BUFFER_SIZE - 7
    cmp r14d, eax
    jle .nl_prefix_space_ok
    mov [rel outpos], r14
    call flush_outbuf
    mov r14, [rel outpos]
.nl_prefix_space_ok:
    mov eax, [rel line_ascii]
    mov [r10 + r14], eax
    mov ax, [rel line_ascii + 4]
    mov [r10 + r14 + 4], ax
    mov al, [rel line_ascii + 6]
    mov [r10 + r14 + 6], al
    add r14, 7
    call bump_line_ascii
    jmp .nl_after_number
.nl_number_slow:
    mov [rel outpos], r14
    call emit_line_number
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
.nl_after_number:
.nl_after_start:
    mov rdi, r12
    mov rcx, r13
    mov al, 10
    repne scasb
    mov r11d, 0
    setz r11b                   ; newline found?
    mov rdx, r13
    sub rdx, rcx                ; bytes scanned
    cmp r11b, 0
    je  .nl_no_nl_fast
    dec rdx                     ; bytes before newline

    mov rax, rdx                ; bytes to copy
.nl_copy_loop:
    cmp rax, 0
    je  .nl_copy_done
    mov r8d, BUFFER_SIZE
    sub r8, r14
    cmp r8, 0
    jne .nl_space_ok
    mov [rel outpos], r14
    mov r8, rax                 ; preserve remaining bytes across flush
    call flush_outbuf
    mov rax, r8                 ; restore remaining bytes
    mov r14, [rel outpos]
    mov r8d, BUFFER_SIZE
    sub r8, r14
.nl_space_ok:
    cmp rax, r8
    jbe .nl_copy_fit
    mov r9, r8
    jmp .nl_do_copy
.nl_copy_fit:
    mov r9, rax
.nl_do_copy:
    lea rsi, [r12]
    lea rdi, [r10 + r14]
    mov rcx, r9
    rep movsb
    add r12, r9
    sub r13, r9
    add r14, r9
    sub rax, r9
    jmp .nl_copy_loop
.nl_copy_done:
    test r15b, OPT_SQUEEZE_BLANK
    je  .nl_emit_nl_after_copy
    cmp byte [rel line_blank], 1
    jne .nl_emit_nl_after_copy
    cmp byte [rel prev_blank], 1
    jne .nl_emit_nl_after_copy
    inc r12
    dec r13
    jmp .nl_loop
.nl_emit_nl_after_copy:
    ; ensure space for optional '$' + newline
    mov eax, BUFFER_SIZE - 2
    cmp r14d, eax
    jle .nl_emit_space_ok
    mov [rel outpos], r14
    call flush_outbuf
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
.nl_emit_space_ok:
    test r15b, OPT_SHOW_ENDS
    je  .nl_emit_nl_only_fast
    mov byte [r10 + r14], '$'
    inc r14
.nl_emit_nl_only_fast:
    mov byte [r10 + r14], 10
    inc r14
    mov byte [rel prev_blank], 0
    mov byte [rel line_start], 1
    mov byte [rel line_blank], 1
    inc r12
    dec r13
    jmp .nl_loop

.nl_no_nl_fast:
    mov rax, rdx
.nl_tail_copy_loop:
    cmp rax, 0
    je  .nl_store_outpos
    mov r8d, BUFFER_SIZE
    sub r8, r14
    cmp r8, 0
    jne .nl_tail_space_ok
    mov [rel outpos], r14
    mov r8, rax                 ; preserve remaining byte count
    call flush_outbuf
    mov rax, r8                 ; restore remaining byte count
    mov r14, [rel outpos]
    mov r8d, BUFFER_SIZE
    sub r8, r14
.nl_tail_space_ok:
    cmp rax, r8
    jbe .nl_tail_fit
    mov r9, r8
    jmp .nl_tail_do_copy
.nl_tail_fit:
    mov r9, rax
.nl_tail_do_copy:
    lea rsi, [r12]
    lea rdi, [r10 + r14]
    mov rcx, r9
    rep movsb
    add r12, r9
    sub r13, r9
    add r14, r9
    sub rax, r9
    jmp .nl_tail_copy_loop

.nl_store_outpos:
    mov [rel outpos], r14
    jmp .done

; --- Tabs + newline decoration ---------------------------------------------
.tabs_path:
.tabs_loop:
    mov r13, rbx                ; remaining = end - current
    sub r13, r12
    cmp r13, 0
    jle .tabs_store_outpos

    cmp byte [rel line_start], 1
    jne .tabs_after_start
    mov al, [r12]
    cmp al, 10
    jne .tabs_not_blank_start
    test r15b, OPT_SQUEEZE_BLANK
    je  .tabs_emit_blank
    cmp byte [rel prev_blank], 1
    jne .tabs_emit_blank
    inc r12
    jmp .tabs_loop

.tabs_emit_blank:
    mov byte [rel line_start], 0
    test r15b, OPT_NUMBER
    je  .tabs_blank_num_done
    mov [rel outpos], r14
    call emit_line_number
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
.tabs_blank_num_done:
    test r15b, OPT_SHOW_ENDS
    je  .tabs_blank_emit_nl
    mov dil, '$'
    call emit_byte
.tabs_blank_emit_nl:
    mov dil, 10
    call emit_byte
    mov byte [rel prev_blank], 1
    mov byte [rel line_start], 1
    mov byte [rel line_blank], 1
    inc r12
    jmp .tabs_loop

.tabs_not_blank_start:
    mov byte [rel line_start], 0
    mov byte [rel line_blank], 0
    test r15b, OPT_NUMBER_NONBLANK
    je  .tabs_check_number_all
    call emit_line_number
    jmp .tabs_scan
.tabs_check_number_all:
    test r15b, OPT_NUMBER
    je  .tabs_scan
    call emit_line_number

.tabs_after_start:
.tabs_scan:
    xor rdx, rdx
.tabs_plain_loop:
    cmp rdx, r13
    jae .tabs_run_done
    mov al, [r12 + rdx]
    cmp al, 10
    je  .tabs_run_done
    cmp al, 9
    je  .tabs_run_done
    inc rdx
    jmp .tabs_plain_loop

.tabs_run_done:
    cmp rdx, 0
    je  .tabs_handle_special
    mov r11, rdx               ; preserve run length
    mov rcx, r11
    mov rsi, r12
    call emit_block
    add r12, r11
    mov r13, rbx                ; refresh remaining for special handling
    sub r13, r12
    mov byte [rel line_blank], 0

.tabs_handle_special:
    cmp r13, 0
    jle .tabs_store_outpos
    mov al, [r12]
    cmp al, 9
    jne .tabs_handle_nl
    mov dil, '^'
    call emit_byte
    mov dil, 'I'
    call emit_byte
    mov byte [rel line_blank], 0
    inc r12
    jmp .tabs_loop

.tabs_handle_nl:
    test r15b, OPT_SQUEEZE_BLANK
    je  .tabs_nl_emit
    cmp byte [rel line_blank], 1
    jne .tabs_nl_emit
    cmp byte [rel prev_blank], 1
    jne .tabs_nl_emit
    inc r12
    jmp .tabs_loop
.tabs_nl_emit:
    test r15b, OPT_SHOW_ENDS
    je  .tabs_nl_emit_only
    mov dil, '$'
    call emit_byte
.tabs_nl_emit_only:
    mov dil, 10
    call emit_byte
    mov al, [rel line_blank]
    mov [rel prev_blank], al
    mov byte [rel line_start], 1
    mov byte [rel line_blank], 1
    inc r12
    jmp .tabs_loop

.tabs_store_outpos:
    jmp .done

; --- Visible (-v) path with block copies -----------------------------------
.visible_path:
    mov rbx, r12                 ; rbx = end pointer (start + remaining)
    add rbx, r13
.visible_loop:
    mov r13, rbx                 ; recalc remaining = end - current
    sub r13, r12
    mov r14, [rel outpos]        ; refresh cached outpos each iteration
    lea r10, [rel outbuf]
    cmp r13, 0
    jle  .vis_store_outpos
    cmp r14, BUFFER_SIZE
    jb   .vis_after_guard
    mov [rel outpos], r14
    call flush_outbuf
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
.vis_after_guard:

    cmp byte [rel line_start], 1
    jne .vis_not_blank_start
    mov al, [r12]
    cmp al, 10
    jne .vis_not_blank_start
    test r15b, OPT_SQUEEZE_BLANK
    je  .vis_emit_blank
    cmp byte [rel prev_blank], 1
    jne  .vis_emit_blank
    inc r12
    dec r13
    jmp .visible_loop

.vis_emit_blank:
    mov byte [rel line_start], 0
    test r15b, OPT_NUMBER
    je  .vis_blank_num_done
    mov [rel outpos], r14
    call emit_line_number
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
.vis_blank_num_done:
    mov eax, BUFFER_SIZE - 2
    cmp r14d, eax
    jle .vis_blank_space_ok
    mov [rel outpos], r14
    call flush_outbuf
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
.vis_blank_space_ok:
    test r15b, OPT_SHOW_ENDS
    je  .vis_blank_no_dollar
    mov byte [r10 + r14], '$'
    inc r14
.vis_blank_no_dollar:
    mov byte [r10 + r14], 10
    inc r14
    mov [rel outpos], r14
    mov byte [rel prev_blank], 1
    mov byte [rel line_start], 1
    mov byte [rel line_blank], 1
    inc r12
    dec r13
    jmp .visible_loop

.vis_not_blank_start:
    cmp byte [rel line_start], 0
    je  .vis_scan
    mov byte [rel line_start], 0
    mov byte [rel line_blank], 0
    test r15b, OPT_NUMBER_NONBLANK
    je  .vis_check_number_all
    mov [rel outpos], r14
    call emit_line_number
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
    jmp .vis_scan
.vis_check_number_all:
    test r15b, OPT_NUMBER
    je  .vis_scan
    mov [rel outpos], r14
    call emit_line_number
    mov r14, [rel outpos]
    lea r10, [rel outbuf]

.vis_scan:
    xor rdx, rdx                ; length of printable/plain run
.vis_plain_loop:
    cmp rdx, r13
    jae  .vis_run_done
    mov al, [r12 + rdx]
    cmp al, 10                  ; newline ends run
    je  .vis_run_done
    cmp al, 9                   ; tab?
    jne .vis_after_tab
    test r15b, OPT_SHOW_TABS
    jne  .vis_run_done          ; special when showing tabs
    inc rdx
    jmp .vis_plain_loop
.vis_after_tab:
    cmp al, 0x20
    jb  .vis_run_done           ; control (except tab/newline)
    cmp al, 0x7F
    je  .vis_run_done           ; DEL
    cmp al, 0x80
    jae .vis_run_done           ; high-bit set
    inc rdx
    jmp .vis_plain_loop

.vis_run_done:
    cmp rdx, 0
    je  .vis_handle_special
    mov r11, rdx                ; preserve run length
    mov rcx, rdx                ; rcx = bytes to forward
    mov rsi, r12                ; rsi = source pointer
    call emit_block             ; bulk copy into outbuf with auto-flush
    add r12, r11                ; advance input pointer
    sub r13, r11                ; decrement remaining byte count
    mov byte [rel line_blank], 0
    mov r14, [rel outpos]       ; keep local outpos in sync after emit_block
    lea r10, [rel outbuf]       ; refresh base pointer
    jmp .vis_handle_special

.vis_handle_special:
    cmp r13, 0
    je  .vis_store_outpos
    mov al, [r12]
    cmp al, 10
    je  .vis_handle_nl
    cmp al, 9
    jne .vis_check_control
    test r15b, OPT_SHOW_TABS
    je  .vis_emit_plain_tab
    mov eax, BUFFER_SIZE - 2
    cmp r14d, eax
    jle .vis_tab_space_ok
    mov [rel outpos], r14
    call flush_outbuf
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
.vis_tab_space_ok:
    mov byte [r10 + r14], '^'
    mov byte [r10 + r14 + 1], 'I'
    add r14, 2
    mov [rel outpos], r14
    mov byte [rel line_blank], 0
    inc r12
    dec r13
    jmp .visible_loop

.vis_emit_plain_tab:
    mov eax, BUFFER_SIZE - 1
    cmp r14d, eax
    jle .vis_plain_tab_space_ok
    mov [rel outpos], r14
    call flush_outbuf
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
.vis_plain_tab_space_ok:
    mov byte [r10 + r14], 9
    inc r14
    mov [rel outpos], r14
    mov byte [rel line_blank], 0
    inc r12
    dec r13
    jmp .visible_loop

.vis_check_control:
    cmp al, 0x20
    jb  .vis_control_plain_check
    cmp al, 0x7F
    je  .vis_del_plain_check
    jmp .vis_meta_plain_check        ; high-bit set

.vis_control_plain_check:
    test r15b, OPT_SHOW_NONPRINTING
    jne  .vis_emit_control
    mov dil, al
    call emit_byte
    mov byte [rel line_blank], 0
    inc r12
    dec r13
    jmp .visible_loop

.vis_del_plain_check:
    test r15b, OPT_SHOW_NONPRINTING
    jne  .vis_emit_del
    mov dil, al
    call emit_byte
    mov byte [rel line_blank], 0
    inc r12
    dec r13
    jmp .visible_loop

.vis_meta_plain_check:
    test r15b, OPT_SHOW_NONPRINTING
    jne  .vis_emit_meta
    mov dil, al
    call emit_byte
    mov byte [rel line_blank], 0
    inc r12
    dec r13
    jmp .visible_loop

.vis_emit_control:
    mov byte [rel line_blank], 0
    mov [rel outpos], r14
    call emit_visible_char
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
    inc r12
    dec r13
    jmp .visible_loop

.vis_emit_del:
    mov byte [rel line_blank], 0
    mov [rel outpos], r14
    call emit_visible_char
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
    inc r12
    dec r13
    jmp .visible_loop

.vis_emit_meta:
    mov byte [rel line_blank], 0
    mov [rel outpos], r14
    call emit_visible_char
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
    inc r12
    dec r13
    jmp .visible_loop

.vis_handle_nl:
    test r15b, OPT_SQUEEZE_BLANK
    je  .vis_emit_nl
    cmp byte [rel line_blank], 1
    jne .vis_emit_nl
    cmp byte [rel prev_blank], 1
    jne .vis_emit_nl
    inc r12
    dec r13
    jmp .visible_loop
.vis_emit_nl:
    mov eax, BUFFER_SIZE - 2
    cmp r14d, eax
    jle .vis_nl_space_ok
    mov [rel outpos], r14
    call flush_outbuf
    mov r14, [rel outpos]
    lea r10, [rel outbuf]
.vis_nl_space_ok:
    test r15b, OPT_SHOW_ENDS
    je  .vis_emit_nl_only
    mov byte [r10 + r14], '$'
    inc r14
.vis_emit_nl_only:
    mov byte [r10 + r14], 10
    inc r14
    mov [rel outpos], r14
    mov al, [rel line_blank]
    mov [rel prev_blank], al
    mov byte [rel line_start], 1
    mov byte [rel line_blank], 1
    inc r12
    dec r13
    jmp .visible_loop

.vis_store_outpos:
    jmp .done

.done:
    pop r15                      ; restore r15
    pop r14                      ; restore r14
    pop r13                      ; restore r13
    pop r12                      ; restore r12
    pop rbx                      ; restore rbx
    ret                          ; return

; Decide whether the current line needs a prefix number.
maybe_emit_number:
    cmp byte [rel line_start], 0 ; are we at line start?
    je  .mn_exit                 ; no -> nothing to do
    mov byte [rel line_start], 0 ; mark that we've left line start
    mov bl, [rel opt_flags]      ; bl = flags
    test bl, OPT_NUMBER_NONBLANK ; -b active?
    jz  .mn_check_all            ; if not, check OPT_NUMBER
    cmp al, 10                   ; is this a newline (blank line)?
    je  .mn_exit                 ; yes -> don't number blank line
    call emit_line_number        ; emit right-aligned number
    jmp .mn_exit                 ; done

.mn_check_all:
    test bl, OPT_NUMBER          ; -n active?
    je  .mn_exit                 ; if not, done
    call emit_line_number        ; emit number for any line
.mn_exit:
    ret                          ; return

; Emit control / high-bit characters using ^ and M- notation (POSIX cat -v).
emit_visible_char:
    push rbx                     ; save rbx
    mov bl, al                   ; bl = character
.meta_loop:
    cmp bl, 128                  ; high-bit set?
    jb  .no_meta                 ; if <128, no meta prefix
    mov dil, 'M'                 ; print "M-"
    call emit_byte
    mov dil, '-' 
    call emit_byte
    and bl, 0x7F                 ; strip high bit
    jmp .meta_loop               ; in case multiple 8th bits (theoretically)

.no_meta:
    cmp bl, 0x20                 ; below space?
    jb  .control                 ; yes -> control char notation
    cmp bl, 0x7F                 ; DEL?
    je  .is_del                  ; handle specially
    mov dil, bl                  ; printable char, emit directly
    call emit_byte
    jmp .visible_done            ; done

.control:
    mov dil, '^'                 ; '^'
    call emit_byte
    add bl, 0x40                 ; map control to printable (e.g. 0x01 -> 'A')
    mov dil, bl                  ; resulting printable letter
    call emit_byte
    jmp .visible_done            ; done

.is_del:
    mov dil, '^'                 ; '^'
    call emit_byte
    mov dil, '?'                 ; '?' for DEL
    call emit_byte
.visible_done:
    pop rbx                      ; restore rbx
    ret                          ; return

str_compare:
    ; rdi = candidate, rsi = expected literal
.sc_loop:
    mov al, [rdi]                ; al = *candidate
    mov bl, [rsi]                ; bl = *expected
    cmp al, '='                  ; treat '=' as end of candidate
    je  .sc_cand_end
    cmp al, bl                   ; compare bytes
    jne .sc_diff                 ; mismatch -> not equal
    cmp al, 0                    ; end of string?
    je  .sc_equal                ; both ended -> equal
    inc rdi                      ; advance candidate
    inc rsi                      ; advance expected
    jmp .sc_loop                 ; continue comparing
.sc_cand_end:
    cmp bl, 0                    ; expected also ended?
    je  .sc_equal
    jmp .sc_diff
.sc_diff:
    mov eax, 1                   ; return nonzero on difference
    ret
.sc_equal:
    xor eax, eax                 ; return 0 on equality
    ret

print_help_and_exit:
    mov rdi, 1                   ; fd = stdout
    mov rsi, help_text           ; pointer to help text
    call write_cstr              ; write NUL-terminated string
    xor edi, edi                 ; exit code 0
    call exit_with_code          ; exit

print_version_and_exit:
    mov rdi, 1                   ; fd = stdout
    mov rsi, version_text        ; pointer to version text
    call write_cstr              ; write NUL-terminated string
    xor edi, edi                 ; exit code 0
    call exit_with_code          ; exit

; -----------------------------------------------------------------------------
; emit_line_number
;   Emits the current line number as a right-aligned, 6-column decimal value
;   followed by a tab character (mirroring GNU cat -n).
; -----------------------------------------------------------------------------
emit_line_number:
    push r15                     ; save r15
    push rbx                     ; save rbx
    mov rax, [rel line_no]       ; rax = current line number
    cmp rax, 1000000             ; fast path valid up to 6 digits
    jae .eln_slow
    lea rsi, [rel line_ascii]    ; cached ASCII + tab
    mov rcx, 7
    call emit_block
    call bump_line_ascii         ; increment cached number + line_no
    jmp .eln_return

.eln_slow:
    lea rbx, [rel numbuf + 64]   ; rbx = scratch end
    mov r10d, 100                ; divisor 100
    lea r11, [rel digit_pairs]   ; digit pair table base
    xor rcx, rcx                 ; rcx = digits produced
    test rax, rax                ; line_no == 0 ?
    jne .eln_convert             ; if not zero, convert
    dec rbx
    mov byte [rbx], '0'          ; single zero digit
    mov rcx, 1
    jmp .eln_trim

.eln_convert:
.eln_loop:
    xor rdx, rdx                 ; clear remainder
    div r10                      ; divide by 100
    mov r8d, edx                 ; remainder 0..99
    shl r8, 1                    ; *2 for pair index
    mov dx, [r11 + r8]           ; grab two digits
    dec rbx
    mov [rbx], dh                ; tens
    inc rcx
    dec rbx
    mov [rbx], dl                ; ones
    inc rcx
    test rax, rax                ; quotient zero?
    jne .eln_loop

.eln_trim:
    mov al, [rbx]                ; trim leading zeros
    cmp al, '0'
    jne .eln_ready
    cmp rcx, 1
    je  .eln_ready
    inc rbx
    dec rcx
    jmp .eln_trim

.eln_ready:
    mov r15, rcx                 ; digit count
    mov r8d, 6                   ; width = 6
    mov r9, rcx                  ; r9 = digits
    cmp r9, r8
    jge .eln_no_spaces
    mov r10, r8                  ; r10 = 6
    sub r10, r9                  ; r10 = spaces needed
    jmp .eln_build
.eln_no_spaces:
    xor r10, r10                 ; no leading spaces

.eln_build:
    lea rdi, [rel numbuf]        ; write formatted prefix to numbuf[0..]
    mov rdx, r10                 ; rdx = spaces to emit
.eln_space_loop:
    test rdx, rdx
    je  .eln_copy_digits
    mov byte [rdi], ' '
    inc rdi
    dec rdx
    jmp .eln_space_loop

.eln_copy_digits:
    mov rdx, r15                 ; rdx = digits remaining
.eln_digit_loop_fast:
    test rdx, rdx
    je  .eln_digits_done_fast
    mov al, [rbx]
    mov [rdi], al
    inc rbx
    inc rdi
    dec rdx
    jmp .eln_digit_loop_fast

.eln_digits_done_fast:
    mov byte [rdi], 9            ; tab terminator
    inc rdi
    mov rcx, r10                 ; total length = spaces + digits + tab
    add rcx, r15
    inc rcx
    mov rsi, numbuf              ; source = formatted number
    call emit_block              ; copy into outbuf in one shot
    mov rax, [rel line_no]
    inc rax
    mov [rel line_no], rax       ; bump counter

.eln_return:
    pop rbx                      ; restore rbx
    pop r15                      ; restore r15
    ret

bump_line_ascii:
    lea rdi, [rel line_ascii + 5] ; start from least-significant digit
    mov ecx, 6                   ; six positions
    mov r8b, 1                   ; carry = 1
.bla_loop:
    mov al, [rdi]
    cmp al, ' '
    jne .bla_not_space
    cmp r8b, 0                  ; if no carry, keep leading spaces
    je  .bla_store_space
    mov al, '0'                 ; convert space to '0' only when carry propagates
.bla_not_space:
    sub al, '0'
    add al, r8b
    mov r8b, 0
    cmp al, 10
    jb  .bla_store
    sub al, 10
    mov r8b, 1                   ; propagate carry
.bla_store:
    add al, '0'
    mov [rdi], al
    dec rdi
    loop .bla_loop
    jmp .bla_done

.bla_store_space:
    mov [rdi], al               ; preserve leading space when carry resolved
    dec rdi
    loop .bla_loop

.bla_done:
    inc qword [rel line_no]      ; numeric counter stays in sync
    ret

; -----------------------------------------------------------------------------
; emit_byte
;   Buffered stdout writer with flush-on-full semantics.  AL holds the byte to
;   store, but syscall clobbers AL, so we mirror it via tmp_char.
; -----------------------------------------------------------------------------
emit_byte:
    movzx eax, dil               ; copy low 8 bits of dil into eax
.store_retry:
    mov rcx, [rel outpos]        ; rcx = current output position
    cmp rcx, BUFFER_SIZE         ; buffer full?
    jne .store                   ; if not full, store directly
    mov byte [rel tmp_char], al  ; save byte across flush
    call flush_outbuf            ; flush buffer to stdout
    mov al, byte [rel tmp_char]  ; restore byte
    mov rcx, [rel outpos]        ; reload (should be 0)
.store:
    lea rsi, [rel outbuf]        ; rsi = buffer base
    mov [rsi + rcx], al          ; store byte at outbuf[outpos]
    inc rcx                      ; outpos++
    mov [rel outpos], rcx        ; update outpos
    ret                          ; return

; -----------------------------------------------------------------------------
; emit_block
;   Copies RCX bytes from RSI into outbuf, flushing as needed.  Accelerates
;   simple decoration paths that can forward large spans without per-byte stalls.
; -----------------------------------------------------------------------------
emit_block:
    push rdi                     ; save rdi
.eb_loop:
    cmp rcx, 0                   ; any bytes to copy?
    je  .eb_done                 ; no -> done
    mov rax, [rel outpos]        ; rax = current outpos
    mov rdx, BUFFER_SIZE         ; rdx = buffer capacity
    sub rdx, rax                 ; rdx = bytes left in buffer
    cmp rdx, 0                   ; any space left?
    jne .eb_have                 ; if yes, proceed
    call flush_outbuf            ; else flush buffer
    jmp .eb_loop                 ; and retry
.eb_have:
    mov r8, rcx                  ; r8 = bytes remaining to copy
    cmp r8, rdx                  ; fewer than available space?
    jbe .eb_copy                 ; if yes, copy them all
    mov r8, rdx                  ; else copy only up to buffer capacity
.eb_copy:
    lea rdi, [rel outbuf]        ; dest = &outbuf
    add rdi, rax                 ; plus current outpos
    mov r10, rcx                 ; save total remaining in r10
    mov rcx, r8                  ; rcx = bytes to copy now
    rep movsb                    ; copy rcx bytes from rsi to rdi
    mov rcx, r10                 ; restore total remaining
    sub rcx, r8                  ; subtract copied bytes
    add rax, r8                  ; advance outpos
    mov [rel outpos], rax        ; store new outpos
    jmp .eb_loop                 ; loop if bytes remain
.eb_done:
    pop rdi                      ; restore rdi
    ret                          ; return

; -----------------------------------------------------------------------------
; chunk_all_printable
;   Returns eax=1 if the RCX-byte chunk at RSI contains only printable ASCII,
;   tabs, and newlines (i.e., no transformations needed for plain -v).
; -----------------------------------------------------------------------------
chunk_all_printable:
    test rcx, rcx
    je  .cap_true
.cap_loop:
    mov al, [rsi]
    cmp al, 0x20
    jb  .cap_ctrl
    cmp al, 0x7F
    je  .cap_false
    cmp al, 0x80
    jae .cap_false
    jmp .cap_next
.cap_ctrl:
    cmp al, 9                    ; tab allowed
    je  .cap_next
    cmp al, 10                   ; newline allowed
    je  .cap_next
    jmp .cap_false
.cap_next:
    inc rsi
    dec rcx
    jnz .cap_loop
.cap_true:
    mov eax, 1
    ret
.cap_false:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
; write_direct_stdout
;   Flushes current outbuf then writes RCX bytes from RSI straight to stdout.
; -----------------------------------------------------------------------------
write_direct_stdout:
    push rcx
    push rsi
    call flush_outbuf            ; ensure buffered data is out
    pop rsi
    pop rcx
.wds_loop:
    mov rdx, rcx
    mov eax, SYS_write
    mov edi, 1
    syscall
    cmp rax, 0
    jl  .wds_error
    je  .wds_loop                ; 0 -> retry
    cmp rax, rdx
    je  .wds_done
    sub rcx, rax
    add rsi, rax
    jmp .wds_loop
.wds_error:
    cmp rax, -EINTR
    je  .wds_loop
    cmp rax, -EAGAIN
    je  .wds_loop
    cmp rax, -EPIPE
    je  .wds_sigpipe
    neg rax
    mov edx, eax
    call fatal_write_error
.wds_sigpipe:
    call handle_sigpipe
.wds_done:
    mov qword [rel outpos], 0    ; keep buffered state consistent
    ret

; -----------------------------------------------------------------------------
; flush_outbuf
;   Writes outbuf[0:outpos) to stdout, honoring partial writes.
; -----------------------------------------------------------------------------
flush_outbuf:
    push rcx                     ; save rcx
    push rsi                     ; save rsi
    mov rcx, [rel outpos]        ; rcx = bytes pending
    cmp rcx, 0                   ; nothing to write?
    je  .flush_return            ; yes -> return
    lea rsi, [rel outbuf]        ; rsi = buffer base
.flush_loop:
    mov rdx, rcx                 ; rdx = bytes to write
    mov eax, SYS_write           ; write() syscall
    mov edi, 1                   ; fd = stdout
    syscall
    cmp rax, 0                   ; error?
    jl  .write_error             ; <0 -> handle error
    je  .flush_loop              ; 0 -> try again
    cmp rax, rdx                 ; wrote everything?
    je  .all_flushed             ; yes -> done
    sub rcx, rax                 ; rcx = remaining bytes
    add rsi, rax                 ; advance buffer pointer
    jmp .flush_loop              ; continue writing

.write_error:
    cmp rax, -EINTR              ; interrupted?
    je  .flush_loop              ; retry write
    cmp rax, -EAGAIN             ; would block?
    je  .flush_loop              ; retry
    cmp rax, -EPIPE              ; broken pipe?
    je  .flush_sigpipe
    neg rax
    mov edx, eax
    call fatal_write_error
.flush_sigpipe:
    call handle_sigpipe

.all_flushed:
    mov qword [rel outpos], 0    ; reset buffer position to 0
    jmp .flush_return            ; return

.flush_done:
    jmp .flush_return            ; (unused label for symmetry)

.flush_return:
    pop rsi                      ; restore rsi
    pop rcx                      ; restore rcx
    ret                          ; return

; -----------------------------------------------------------------------------
; Simple helpers for consistent diagnostics / exit handling.
; -----------------------------------------------------------------------------
report_open_error:
    mov byte [rel errflag], 1    ; mark that an error occurred
    mov r8, rsi                  ; save filename pointer in r8
    mov r9d, edx                 ; save errno in r9d
    mov rdi, 2                   ; fd = stderr
    mov rsi, err_prefix          ; prefix string
    call write_cstr              ; write prefix
    mov rsi, r8                  ; restore filename pointer
    call write_cstr              ; write filename / label
    mov rsi, err_open_sep        ; ": "
    call write_cstr              ; separator before strerror

    mov edx, r9d                 ; edx = errno for lookup
    call write_errno_string      ; print errno string

    mov rsi, newline             ; newline string
    call write_cstr              ; end line
    ret                          ; return

report_read_error:
    jmp report_open_error        ; same formatting as open errors
report_bad_short_option:
    mov byte [rel errflag], 1    ; mark error
    mov [rel opt_char_buf], dil  ; store offending option character
    mov byte [rel opt_char_buf + 1], 0
    mov rdi, 2                   ; fd = stderr
    call write_prog_name
    mov rsi, err_invalid_option_mid
    call write_cstr
    lea rsi, [rel opt_char_buf]
    call write_cstr
    mov rsi, err_option_close
    call write_cstr
    mov rsi, err_try_prefix
    call write_cstr
    call write_prog_name
    mov rsi, err_try_suffix
    call write_cstr
    mov edi, 1                   ; exit code = 1
    call exit_with_code

report_bad_long_option:
    mov byte [rel errflag], 1    ; mark error
    mov r8, rsi                  ; save option string pointer
    mov rdi, 2                   ; fd = stderr
    call write_prog_name
    mov rsi, err_unrecognized_option_mid
    call write_cstr
    mov rsi, r8                  ; offending option
    call write_cstr
    mov rsi, err_option_close
    call write_cstr
    mov rsi, err_try_prefix
    call write_cstr
    call write_prog_name
    mov rsi, err_try_suffix
    call write_cstr
    mov edi, 1                   ; exit code = 1
    call exit_with_code

report_long_option_argument:
    mov byte [rel errflag], 1    ; mark error
    mov r8, rsi                  ; save option name pointer
    mov rdi, 2                   ; fd = stderr
    call write_prog_name
    mov rsi, err_option_arg_mid
    call write_cstr
    mov rsi, err_option_arg_dashes
    call write_cstr
    mov rsi, r8                  ; option name (no "--")
    call write_until_eq
    mov rsi, err_option_arg_tail
    call write_cstr
    mov rsi, err_try_prefix
    call write_cstr
    call write_prog_name
    mov rsi, err_try_suffix
    call write_cstr
    mov edi, 1
    call exit_with_code

write_prog_name:
    mov rsi, [rel prog_name]
    call write_cstr
    ret

write_until_eq:
    mov rcx, rsi                 ; rcx = scan pointer
.wue_scan:
    mov al, [rcx]
    cmp al, 0
    je  .wue_have_len
    cmp al, '='
    je  .wue_have_len
    inc rcx
    jmp .wue_scan
.wue_have_len:
    mov rdx, rcx
    sub rdx, rsi                 ; rdx = length
    cmp rdx, 0
    je  .wue_return
.wue_write_loop:
    mov eax, SYS_write
    syscall
    cmp rax, 0
    jl  .wue_write_error
    je  .wue_write_loop
    cmp rax, rdx
    je  .wue_return
    sub rdx, rax
    add rsi, rax
    jmp .wue_write_loop
.wue_write_error:
    cmp rax, -EINTR
    je  .wue_write_loop
    cmp rax, -EAGAIN
    je  .wue_write_loop
    mov byte [rel errflag], 1
    mov edi, 1
    call exit_with_code
.wue_return:
    ret

handle_sigpipe:
    mov eax, 39                  ; SYS_getpid
    syscall
    mov edi, eax
    mov esi, 13                  ; SIGPIPE
    mov eax, 62                  ; SYS_kill
    syscall
    mov edi, 1                   ; exit if SIGPIPE ignored
    call exit_with_code

fatal_write_error:
    mov byte [rel errflag], 1    ; mark fatal I/O error
    mov r9d, edx                 ; save errno
    mov rdi, 2                   ; fd = stderr
    mov rsi, err_write_prefix
    call write_cstr
    mov edx, r9d
    call write_errno_string
    mov rsi, newline
    call write_cstr
    mov edi, 1                   ; exit status = 1
    call exit_with_code

write_cstr:
    mov rcx, rsi                 ; rcx = current pointer
.len_loop:
    cmp byte [rcx], 0            ; reached NUL terminator?
    je  .have_len                ; yes -> compute length
    inc rcx                      ; move to next char
    jmp .len_loop                ; keep scanning

.have_len:
    mov rdx, rcx                 ; rdx = end pointer
    sub rdx, rsi                 ; rdx = length (end - start)
    cmp rdx, 0                   ; zero-length string?
    je  .return                  ; nothing to write
 .write_loop:
    mov eax, SYS_write           ; write() syscall
    syscall                      ; write(rdi, rsi, rdx)
    cmp rax, 0                   ; error?
    jl  .write_error             ; <0 -> handle
    je  .write_loop              ; 0 -> retry
    cmp rax, rdx                 ; wrote all bytes?
    je  .return                  ; yes -> return
    sub rdx, rax                 ; adjust remaining
    add rsi, rax                 ; move pointer
    jmp .write_loop              ; write remaining

.write_error:
    cmp rax, -EINTR              ; interrupted?
    je  .write_loop              ; retry
    cmp rax, -EAGAIN             ; would block?
    je  .write_loop              ; retry
    mov byte [rel errflag], 1    ; mark error
    mov edi, 1                   ; exit code
    call exit_with_code          ; exit immediately
.return:
    ret                          ; return to caller

; -----------------------------------------------------------------------------
; write_errno_string
;   Input : rdi = fd (typically stderr), edx = errno value
;   Effect: writes a short human-readable errno description.
; -----------------------------------------------------------------------------
write_errno_string:
    cmp edx, ENOENT
    je  .enoent
    cmp edx, EACCES
    je  .eacces
    cmp edx, EIO
    je  .eio
    cmp edx, EISDIR
    je  .eisdir
    cmp edx, ENOTDIR
    je  .enotdir
    cmp edx, ELOOP
    je  .eloop
    cmp edx, ENAMETOOLONG
    je  .enametoolong
    cmp edx, EMFILE
    je  .emfile
    cmp edx, ENFILE
    je  .enfile
    cmp edx, EROFS
    je  .erofs
    cmp edx, ENOSPC
    je  .enospc
    cmp edx, EINVAL
    je  .einval
    cmp edx, EBADF
    je  .ebadf
    cmp edx, EFBIG
    je  .efbig
    cmp edx, ENOMEM
    je  .enomem

    mov rsi, err_unknown
    jmp write_cstr

.enoent:
    mov rsi, err_enoent
    jmp write_cstr
.eacces:
    mov rsi, err_eacces
    jmp write_cstr
.eisdir:
    mov rsi, err_eisdir
    jmp write_cstr
.enotdir:
    mov rsi, err_enotdir
    jmp write_cstr
.eloop:
    mov rsi, err_eloop
    jmp write_cstr
.enametoolong:
    mov rsi, err_enametoolong
    jmp write_cstr
.emfile:
    mov rsi, err_emfile
    jmp write_cstr
.enfile:
    mov rsi, err_enfile
    jmp write_cstr
.erofs:
    mov rsi, err_erofs
    jmp write_cstr
.eio:
    mov rsi, err_eio
    jmp write_cstr
.enospc:
    mov rsi, err_enospc
    jmp write_cstr
.einval:
    mov rsi, err_einval
    jmp write_cstr
.ebadf:
    mov rsi, err_ebadf
    jmp write_cstr
.efbig:
    mov rsi, err_efbig
    jmp write_cstr
.enomem:
    mov rsi, err_enomem
    jmp write_cstr

exit_with_code:
    mov eax, SYS_exit            ; exit syscall
    syscall                      ; terminate process with status in edi
