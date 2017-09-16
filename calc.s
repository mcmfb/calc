; calc.s: an RPN calculator.
; Copyright (C) 2017 Mateus Carmo M de F Barbosa
;
; This program is licensed under the GNU General Public License version 3.
; See LICENSE.txt for details.
;

global _start

; NOTE: the macros below don't include the usual 'mov rbp, rsp' and
; 'mov rsp, rbp' because rbp is a general purpose register, and need not be
; used for restoring rsp. Should one want to use rbp for that, do it like:
;	PUSH_CALLEE_SAVED_REGISTERS
;	mov rbp, rsp
;	...
;	mov rsp, rbp
;	POP_CALLEE_SAVED_REGISTERS
;
%macro PUSH_CALLEE_SAVED_REGISTERS 0
	push rbp
	push rbx
	push r12
	push r13
	push r14
	push r15
%endmacro
%macro POP_CALLEE_SAVED_REGISTERS 0
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
%endmacro

NUL				equ `\0`
SPACE				equ ` `
NEWLINE				equ `\n`
TAB				equ `\t`

STDIN				equ 0
STDOUT				equ 1
STDERR				equ 2

; Linux x86_64
SYS_WRITE			equ 1
SYS_EXIT			equ 60

; note: MXCSR's 16 upper bits are reserved; do not change them.
MXCSR_TRUNCATE_MASK		equ 0x00006000	; use with OR

; IEEE floating point stuff
FLT_DIG				equ 6	; same meaning as in C

; error codes
ERR_INVALID_TOKEN		equ -1
ERR_OVERFLOW			equ -2
ERR_NUM_STACK_OVERFLOW		equ -3
ERR_NUM_STACK_UNDERFLOW		equ -4
ERR_NUM_TOO_LARGE		equ -5
ERR_TOO_MANY_NUMBERS		equ -6
ERR_NO_ARGUMENTS		equ -7

section .rodata
	; floating point instructions need addresses, so here they are
	f0.1			dd 0.1
	f10			dd 10.0
	fminus1			dd -1.0

	; messages
	msgUsage		db \
'usage: program_name [options] expr', NEWLINE, \
'options:', NEWLINE, \
TAB, '-h, --help', TAB, 'display this message', NEWLINE, \
NEWLINE, \
'expr must be an RPN numeric expression. Examples:', NEWLINE, \
TAB, 'Expression      Result', NEWLINE, \
TAB, '4               4.0', NEWLINE, \
TAB, '1 2 +           3.0', NEWLINE, \
TAB, '1 -2 - 2 +      5.0', NEWLINE, \
TAB, '3 1 2.5 * /     1.2', NEWLINE, \
NEWLINE, \
'All following are considered valid number formats:', NEWLINE, \
TAB, '32  10.  +3.5  .5  -.5', NEWLINE, \
NEWLINE, \
'Operators supported: + - * /', NEWLINE, \
NEWLINE, \
'expr may be passed as a single argument (by quoting it), or as', NEWLINE, \
'multiple arguments; in the latter case, one might need to write', NEWLINE, \
'the asterisk as \* to prevent its expansion by the shell.', NEWLINE
	msgUsageSiz		equ $-msgUsage

	; TODO it'd be great if this could print the invalid token as well
	msgInvalidToken		db \
'invalid token', NEWLINE
	msgInvalidTokenSiz	equ $-msgInvalidToken

	msgOverflow		db \
'overflow ocurred in some integer operation', NEWLINE
	msgOverflowSiz		equ $-msgOverflow

	msgNumStackOverflow	db \
'the number stack overflowed', NEWLINE
	msgNumStackOverflowSiz	equ $-msgNumStackOverflow

	msgNumStackUnderflow	db \
'too many operators, or not enough numbers', NEWLINE
	msgNumStackUnderflowSiz	equ $-msgNumStackUnderflow

	msgNumTooLarge		db \
'the number is too large to fit in its string representation', NEWLINE
	msgNumTooLargeSiz	equ $-msgNumTooLarge

	msgTooManyNumbers	db \
'too many numbers, or not enough operators', NEWLINE
	msgTooManyNumbersSiz	equ $-msgTooManyNumbers

	; short options
	helpShortOpt		db '-h'
	helpShortOptSiz		equ $-helpShortOpt

	; long options
	helpLongOpt		db '--help'
	helpLongOptSiz		equ $-helpLongOpt

