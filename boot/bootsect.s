;
; SYS_SIZE is the number of clicks (16 bytes) to be loaded.
; 0x3000 is 0x30000 bytes = 196kB, more than enough for current
; versions of linux
;
SYSSIZE = 0x3000
;
;	bootsect.s		(C) 1991 Linus Torvalds
;
; bootsect.s is loaded at 0x7c00 by the bios-startup routines, and moves
; iself out of the way to address 0x90000, and jumps there.
;
; It then loads 'setup' directly after itself (0x90200), and the system
; at 0x10000, using BIOS interrupts. 
;
; NOTE; currently system is at most 8*65536 bytes long. This should be no
; problem, even in the future. I want to keep it simple. This 512 kB
; kernel size should be enough, especially as this doesn't contain the
; buffer cache as in minix
;
; The loader has been made as simple as possible, and continuos
; read errors will result in a unbreakable loop. Reboot by hand. It
; loads pretty fast by getting whole sectors at a time whenever possible.

/*
 * .text 等是伪操作符，告诉编译器产生文本段，.text 用于标识文本段的开始位置。
 * 此处的.text、.data、.bss表明这3个段重叠，不分段！
 */
.globl begtext, begdata, begbss, endtext, enddata, endbss
.text // 文本段
begtext:
.data // 数据段
begdata:
.bss // 未初始化数据段
begbss:
.text

SETUPLEN = 4				; nr of setup-sectors
BOOTSEG  = 0x07c0			; original address of boot-sector
INITSEG  = 0x9000			; we move boot here - out of the way
SETUPSEG = 0x9020			; setup starts here
SYSSEG   = 0x1000			; system loaded at 0x10000 (65536).
ENDSEG   = SYSSEG + SYSSIZE		; where to stop loading

; ROOT_DEV:	0x000 - same type of floppy as boot.
;		0x301 - first partition on first drive etc
ROOT_DEV = 0x306

entry start // 关键字 entry 告诉链接器"程序入口"
start:
	mov	ax,#BOOTSEG
	mov	ds,ax // 此条语句就是 0x7c00 处存放的语句！
	mov	ax,#INITSEG
	mov	es,ax
	mov	cx,#256
	sub	si,si // 等价于 sub a,b --> a = a - b，即 si = si - si, 就是把 si 清零
	sub	di,di
	rep
	movw // 从 ds:si 处复制到 es:di 处，即将 0x7c00:0x0000 处的 256 个字移动到 0x9000:0x0000 处
	jmpi	go,INITSEG
go:	mov	ax,cs // cs=0x9000
	mov	ds,ax
	mov	es,ax
; put stack at 0x9ff00.
	mov	ss,ax
	mov	sp,#0xFF00		; arbitrary value >>512 // 为 call 做准备

; load the setup-sectors directly after the bootblock.
; Note that 'es' is already set up.

load_setup: // 载入 setup 模块
	mov	dx,#0x0000		; drive 0, head 0
	mov	cx,#0x0002		; sector 2, track 0
	mov	bx,#0x0200		; address = 512, in INITSEG
	mov	ax,#0x0200+SETUPLEN	; service 2, nr of sectors
	int	0x13			; read it // BIOS 中断【0x13是BIOS读磁盘扇区的中断: ah=0x02-读磁盘，al=扇区数量（SETUPLEN=4），ch=柱面号，cl=开始扇区，dh=磁头号，dl=驱动器号，es:bx=内存地址】
	jnc	ok_load_setup		; ok - continue // 跳转到 ok_load_setup
	mov	dx,#0x0000
	mov	ax,#0x0000		; reset the diskette // 复位
	int	0x13
	j	load_setup // 重读

ok_load_setup: // 载入 setup 模块

; Get disk drive parameters, specifically nr of sectors/track

	mov	dl,#0x00
	mov	ax,#0x0800		; AH=8 is get drive parameters // ah=8 获得磁盘参数
	int	0x13
	mov	ch,#0x00
	seg cs
	mov	sectors,cx
	mov	ax,#INITSEG
	mov	es,ax