section .data
	nsttop	dd 0 ; number stack top, as a relative offset (in bytes)

section .bss
	buf		resb 1024
	bufsiz		equ $-buf
	nst		resd 1024	; number stack
	nstsiz		equ $-nst

section .text
_start:
	mov rbx, [rsp] ; here, [rsp] == argc
	cmp rbx, 1
	je .usage
	cmp rbx, 2
	je .singleArg

	mov rdi, [rsp] ; argc
	lea rsi, [rsp+8] ; argv
	call loopOverArgs
	jmp .printst
.usage:
	mov rdi, STDERR
	mov rsi, ERR_NO_ARGUMENTS
	call usage
	jmp .quit

.singleArg:
	mov rdi, [rsp+16] ; rsp+8*(n+1) == argv + n
	call loopOverStr
.printst:
	call printst
.quit:
	xor rdi, rdi
	call death

; (leaf?)
; args
;	(rdi) the file descriptor to write to (could be e.g. STDERR or STDOUT)
;	(rsi) error code
; returns
;	nothing
usage:
	mov r8, rsi

	mov rax, SYS_WRITE
	; rdi is ready
	mov rsi, msgUsage 
	mov rdx, msgUsageSiz
	syscall

	mov rdi, r8
	call death
	ret

; args
;	(rdi) argc (number of arguments, including the program name)
;	(rsi) argv (address of the first argument, which is the prog name)
; returns
;	nothing
loopOverArgs:
	PUSH_CALLEE_SAVED_REGISTERS
	mov r12, rdi
	mov r13, rsi
	mov r14, 1 ; index; we start from 1 to skip the program name
.loop:
	cmp r14, r12
	je .quit

	mov r15, [r13+8*r14] ; argv[n]

	mov rdi, r15
	call strend
	mov rbx, rax ; address of '\0' in argv[n]

	mov rdi, r15
	mov rsi, rbx
	call parstok

	inc r14
	jmp .loop
.quit:
	POP_CALLEE_SAVED_REGISTERS
	ret

; args
;	(rdi) the expression's starting address
; returns
;	nothing
loopOverStr:
	PUSH_CALLEE_SAVED_REGISTERS
	mov r12, rdi
	mov r13, rdi
.loop:
	xor rbx, rbx

	mov rdi, r13
	mov rsi, 1
	call skipOrSeekBlanks
	mov r12, rdi
	cmp rax, 1
	sete bl
	; rdi is ready
	xor rsi, rsi
	call skipOrSeekBlanks
	mov r13, rdi
	cmp rax, 1
	sete bh

	; NOTE: this will call parstok at the null terminator if the string
	; has spaces after the last token
	mov rdi, r12
	mov rsi, r13
	call parstok

	; if either bl or bh is set, bx != 0
	cmp bx, 0
	jne .quit
	jmp .loop
.quit:
	POP_CALLEE_SAVED_REGISTERS
	ret

; args
;	(rdi) an address in a null-terminated string 
;	(rsi) mode of operation (1 skips the blanks, 0 seeks a blank)
; returns
;	(rdi) the new address
;	(rax) 1 if the end of the string was reached, 0 otherwise.
skipOrSeekBlanks:
	PUSH_CALLEE_SAVED_REGISTERS
	mov rbx, rdi
	mov r12, rsi
	jmp .loop
.inc:
	inc rbx
.loop:
	cmp byte [rbx], NUL
	je .endstr
	xor rdi, rdi
	mov dil, byte [rbx]
	call isblank
	cmp rax, r12 ; this relies on isblank returning 1 as the 'true' value
	je .inc

	xor rax, rax
	jmp .quit
.endstr:
	mov rax, 1
.quit:
	mov rdi, rbx
	POP_CALLEE_SAVED_REGISTERS
	ret

; args
;	(rdi) address of token's first char
;	(rsi) address of the char after token's last char
; returns
;	nothing
parstok:
	PUSH_CALLEE_SAVED_REGISTERS
	mov rbx, rdi
	mov r12, rsi

	cmp r12, rbx
	jle .inval
	cmp byte [rbx], NUL
	je .inval

	xor rdi, rdi
	mov dil, byte [rbx]
	call isdigit
	cmp rax, 1 ; this relies on isdigit returning 1 as the 'true' value
	je .num
	; if it doesn't start with a digit and is 1 char long, it can't be
	; a number, so we assume it's an operator
	mov rcx, r12
	sub rcx, rbx
	cmp rcx, 1
	je .oper1char
	; if it isn't 1 char long and begins with any of these digits, it
	; may be a number
	cmp byte [rbx], '.'
	je .num
	cmp byte [rbx], '+'
	je .num

	cmp byte [rbx], '-'	; could be a number or an option
	je .minus

	jmp .operMultichar
.num:
	mov rdi, rbx
	mov rsi, r12
	call parsnum
	jmp .quit
.minus:
	xor rdi, rdi
	mov dil, byte [rbx+1]
	call isdigit
	cmp rax, 1 ; this relies on isdigit returning 1 as the 'true' value
	je .num
	cmp byte [rbx+1], '.'
	je .num
	cmp byte [rbx+1], '-'
	je .longopt
	jmp .shortopt
.oper1char:
	mov rdi, rbx
	call oper1char
	jmp .quit
.operMultichar:
	mov rdi, rbx
	mov rsi, r12
	call operMultichar
	jmp .quit
.longopt:
	mov rdi, rbx
	mov rsi, r12
	call longopt
	jmp .quit
.shortopt:
	mov rdi, rbx
	mov rsi, r12
	call shortopt
	jmp .quit
.inval:
	call invalidToken
.quit:
	POP_CALLEE_SAVED_REGISTERS
	ret

; args
;	(rdi) address of token's first char
;	(rsi) address of the char after token's last char
; returns
;	nothing
parsnum:
	PUSH_CALLEE_SAVED_REGISTERS
	mov rbx, rdi
	mov r12, rsi

	call str2flt
	; xmm0 is ready
	call pushnum

.quit:
	POP_CALLEE_SAVED_REGISTERS
	ret


; args
;	(rdi) address of token's first char
;	(rsi) address of the char after token's last char
; returns
;	(xmm0) the number
str2flt:
	;
	; TODO: support to the exp notation; this involves finding 'e',
	; calling str2int for the value after it, and changing some occurences
	; of r12 for whatever register we're using to store e's location
	;
	PUSH_CALLEE_SAVED_REGISTERS
	mov rbp, rsp
	and rsp, -16
	sub rsp, 16

	mov rbx, rdi
	mov r12, rsi
	xor r13, r13	; dot's position, or end of token if there's no dot
	xor r14, r14	; 1 if number is negative, 0 otherwise
	pxor xmm0, xmm0
	movss [rsp+12], xmm0

	mov rdi, rbx
	mov rsi, r12
	mov dl, '.'
	call findchar
	mov r13, rax
	cmp r13, 0
	jne .beforesign
	mov r13, r12
.beforesign:
	mov rdi, rbx
	call skipsign
	mov rbx, rdi
	mov r14, rax
.aftersign:
	cmp r13, rbx
	je .afterdot	; no digits before the dot 

	mov rdi, rbx
	mov rsi, r13
	call str2uint

	cmp r14, 0
	je .pos
	neg rax
.pos:
	cvtsi2ss xmm1, rax
	movss xmm0, [rsp+12]
	addss xmm0, xmm1
	movss [rsp+12], xmm0
.afterdot:
	cmp r12, r13
	je .quit	; no dot
	lea rdx, [r13+1]
	cmp r12, rdx
	je .quit	; no digits after the dot

	lea rdi, [r13+1]
	mov rsi, r12
	call str2uint	; uint because there can't be a sign after the dot

	cmp r14, 0
	je .pos2
	neg rax
.pos2:
	cvtsi2ss xmm1, rax
	mov rcx, r12
	lea rdx, [r13+1]
	sub rcx, rdx	; rcx: number of digits between the dot and the 'e'
.loop:
	mulss xmm1, [f0.1]
	dec rcx
	cmp rcx, 0
	jg .loop

	movss xmm0, [rsp+12]
	addss xmm0, xmm1
	;movss [rsp+12], xmm0	; not needed for now, will be for 'e' support
	jmp .quit
.quit:
	mov rsp, rbp
	POP_CALLEE_SAVED_REGISTERS
	ret

; args
;	(rdi) address of token's first char
;	(rsi) address of the char after token's last char
; returns
;	(rax) the integer
str2int:
	;
	; isn't used for now, will be with 'e' support
	; TODO: remove this message after that is implemented
	;
	PUSH_CALLEE_SAVED_REGISTERS
	mov rbx, rdi
	mov r12, rsi
	xor r13, r13	; 1 if number is negative, 0 otherwise

	mov rdi, rbx
	call skipsign
	mov rbx, rdi
	mov r13, rax

	mov rdi, rbx
	mov rsi, r12
	call str2uint
	cmp r13, 0
	je .quit

	neg rax
.quit:
	POP_CALLEE_SAVED_REGISTERS
	ret

; args
;	(rdi) address of token's first char
;	(rsi) address of the char after token's last char
; returns
;	(rax) the unsigned integer
str2uint:
	PUSH_CALLEE_SAVED_REGISTERS
	mov r12, rdi
	mov r13, rsi
	mov r14, 1 	; ten's power
	xor r15, r15	; result

	cmp r13, r12
	jle .inval

	dec r13	; at first, r12 points to the char after the last digit
.loop:
	xor rbx, rbx
	mov bl, byte [r13]

	xor rdi, rdi
	mov dil, bl
	call isdigit
	cmp rax, 0
	je .inval

	sub bl, '0'
	mov rax, rbx
	mul r14
	jo .overflow
	mov rbx, rax
	add r15, rbx

	mov rax, r14
	mov rcx, 10
	mul rcx
	jo .overflow
	mov r14, rax

	dec r13
	cmp r13, r12
	jge .loop

	mov rax, r15
	jmp .quit
.inval:
	call invalidToken
.overflow:
	call overflow
.quit:
	POP_CALLEE_SAVED_REGISTERS
	ret

; (leaf)
; args
;	(xmm0) the number to be pushed into the number stack
; returns
;	nothing
pushnum:
	push rbp
	mov rbp, rsp
	and rsp, -16

	mov ecx, dword [nsttop]

	cmp ecx, nstsiz
	jge .numStackOverflow

	movss [nst+ecx], xmm0
	add dword [nsttop], 4
	jmp .quit

.numStackOverflow:
	call numStackOverflow
.quit:
	mov rsp, rbp
	pop rbp
	ret

; (leaf)
; args
;	none
; returns
;	(xmm0) the number popped from the number stack
popnum:
	push rbp
	mov rbp, rsp
	and rsp, -16

	xor rax, rax
	pxor xmm0, xmm0
	sub dword [nsttop], 4
	mov ecx, dword [nsttop]

	cmp ecx, 0
	jl .numStackUnderflow

	movss xmm0, [nst+ecx]
	jmp .quit

.numStackUnderflow:
	call numStackUnderflow
.quit:
	mov rsp, rbp
	pop rbp
	ret

; args
;	(rdi) address of token's only char
; returns
;	nothing
oper1char:
	PUSH_CALLEE_SAVED_REGISTERS
	mov rbp, rsp
	and rsp, -16
	sub rsp, 16

	mov rbx, rdi
	;
	; since all of these operators are binary (recieve 2 arguments),
	; some code is common to all of them, and I could very well put it
	; here instead. But I won't, because popping numbers before checking
	; if the operator is valid would give a stack underflow error when
	; the actual error is an invalid token.
	; Also, I could check that the operator is valid, execute the code
	; common to binary operators, and then see what operator it is; but
	; I won't do that either, because it would mean making the same
	; comparisons twice.
	; Finally, I could put that code in magical macros that only
	; make sense in this function, but surely that's even worse.
	; In the end, this is the least worst solution.
	;
	mov al, byte [rbx]
	cmp al, '+'
	je .add
	cmp al, '-'
	je .sub
	cmp al, '*'
	je .mult
	cmp al, '/'
	je .div

	jmp .inval
.add:
	call popnum
	movss [rsp+12], xmm0
	call popnum

	addss xmm0, [rsp+12]

	call pushnum
	jmp .quit
.sub:
	call popnum
	movss [rsp+12], xmm0
	call popnum

	subss xmm0, [rsp+12]

	call pushnum
	jmp .quit
.mult:
	call popnum
	movss [rsp+12], xmm0
	call popnum

	mulss xmm0, [rsp+12]

	call pushnum
	jmp .quit
.div:
	call popnum
	movss [rsp+12], xmm0
	call popnum

	divss xmm0, [rsp+12]

	call pushnum
	jmp .quit
.inval:
	call invalidToken
.quit:
	mov rsp, rbp
	POP_CALLEE_SAVED_REGISTERS
	ret

; args
;	(rdi) address of token's first char
;	(rsi) address of the char after token's last char
; returns
;	nothing
operMultichar:
	; TODO sqrt(x) and rsqrt(x) := 1/sqrt(x)
	call invalidToken
	ret

; args
;	(rdi) address of token's first char
;	(rsi) address of the char after token's last char
; returns
;	nothing
shortopt:
	PUSH_CALLEE_SAVED_REGISTERS
	mov r12, rdi
	mov r13, rsi

	sub rsi, rdi
	mov r14, rsi ; number of characters in token

	mov rdi, r12
	mov rsi, r14
	mov rdx, helpShortOpt
	mov rcx, helpShortOptSiz
	call tokeq
	cmp rax, 1
	je .help

	call invalidToken
	jmp .quit
.help:
	mov rdi, STDOUT
	xor rsi, rsi
	call usage
	jmp .quit

.quit:
	POP_CALLEE_SAVED_REGISTERS
	ret

; args
;	(rdi) address of token's first char
;	(rsi) address of the char after token's last char
; returns
;	nothing
longopt:
	PUSH_CALLEE_SAVED_REGISTERS
	mov r12, rdi
	mov r13, rsi

	sub rsi, rdi
	mov r14, rsi ; number of characters in token

	mov rdi, r12
	mov rsi, r14
	mov rdx, helpLongOpt
	mov rcx, helpLongOptSiz
	call tokeq
	cmp rax, 1
	je .help

	call invalidToken
	jmp .quit

.help:
	mov rdi, STDOUT
	xor rsi, rsi
	call usage
	jmp .quit

.quit:
	POP_CALLEE_SAVED_REGISTERS
	ret


; (leaf)
; args
;	(rdi) address of token's first char
; returns
;	(rdi) the address after skipping the sign
;	(rax) 1 if a minus sign was skipped; 0 otherwise
;	(rdx) 1 if a sign was skipped at all; 0 otherwise
skipsign:
	xor rax, rax
	xor rdx, rdx

	cmp byte [rdi], '-'
	je .minus
	cmp byte [rdi], '+'
	je .plus

	jmp .quit
.minus:
	inc rdi
	mov rdx, 1
	mov rax, 1
	jmp .quit
.plus:
	inc rdi
	mov rdx, 1
	;jmp .quit
.quit:
	ret

; (leaf)
; args
;	(rdi) address of token's first char
;	(rsi) address of the char after token's last char
;	(dl) the char to be found in the token
; returns
;	(rax) the address of the char in (dl), if found; 0 otherwise
findchar:
	xor rax, rax	; default return value
	cmp rsi, rdi
	jle .quit
.loop:
	cmp byte [rdi], dl
	je .found
	inc rdi
	cmp rdi, rsi
	jl .loop
.quit:
	ret
.found:
	mov rax, rdi
	ret

; (leaf)
; args
;	(rdi) a char
; returns
;	(rax) the answer
isblank:
	cmp rdi, SPACE
	je .true
	cmp rdi, NEWLINE
	je .true
	cmp rdi, TAB
	je .true

	xor rax, rax
	ret
.true:
	mov rax, 1
	ret

; (leaf)
; args
;	(rdi) a char
; returns
;	(rax) the answer
isdigit:
	cmp rdi, '0'
	jl .false
	cmp rdi, '9'
	jg .false

	mov rax, 1
	ret
.false:
	xor rax, rax
	ret

; args
;	none
; returns
;	nothing
printst:
	PUSH_CALLEE_SAVED_REGISTERS

	cmp dword [nsttop], 4
	jg .tooManyNums

	call popnum

	mov rdi, buf
	lea rsi, [buf+bufsiz]
	; xmm0 is ready
	call flt2str
	mov r12, rax

	mov byte [buf+r12], NEWLINE
	inc r12
	mov rcx, bufsiz
	cmp rcx, r12
	jle .numTooLarge

	mov rax, SYS_WRITE
	mov rdi, STDOUT
	mov rsi, buf
	mov rdx, r12
	syscall

	jmp .quit

.tooManyNums:
	call tooManyNumbers
.numTooLarge:
	call numTooLarge
.quit:
	POP_CALLEE_SAVED_REGISTERS
	ret

; args
;	(xmm0) the single precision floating-point number
;	(rdi) beginning of the buffer where the string will be placed
;	(rsi) address of the byte after the last buffer's byte
; returns
;	(rax) number of characters written
;
; NOTE: the resulting string is not null-terminated.
;
flt2str:
	;
	; this is a rather rudimentary function, since it doesn't round 
	; correctly or deal with proper formatting. Still works though.
	;
	; TODO: NaN, infinities.
	;
	PUSH_CALLEE_SAVED_REGISTERS
	mov rbp, rsp
	and rsp, -16
	sub rsp, 16

	mov rbx, rdi
	mov r12, rsi
	movss [rsp+12], xmm0
	mov r13, rbx	; address after the last written character
	xor r14, r14	; integer part of the float
	xor r15, r15	; fraction part, multiplied by 10^precision

	cmp r12, rbx
	jle .quit

	mov eax, dword [rsp+12]
	cmp eax, 0
	je .zero
	and eax, 0x80000000	; exctract the sign bit
	cmp eax, 0
	je .pos

	mov byte [r13], '-'
	inc r13
	cmp r12, r13
	jle .numTooLarge
	movss xmm0, [rsp+12]
	mulss xmm0, [fminus1]
	movss [rsp+12], xmm0
.pos:
	stmxcsr [rsp+8]
	mov eax, dword [rsp+8]
	or eax, MXCSR_TRUNCATE_MASK
	mov [rsp+4], eax	; ldmxscr only accepts memory locations
	ldmxcsr [rsp+4]
	cvtss2si r14, [rsp+12]
	ldmxcsr [rsp+8]

	mov rdi, r13
	mov rsi, r12
	mov rdx, r14
	call uint2str
	add r13, rax

	mov byte [r13], '.'
	inc r13
	cmp r12, r13
	jle .numTooLarge

	movss xmm0, [rsp+12]
	cvtsi2ss xmm1, r14
	subss xmm0, xmm1	; xmm0 now holds the fraction part

	mov rcx, FLT_DIG
.loop1:
	mulss xmm0, [f10]
	dec rcx
	cmp rcx, 0
	jg .loop1
	cvtss2si r15, xmm0

	; 0s after the dot and before the first non-zero digit
	mov rdi, r15
	call digcount
	mov rcx, rax
	neg rcx
	add rcx, FLT_DIG
.loop2:
	cmp rcx, 0
	jle .after0s

	mov byte [r13], '0'
	inc r13
	cmp r12, r13
	jle .numTooLarge

	dec rcx
	jmp .loop2

.after0s:
	mov rdi, r13
	mov rsi, r12
	mov rdx, r15
	call uint2str
	add r13, rax
	jmp .quit
.zero:
	mov byte [r13], '0'
	inc r13
	cmp r12, r13
	jle .numTooLarge
	jmp .quit

.numTooLarge:
	call numTooLarge
.quit:
	mov rax, r13
	sub rax, rbx

	mov rsp, rbp
	POP_CALLEE_SAVED_REGISTERS
	ret

; args
;	(rdi) beginning of the buffer where the string will be placed
;	(rsi) address of the byte after the last buffer byte
;	(rdx) the unsigned integer
; returns
;	(rax) number of characters written
;
; NOTE: the resulting string is not null-terminated.
uint2str:
	PUSH_CALLEE_SAVED_REGISTERS
	mov rbx, rdi
	mov r12, rsi
	mov r13, rdx
	xor r14, r14	; number of decimal digits
	xor r15, r15	; return value

	; We must know the number of digits beforehand because we must start
	; writing the number from the last (rightmost) position to the first.
	; The disavantage is we must do a similar procedure twice (dividing
	; the number by 10 repeatedly)
	mov rdi, r13
	call digcount
	mov r14, rax

	lea rcx, [rbx+r14]
	cmp r12, rcx
	jle .numTooLarge

	dec r14	; with n digits, we must go from [rbx+n-1] to [rbx]

	; we assume rax and rcx will not be manually changed in .loop.
	mov rax, r13
	mov rcx, 10
.loop:
	; edx = dividend's upper bits. We need this instruction inside
	; this loop, because the remainder of the division is stored in edx.
	xor rdx, rdx
	div rcx
	add dl, '0'	; remainder is < 10, thus it fits in a byte
	mov byte [rbx+r14], dl
	inc r15

	dec r14
	cmp r14, 0
	jge .loop

	jmp .quit

.numTooLarge:
	call numTooLarge
.quit:
	mov rax, r15
	POP_CALLEE_SAVED_REGISTERS
	ret

; (leaf)
; args
;	(rdi) an unsigned integer
; returns
;	(rax) the amount of decimal digits in that number (minimum 1)
digcount:
	mov rax, rdi
	mov rcx, 10
	xor r8, r8
.loop:
	; edx = dividend's upper bits. We need this instruction inside
	; this loop, because the remainder of the division is stored in edx.
	xor rdx, rdx
	div rcx
	inc r8
	cmp rax, 0
	jg .loop

	mov rax, r8
	ret

; (leaf)
; args
;	(rdi) address of first token's first char
;	(rsi) size of first token, in chars (minimum 1)
;	(rdx) address of second token's first char
;	(rcx) size of second token, in chars (minimum 1)
; returns
;	(rax) 1 if tokens are equal, 0 otherwise
tokeq:
	xor rax, rax

	; prelimary check to save time.
	cmp rsi, rcx
	jne .quit

	xor r8, r8
.loop:
	; we're sure that rsi == rcx, so rcx is free to use
	mov cl, byte [rdi+r8]
	cmp cl, byte [rdx+r8]
	jne .quit

	inc r8
	cmp r8, rsi
	jge .equal
	; not needed, since we're sure that rsi == rcx
	;cmp r8, rcx
	;jge .equal

	jmp .loop
.equal:
	mov rax, 1
.quit:
	ret

; (leaf)
; args
;	(rdi) address of the first char of a NULL-TERMINATED string
; returns
;	(rax) address of the null-terminator
;
; NOTE: most strings/tokens used in this program are NOT null-terminated!
; Use this only with the program's command-line arguments!
;
strend:
	mov rax, rdi
.loop:
	cmp byte [rax], 0
	je .quit
	inc rax
	jmp .loop
.quit:
	ret

; below, there is a function for each type of error; they all recieve nothing
; and return nothing (in fact, they don't even return).
invalidToken:
	mov rdi, ERR_INVALID_TOKEN
	mov rsi, msgInvalidToken
	mov rdx, msgInvalidTokenSiz
	call lastwords
	ret
overflow:
	mov rdi, ERR_OVERFLOW
	mov rsi, msgOverflow
	mov rdx, msgOverflowSiz
	call lastwords
	ret
numStackOverflow:
	mov rdi, ERR_NUM_STACK_OVERFLOW
	mov rsi, msgNumStackOverflow
	mov rdx, msgNumStackOverflowSiz
	call lastwords
	ret
numStackUnderflow:
	mov rdi, ERR_NUM_STACK_UNDERFLOW
	mov rsi, msgNumStackUnderflow
	mov rdx, msgNumStackUnderflowSiz
	call lastwords
	ret
numTooLarge:
	mov rdi, ERR_NUM_TOO_LARGE
	mov rsi, msgNumTooLarge
	mov rdx, msgNumTooLargeSiz
	call lastwords
	ret
tooManyNumbers:
	mov rdi, ERR_TOO_MANY_NUMBERS
	mov rsi, msgTooManyNumbers
	mov rdx, msgTooManyNumbersSiz
	call lastwords
	ret

; (why care about callee-saved registers when death is imminent?)
; args
;	(rdi) error code
;	(rsi) starting address of the error message
;	(rdx) error message size
lastwords:
	mov r8, rdi

	mov rax, SYS_WRITE
	mov rdi, STDERR
	; rsi is ready
	; rdx is ready
	syscall

	mov rdi, r8
	call death
	ret ; won't happen

; args
;	(rdi) error code
; returns
;	The dust of a process which shall be mourned by its loved ones
death:
	; rdi is ready
	mov rax, SYS_EXIT
	syscall

; vim: set ft=nasm :