; Print some inane message

	mov	ah,#0x03		; read cursor pos
	xor	bh,bh
	int	0x10 // 读光标
	
	mov	cx,#24
	mov	bx,#0x0007		; page 0, attribute 7 (normal)
	mov	bp,#msg1
	mov	ax,#0x1301		; write string, move cursor
	int	0x10 // 显示字符

; ok, we've written the message, now
; we want to load the system (at 0x10000)

	mov	ax,#SYSSEG // SYSSEG=0x1000
	mov	es,ax		; segment of 0x010000
	call	read_it // 读入 system 模块
	call	kill_motor

; After that we check which root-device to use. If the device is
; defined (!= 0), nothing is done and the given device is used.
; Otherwise, either /dev/PS0 (2,28) or /dev/at0 (2,8), depending
; on the number of sectors that the BIOS reports currently.

	seg cs
	mov	ax,root_dev
	cmp	ax,#0
	jne	root_defined
	seg cs
	mov	bx,sectors
	mov	ax,#0x0208		; /dev/ps0 - 1.2Mb
	cmp	bx,#15
	je	root_defined
	mov	ax,#0x021c		; /dev/PS0 - 1.44Mb
	cmp	bx,#18
	je	root_defined
undef_root:
	jmp undef_root
root_defined:
	seg cs
	mov	root_dev,ax

; after that (everyting loaded), we jump to
; the setup-routine loaded directly after
; the bootblock:

	jmpi	0,SETUPSEG // 转入 0x9020:0x0000 执行 setup.s

; This routine loads the system at address 0x10000, making sure
; no 64kB boundaries are crossed. We try to load it as fast as
; possible, loading whole tracks whenever we can.
;
; in:	es - starting address segment (normally 0x1000)
;
sread:	.word 1+SETUPLEN	; sectors read of current track
head:	.word 0			; current head
track:	.word 0			; current track

read_it:
	mov ax,es
	test ax,#0x0fff
die:	jne die			; es must be at 64kB boundary
	xor bx,bx		; bx is starting address within segment
rp_read:
	mov ax,es
	cmp ax,#ENDSEG		; have we loaded all yet?
	jb ok1_read
	ret
ok1_read:
	seg cs
	mov ax,sectors
	sub ax,sread // sread 是当前磁道已读扇区数，ax 未读扇区数
	mov cx,ax
	shl cx,#9
	add cx,bx
	jnc ok2_read
	je ok2_read
	xor ax,ax
	sub ax,bx
	shr ax,#9
ok2_read:
	call read_track // 读磁道...
	mov cx,ax
	add ax,sread
	seg cs
	cmp ax,sectors
	jne ok3_read
	mov ax,#1
	sub ax,head
	jne ok4_read
	inc track
ok4_read:
	mov head,ax
	xor ax,ax
ok3_read:
	mov sread,ax
	shl cx,#9
	add bx,cx
	jnc rp_read
	mov ax,es
	add ax,#0x1000
	mov es,ax
	xor bx,bx
	jmp rp_read

read_track:
	push ax
	push bx
	push cx
	push dx
	mov dx,track
	mov cx,sread
	inc cx
	mov ch,dl
	mov dx,head
	mov dh,dl
	mov dl,#0
	and dx,#0x0100
	mov ah,#2
	int 0x13
	jc bad_rt
	pop dx
	pop cx
	pop bx
	pop ax
	ret
bad_rt:	mov ax,#0
	mov dx,#0
	int 0x13
	pop dx
	pop cx
	pop bx
	pop ax
	jmp read_track

/*
 * This procedure turns off the floppy drive motor, so
 * that we enter the kernel in a known state, and
 * don't have to worry about it later.
 */
kill_motor:
	push dx
	mov dx,#0x3f2
	mov al,#0
	outb
	pop dx
	ret

sectors:
	.word 0

msg1:
	.byte 13,10
	.ascii "Loading system ..."
	.byte 13,10,13,10

.org 508
root_dev:
	.word ROOT_DEV
boot_flag:
	.word 0xAA55 // 扇区的最后两个字节

.text
endtext:
.data
enddata:
.bss
endbss:
