; ============================================================
;  SWITCHYARD  -  COAL project, BSSE 3B, Fall 2026
;  Intel 8086, real mode, DOS .COM program, NASM syntax
;
;  Build :  nasm -f bin main.asm -o switchyard.com
;  Run   :  switchyard.com        (DOSBox)
; ============================================================

[bits 16]
[org 0x100]
cpu 8086                        ; NASM rejects any non-8086 instruction

        jmp  start

; ===== constants.inc =====
; ============================================================
;  constants.inc  -  all equates for SwitchYard
; ============================================================

VIDSEG          equ 0xB800      ; colour text-mode video memory

; ---------- game rules ----------
MAXT            equ 8           ; trains that can be on screen (power of 2)
MAXMIST         equ 5           ; mistakes that lose the game
WIN_SINGLE      equ 10
WIN_COOP        equ 20
SPEED_SINGLE    equ 6           ; deliveries that trigger the one-time speed-up
SPEED_COOP      equ 12
INIT_INTERVAL   equ 6           ; movement interval in timer ticks (18.2 / sec)
SPAWN_BASE      equ 36          ; min ticks between spawns (+ random 0..31)
BANNER_TICKS    equ 54          ; how long the speed-up banner stays (~3 s)

; ---------- game states ----------
GS_PLAY         equ 0
GS_WIN          equ 1
GS_LOSE         equ 2
GS_ABORT        equ 3

; ---------- CP437 line-drawing glyphs ----------
G_H             equ 0xC4        ; horizontal rail
G_V             equ 0xB3        ; vertical rail
G_DR            equ 0xDA        ; corner: down + right
G_UR            equ 0xC0        ; corner: up + right
G_TEE           equ 0xC3        ; junction: vertical with exit right

; ---------- colour attributes (background<<4 | foreground) ----------
ATTR_TRK        equ 0x03        ; rail: cyan on black
ATTR_SEL        equ 0x0A        ; selected branch: bright green
ATTR_UNSEL      equ 0x08        ; unselected branch: dark grey
ATTR_SW         equ 0x6F        ; switch box: white on brown
ATTR_A          equ 0x1F        ; station/train A: white on blue
ATTR_B          equ 0x2F        ; B: white on green
ATTR_C          equ 0x4F        ; C: white on red
ATTR_D          equ 0x5F        ; D: white on magenta
ATTR_TITLE      equ 0x1F
ATTR_LABEL      equ 0x07
ATTR_HUD        equ 0x0B
ATTR_HUDV       equ 0x0F
ATTR_PANEL      equ 0x0E
ATTR_DIM        equ 0x08

; ---------- keyboard scan codes (make codes) ----------
SC_ESC          equ 0x01
SC_1            equ 0x02
SC_2            equ 0x03
SC_3            equ 0x04
SC_4            equ 0x05
SC_R            equ 0x13
SC_ENTER        equ 0x1C
SC_J            equ 0x24
SC_K            equ 0x25
SC_M            equ 0x32
SC_UP           equ 0x48
SC_DOWN         equ 0x50

; ---------- screen layout ----------
PANEL_COL       equ 63          ; right-hand information panel

; ===== data.asm =====
; ============================================================
;  data.asm  -  variables, tables and strings
; ============================================================

; ---------- saved interrupt vectors (offset, segment) ----------
old8:           dw 0, 0         ; original INT 8  (timer)
old9:           dw 0, 0         ; original INT 9  (keyboard)

; ---------- interrupt-driven state ----------
ticks:          dw 0            ; incremented by the timer ISR
lasttick:       dw 0            ; last tick the main loop has processed
kbuf:           times 16 db 0   ; circular key queue
khead:          dw 0
ktail:          dw 0
kdown:          times 128 db 0  ; 1 = key currently held (kills auto-repeat)

; ---------- general ----------
seed:           dw 0x1234
gmode:          db 0            ; 0 = single player, 1 = co-op, 2 = exit
gstate:         db GS_PLAY
sel:            db 0            ; highlighted menu item
pattr:          db 0x0F         ; attribute used by print_dec2
fl:             db 0            ; draw_frame scratch
ft:             db 0
fr:             db 0
fb:             db 0

; ---------- game counters (set by reset_game) ----------
score:          db 0
mistakes:       db 0
winat:          db WIN_SINGLE
speedat:        db SPEED_SINGLE
speeded:        db 0
interval:       db INIT_INTERVAL
spawn_cnt:      db 0
spawn_delay:    db SPAWN_BASE
rot:            db 0
banner_on:      db 0
banner_until:   dw 0

; ---------- block zeroed by reset_game ----------
rt_start:
sw:             times 4 db 0            ; switch states
t_act:          times MAXT db 0         ; train slot in use
t_pos:          times MAXT db 0         ; cell index
t_dest:         times MAXT db 0         ; destination letter
t_int:          times MAXT db 0         ; this train's movement interval
t_cnt:          times MAXT db 0         ; ticks since its last move
t_new:          times MAXT db 0         ; cell it has been granted
t_mov:          times MAXT db 0         ; 1 = moves in this update
occ:            times 256 db 0          ; cell -> train slot+1 (0 = empty)
claim:          times 256 db 0          ; cells claimed in this update
rt_end:
RT_LEN          equ rt_end - rt_start

; ---------- colour of each destination letter ----------
lettattr:       db ATTR_A, ATTR_B, ATTR_C, ATTR_D

; ---------- switch panel text (all 16 chars wide) ----------
swstr:          dw S1_0, S1_1, S2_0, S2_1, S3_0, S3_1, S4_0, S4_1
S1_0:           db '1 ^ Direct to A ',0
S1_1:           db '1 v Shared track',0
S2_0:           db '2 v Direct to D ',0
S2_1:           db '2 ^ Shared track',0
S3_0:           db '3 ^ Exit to B   ',0
S3_1:           db '3 > Continue    ',0
S4_0:           db '4 > Station C   ',0
S4_1:           db '4 v Station D   ',0

; ---------- game screen strings ----------
s_title:        db 'S W I T C H Y A R D',0
s_single:       db 'SINGLE PLAYER',0
s_coop:         db 'CO-OP  2 PLAYERS',0
s_score:        db 'SCORE',0
s_mist:         db 'MISTAKES',0
s_time:         db 'TIME',0
s_speed:        db 'SPEED x',0
s_entry1:       db 'ENTRY 1',0
s_entry2:       db 'ENTRY 2',0
s_lbl_a:        db 'Direct route to A',0
s_lbl_b:        db 'Exit to B',0
s_lbl_sh:       db 'Shared track',0
s_lbl_d:        db 'Direct route to D',0
s_stations:     db 'STATIONS',0
s_sw:           db 'SWITCHES',0
s_ctrl:         db 'CONTROLS',0
s_ctrl_s1:      db 'Keys 1 2 3 4',0
s_ctrl_s2:      db 'flip switches',0
s_ctrl_c1:      db 'P1: keys 1 2',0
s_ctrl_c2:      db 'P2: keys J K',0
s_esc:          db 'ESC = menu',0
s_how:          db 'HOW TO PLAY',0
s_how1:         db 'Train letter is',0
s_how2:         db 'its destination',0
s_how3:         db 'Right: +1 point',0
s_how4:         db 'Wrong: mistake!',0
s_banner:       db '>>> SPEED UP!  All trains now move twice as fast <<<',0
s_clear_banner: db '                                                      ',0

; ---------- menu strings (all 26 wide so the bar is even) ----------
m_title:        db '  S W I T C H Y A R D  ',0
m_sub:          db 'Route every train to its station!',0
m_item0:        db '   1.  SINGLE PLAYER      ',0
m_item1:        db '   2.  TWO-PLAYER CO-OP   ',0
m_item2:        db '  ESC. EXIT TO DOS        ',0
m_h1:           db 'Single : keys 1 2 3 4 flip switches 1-4',0
m_h2:           db 'Co-op  : P1 keys 1 2     P2 keys J K',0
m_h3:           db 'Win: 10 correct (20 co-op)  Lose: 5 mistakes',0
m_h4:           db 'UP / DOWN + ENTER,  or press 1 / 2 / ESC',0

; ---------- end screen strings ----------
e_win:          db '*** YOU WIN! ***',0
e_lose:         db '*** GAME OVER ***',0
e_score:        db 'Score    :',0
e_mist:         db 'Mistakes :',0
e_time:         db 'Time     :',0
e_keys:         db 'R = Replay    M = Menu    ESC = Exit',0

; ===== map.asm =====
; ============================================================
;  map.asm  -  the fixed track, stored as a table of CELLS
;
;  One record (8 bytes) per track cell:
;     +0 col     +1 row     +2 glyph   +3 type
;     +4 next0   +5 next1   +6 attr    +7 (pad)
;  type : 0      = plain rail
;         1..4   = switch number
;         'A'..'D' = station (train is removed on arrival)
;  next0 : cell reached normally / when switch state = 0
;  next1 : cell reached when switch state = 1 (switches only)
;
;  Switch states:  SW1 0=Direct A     1=Shared track
;                  SW2 0=Direct D     1=Shared track
;                  SW3 0=Exit to B    1=Continue to SW4
;                  SW4 0=Station C    1=Station D
;
;  The macros below generate the table at assembly time, so the
;  cell numbers (indices) are computed by NASM, never by hand.
; ============================================================

%assign CELLN 0
%define IDX(l) (((l) - celltab) / 8)

%macro CELLDEF 7                ; col,row,glyph,type,next0,next1,attr
        db %1, %2, %3, %4, %5, %6, %7, 0
        %assign CELLN CELLN+1
%endmacro

%macro RUN 8                    ; col,row,dx,dy,count,glyph,attr,nextAfterLast
        %assign _i 0
        %rep %5
          %if _i == %5 - 1
                CELLDEF %1+_i*%3, %2+_i*%4, %6, 0, %8, 0xFF, %7
          %else
                CELLDEF %1+_i*%3, %2+_i*%4, %6, 0, CELLN+1, 0xFF, %7
          %endif
          %assign _i _i+1
        %endrep
%endmacro

%macro SWC 5                    ; col,row,number,next0,next1
        CELLDEF %1, %2, '0'+%3, %3, %4, %5, ATTR_SW
%endmacro

%macro STN 4                    ; col,row,letter,attr
        CELLDEF %1, %2, %3, %3, 0xFF, 0xFF, %4
%endmacro

celltab:
; ---- Entry 1 -> switch 1 -> Direct A route ----
e1_h:   RUN  8, 7, 1, 0,  6, G_H,  ATTR_TRK, IDX(sw1c)
sw1c:   SWC 14, 7, 1, IDX(a_v), IDX(j_v1)
a_v:    RUN 14, 6, 0,-1,  2, G_V,  ATTR_TRK, IDX(a_c)
a_c:    RUN 14, 4, 0, 0,  1, G_DR, ATTR_TRK, IDX(a_h)
a_h:    RUN 15, 4, 1, 0, 45, G_H,  ATTR_TRK, IDX(st_a)
st_a:   STN 60, 4, 'A', ATTR_A
; ---- from switch 1 down to the junction ----
j_v1:   RUN 14, 8, 0, 1,  2, G_V,  ATTR_TRK, IDX(jn)
jn:     RUN 14,10, 0, 0,  1, G_TEE,ATTR_TRK, IDX(sh1)
; ---- shared track, switch 3, switch 4 ----
sh1:    RUN 15,10, 1, 0, 15, G_H,  ATTR_TRK, IDX(sw3c)
sw3c:   SWC 30,10, 3, IDX(b_v), IDX(sh2)
sh2:    RUN 31,10, 1, 0, 15, G_H,  ATTR_TRK, IDX(sw4c)
sw4c:   SWC 46,10, 4, IDX(c_h), IDX(d_v)
c_h:    RUN 47,10, 1, 0, 13, G_H,  ATTR_TRK, IDX(st_c)
st_c:   STN 60,10, 'C', ATTR_C
d_v:    RUN 46,11, 0, 1,  1, G_V,  ATTR_TRK, IDX(d_c)
d_c:    RUN 46,12, 0, 0,  1, G_UR, ATTR_TRK, IDX(d_h)
d_h:    RUN 47,12, 1, 0, 13, G_H,  ATTR_TRK, IDX(st_d1)
st_d1:  STN 60,12, 'D', ATTR_D
; ---- exit to B (from switch 3) ----
b_v:    RUN 30, 9, 0,-1,  2, G_V,  ATTR_TRK, IDX(b_c)
b_c:    RUN 30, 7, 0, 0,  1, G_DR, ATTR_TRK, IDX(b_h)
b_h:    RUN 31, 7, 1, 0, 29, G_H,  ATTR_TRK, IDX(st_b)
st_b:   STN 60, 7, 'B', ATTR_B
; ---- Entry 2 -> switch 2 -> Direct D route / up to the junction ----
e2_h:   RUN  8,13, 1, 0,  6, G_H,  ATTR_TRK, IDX(sw2c)
sw2c:   SWC 14,13, 2, IDX(dd_v), IDX(u_v)
dd_v:   RUN 14,14, 0, 1,  2, G_V,  ATTR_TRK, IDX(dd_c)
dd_c:   RUN 14,16, 0, 0,  1, G_UR, ATTR_TRK, IDX(dd_h)
dd_h:   RUN 15,16, 1, 0, 45, G_H,  ATTR_TRK, IDX(st_d2)
st_d2:  STN 60,16, 'D', ATTR_D
u_v:    RUN 14,12, 0,-1,  2, G_V,  ATTR_TRK, IDX(jn)
celltab_end:

NCELLS  equ CELLN

; indices of the two entrances and the four switch cells
entr_cell:  db IDX(e1_h), IDX(e2_h)
entr_mask:  db 0x0F, 0x0E       ; reachable stations (bit0=A..bit3=D)
swcell:     db IDX(sw1c), IDX(sw2c), IDX(sw3c), IDX(sw4c)

; ===== video.asm =====
; ============================================================
;  video.asm  -  direct video-memory routines (segment 0xB800)
;  ES must hold VIDSEG whenever these are called.
;  Each text cell is 2 bytes: character, then attribute.
; ============================================================

; ---- BIOS helpers (INT 10h) ----
set_mode3:                      ; 80x25 colour text, clears screen
        mov  ax, 0x0003
        int  0x10
        mov  ax, VIDSEG
        mov  es, ax
        ret

hide_cursor:
        mov  ah, 1
        mov  cx, 0x2000
        int  0x10
        ret

; ---- clear_screen : fill all 2000 cells with a black-on-grey space ----
clear_screen:
        push ax
        push cx
        push di
        xor  di, di
        mov  cx, 2000
        mov  ax, 0x0720
        cld
        rep  stosw
        pop  di
        pop  cx
        pop  ax
        ret

; ---- putc : AL = char, AH = attr, DL = col, DH = row ----
;      offset = (row*80 + col) * 2   (all registers preserved)
putc:
        push bx
        push di
        push ax
        mov  al, 80
        mul  dh                 ; AX = row * 80
        xor  bh, bh
        mov  bl, dl
        add  ax, bx             ; + col
        shl  ax, 1              ; * 2 bytes per cell
        mov  di, ax
        pop  ax
        mov  [es:di], ax        ; char + attribute in one word write
        pop  di
        pop  bx
        ret

; ---- puts : SI = zero-terminated string, AH = attr, DL/DH = start ----
puts:
        push ax
        push dx
        push si
.next:  lodsb
        or   al, al
        jz   .done
        call putc
        inc  dl
        jmp  .next
.done:  pop  si
        pop  dx
        pop  ax
        ret

; ---- fill_rect : AX = char/attr, DL/DH = top-left, CL = width, CH = height ----
fill_rect:
        push bx
        push cx
        push dx
        mov  bl, dl
.row:   push cx
        xor  ch, ch
        mov  dl, bl
.col:   call putc
        inc  dl
        loop .col
        pop  cx
        inc  dh
        dec  ch
        jnz  .row
        pop  dx
        pop  cx
        pop  bx
        ret

; ---- draw_frame : double-line box.  AH = attr, DL/DH = top-left, CL = w, CH = h ----
draw_frame:
        push ax
        push dx
        mov  [fl], dl
        mov  [ft], dh
        add  dl, cl
        dec  dl
        mov  [fr], dl
        add  dh, ch
        dec  dh
        mov  [fb], dh
        mov  al, 0xC9           ; corners
        mov  dl, [fl]
        mov  dh, [ft]
        call putc
        mov  al, 0xBB
        mov  dl, [fr]
        call putc
        mov  al, 0xBC
        mov  dh, [fb]
        call putc
        mov  al, 0xC8
        mov  dl, [fl]
        call putc
        mov  dl, [fl]           ; top and bottom edges
.h:     inc  dl
        cmp  dl, [fr]
        jae  .hd
        mov  al, 0xCD
        mov  dh, [ft]
        call putc
        mov  dh, [fb]
        call putc
        jmp  .h
.hd:    mov  dh, [ft]           ; left and right edges
.v:     inc  dh
        cmp  dh, [fb]
        jae  .vd
        mov  al, 0xBA
        mov  dl, [fl]
        call putc
        mov  dl, [fr]
        call putc
        jmp  .v
.vd:    pop  dx
        pop  ax
        ret

; ---- print_dec2 : AX = 0..99 (AH must be 0), DL/DH = position, attr = [pattr] ----
;      Converts with DIV by 10 exactly as taught in the book.
print_dec2:
        push ax
        push bx
        push dx
        mov  bl, 10
        div  bl                 ; AL = tens, AH = ones
        mov  bh, ah
        add  al, '0'
        mov  ah, [pattr]
        call putc
        inc  dl
        mov  al, bh
        add  al, '0'
        call putc
        pop  dx
        pop  bx
        pop  ax
        ret

; ===== random.asm =====
; ============================================================
;  random.asm  -  16-bit linear congruential generator
;      seed = seed * 25173 + 13849
; ============================================================

; ---- seed_rand : seed from the BIOS tick count (INT 1Ah) ----
seed_rand:
        push ax
        push cx
        push dx
        mov  ah, 0
        int  0x1A               ; CX:DX = ticks since midnight
        mov  [seed], dx
        xor  [seed], cx
        or   word [seed], 1
        pop  dx
        pop  cx
        pop  ax
        ret

; ---- rand : returns AL = pseudo-random byte (high byte of the seed) ----
rand:
        push dx
        mov  ax, [seed]
        mov  dx, 25173
        mul  dx
        add  ax, 13849
        mov  [seed], ax
        mov  al, ah
        pop  dx
        ret

; ===== timer.asm =====
; ============================================================
;  timer.asm  -  hook / restore INT 8 (IRQ0, ~18.2 Hz)
;  Hooking method is the one from the book (chapter 8/9):
;  write offset+segment into the IVT at  n*4  with interrupts off.
; ============================================================

hook_timer:
        push ax
        push es
        xor  ax, ax
        mov  es, ax                     ; ES -> interrupt vector table
        mov  ax, [es:8*4]               ; save the original vector
        mov  [old8], ax
        mov  ax, [es:8*4+2]
        mov  [old8+2], ax
        cli
        mov  word [es:8*4], timer_isr
        mov  [es:8*4+2], cs
        sti
        pop  es
        pop  ax
        ret

unhook_timer:
        push ax
        push es
        xor  ax, ax
        mov  es, ax
        cli
        mov  ax, [old8]
        mov  [es:8*4], ax
        mov  ax, [old8+2]
        mov  [es:8*4+2], ax
        sti
        pop  es
        pop  ax
        ret

; ---- the ISR: count the tick, then chain to the BIOS handler ----
;      (the BIOS handler keeps the DOS clock correct and sends the EOI)
timer_isr:
        inc  word [cs:ticks]
        jmp  far [cs:old8]

; ===== keyboard.asm =====
; ============================================================
;  keyboard.asm  -  INT 9 hook, key queue, in-game key handling
; ============================================================

hook_keyboard:
        push ax
        push es
        xor  ax, ax
        mov  es, ax
        mov  ax, [es:9*4]
        mov  [old9], ax
        mov  ax, [es:9*4+2]
        mov  [old9+2], ax
        cli
        mov  word [es:9*4], kb_isr
        mov  [es:9*4+2], cs
        sti
        pop  es
        pop  ax
        ret

unhook_keyboard:
        push ax
        push es
        xor  ax, ax
        mov  es, ax
        cli
        mov  ax, [old9]
        mov  [es:9*4], ax
        mov  ax, [old9+2]
        mov  [es:9*4+2], ax
        sti
        pop  es
        pop  ax
        ret

; ---- INT 9 service routine ----
;  Reads the scan code from port 0x60.  Bit 7 set = key RELEASE.
;  A key that is already held (typematic repeat) is ignored, so
;  holding a key flips a switch only once.  New presses go into
;  a 16-byte circular queue.
kb_isr:
        push ax
        push bx
        in   al, 0x60
        mov  bl, al
        and  bl, 0x7F
        xor  bh, bh                     ; BX = scan code without bit 7
        test al, 0x80
        jz   .press
        mov  byte [cs:kdown+bx], 0      ; release: forget the key
        jmp  short .eoi
.press: cmp  byte [cs:kdown+bx], 0
        jne  .eoi                       ; repeat while held: ignore
        mov  byte [cs:kdown+bx], 1
        mov  bx, [cs:ktail]
        mov  [cs:kbuf+bx], al
        inc  bx
        and  bx, 15
        cmp  bx, [cs:khead]
        je   .eoi                       ; queue full: drop the key
        mov  [cs:ktail], bx
.eoi:   mov  al, 0x20
        out  0x20, al                   ; end-of-interrupt to the PIC
        pop  bx
        pop  ax
        iret

; ---- kb_get : AL = next scan code from the queue, 0 if none ----
kb_get:
        push bx
        mov  bx, [khead]
        cmp  bx, [ktail]
        je   .empty
        mov  al, [kbuf+bx]
        inc  bx
        and  bx, 15
        mov  [khead], bx
        pop  bx
        ret
.empty: xor  al, al
        pop  bx
        ret

kb_flush:
        push ax
        cli
        mov  ax, [ktail]
        mov  [khead], ax
        sti
        pop  ax
        ret

; ---- kb_game : handle queued keys while playing ----
;  Single player : 1,2,3,4 -> switches 1..4
;  Co-op         : P1 = 1,2 -> switches 1,2     P2 = J,K -> switches 3,4
kb_game:
        push ax
        push bx
.n:     call kb_get
        or   al, al
        jz   .done
        cmp  al, SC_ESC
        jne  .k
        mov  byte [gstate], GS_ABORT
        jmp  short .done
.k:     cmp  byte [gmode], 0
        jne  .coop
        cmp  al, SC_1                   ; single player: scan codes 2..5
        jb   .n
        cmp  al, SC_4
        ja   .n
        sub  al, SC_1
        xor  ah, ah
        mov  bx, ax
        jmp  short .t
.coop:  xor  bx, bx
        cmp  al, SC_1
        je   .t
        inc  bx
        cmp  al, SC_2
        je   .t
        inc  bx
        cmp  al, SC_J
        je   .t
        inc  bx
        cmp  al, SC_K
        je   .t
        jmp  .n
.t:     xor  byte [sw+bx], 1            ; toggle the selected switch
        call draw_dynamic               ; show it immediately
        jmp  .n
.done:  pop  bx
        pop  ax
        ret

; ===== track.asm =====
; ============================================================
;  track.asm  -  cell lookup, drawing the track and switches
; ============================================================

; ---- get_cell : AL = cell index  ->  SI = address of its record ----
;      address = celltab + index*8   (clobbers AX)
get_cell:
        xor  ah, ah
        mov  si, ax
        shl  si, 1
        shl  si, 1
        shl  si, 1
        add  si, celltab
        ret

; ---- next_cell : AL = cell index -> AL = cell a train moves to next ----
;      A switch cell looks at the CURRENT switch state to pick next0/next1.
next_cell:
        push bx
        push si
        call get_cell
        mov  al, [si+3]                 ; cell type
        cmp  al, 1
        jb   .norm
        cmp  al, 4
        ja   .norm
        xor  ah, ah
        mov  bx, ax                     ; type 1..4
        mov  bl, [sw+bx-1]              ; state of that switch
        xor  bh, bh
        mov  al, [si+4+bx]              ; next0 or next1
        jmp  short .done
.norm:  mov  al, [si+4]
.done:  pop  si
        pop  bx
        ret

; ---- draw_cell : AL = index, BH = attr override (0 = use cell's own) ----
draw_cell:
        push ax
        push dx
        push si
        call get_cell
        mov  dl, [si]
        mov  dh, [si+1]
        mov  al, [si+2]
        mov  ah, bh
        or   ah, ah
        jnz  .go
        mov  ah, [si+6]
.go:    call putc
        pop  si
        pop  dx
        pop  ax
        ret

; ---- draw_track : redraw every cell ----
draw_track:
        push ax
        push bx
        push cx
        xor  bh, bh
        xor  al, al
        mov  cx, NCELLS
.l:     call draw_cell
        inc  al
        loop .l
        pop  cx
        pop  bx
        pop  ax
        ret

; ---- draw_branches : for each switch, light the chosen route ----
;      selected first cell = bright green, other = dark grey
draw_branches:
        push ax
        push bx
        push dx
        push si
        push di
        xor  di, di
.s:     mov  al, [swcell+di]
        call get_cell
        mov  dl, [si+4]                 ; next0
        mov  dh, [si+5]                 ; next1
        cmp  byte [sw+di], 0
        je   .a
        xchg dl, dh                     ; state 1: next1 is selected
.a:     mov  bh, ATTR_SEL
        mov  al, dl
        call draw_cell
        mov  bh, ATTR_UNSEL
        mov  al, dh
        call draw_cell
        inc  di
        cmp  di, 4
        jb   .s
        pop  di
        pop  si
        pop  dx
        pop  bx
        pop  ax
        ret

; ---- draw_panel : one line per switch showing where it points ----
draw_panel:
        push ax
        push bx
        push dx
        push si
        push di
        xor  di, di
.l:     mov  bl, [sw+di]
        xor  bh, bh
        mov  ax, di
        shl  ax, 1
        add  ax, bx                     ; 2*switch + state
        shl  ax, 1                      ; word index
        mov  bx, ax
        mov  si, [swstr+bx]
        mov  dl, PANEL_COL
        mov  ax, di
        add  al, 4
        mov  dh, al
        mov  ah, ATTR_PANEL
        call puts
        inc  di
        cmp  di, 4
        jb   .l
        pop  di
        pop  si
        pop  dx
        pop  bx
        pop  ax
        ret

; ---- draw_static : labels and panel text drawn once per game ----
draw_static:
        push ax
        push cx
        push dx
        push si
        ; title bar
        mov  ax, ATTR_TITLE*256 + ' '
        xor  dx, dx
        mov  cx, 80
        mov  ch, 1
        call fill_rect
        mov  si, s_title
        mov  dl, 30
        xor  dh, dh
        mov  ah, ATTR_TITLE
        call puts
        mov  si, s_single
        cmp  byte [gmode], 0
        je   .m
        mov  si, s_coop
.m:     mov  dl, 62
        xor  dh, dh
        call puts
        ; entrance + route labels
        mov  ah, ATTR_PANEL
        mov  si, s_entry1
        xor  dl, dl
        mov  dh, 7
        call puts
        mov  si, s_entry2
        mov  dh, 13
        call puts
        mov  ah, ATTR_DIM
        mov  si, s_lbl_a
        mov  dl, 22
        mov  dh, 3
        call puts
        mov  si, s_lbl_b
        mov  dl, 40
        mov  dh, 6
        call puts
        mov  si, s_lbl_sh
        mov  dl, 18
        mov  dh, 11
        call puts
        mov  si, s_lbl_d
        mov  dl, 22
        mov  dh, 17
        call puts
        mov  ah, ATTR_HUD
        mov  si, s_stations
        mov  dl, 56
        mov  dh, 2
        call puts
        ; right-hand panel
        mov  si, s_sw
        mov  dl, PANEL_COL
        mov  dh, 3
        call puts
        mov  si, s_ctrl
        mov  dh, 9
        call puts
        mov  ah, ATTR_LABEL
        cmp  byte [gmode], 0
        jne  .co
        mov  si, s_ctrl_s1
        mov  dh, 10
        call puts
        mov  si, s_ctrl_s2
        mov  dh, 11
        call puts
        jmp  short .c2
.co:    mov  si, s_ctrl_c1
        mov  dh, 10
        call puts
        mov  si, s_ctrl_c2
        mov  dh, 11
        call puts
.c2:    mov  si, s_esc
        mov  dh, 12
        call puts
        mov  ah, ATTR_HUD
        mov  si, s_how
        mov  dh, 14
        call puts
        mov  ah, ATTR_LABEL
        mov  si, s_how1
        mov  dh, 15
        call puts
        mov  si, s_how2
        mov  dh, 16
        call puts
        mov  si, s_how3
        mov  dh, 17
        call puts
        mov  si, s_how4
        mov  dh, 18
        call puts
        ; HUD labels (row 1)
        mov  ah, ATTR_HUD
        mov  si, s_score
        mov  dl, 1
        mov  dh, 1
        call puts
        mov  si, s_mist
        mov  dl, 15
        call puts
        mov  si, s_time
        mov  dl, 41
        call puts
        mov  si, s_speed
        mov  dl, 54
        call puts
        mov  al, '/'
        mov  ah, ATTR_HUD
        mov  dl, 9
        call putc
        mov  dl, 26
        call putc
        mov  al, ':'
        mov  dl, 48
        call putc
        pop  si
        pop  dx
        pop  cx
        pop  ax
        ret

; ===== train.asm =====
; ============================================================
;  train.asm  -  spawning, movement + collision rule, speed-up
; ============================================================

; ---- spawn_train : once per tick; creates a train when the timer is due ----
spawn_train:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        inc  byte [spawn_cnt]
        mov  al, [spawn_cnt]
        cmp  al, [spawn_delay]
        jae  $+5                        ; (long jump: jb .out is out of short range)
        jmp  .out
        call rand
        and  al, 1
        mov  bl, al                     ; random entrance 0/1
        xor  bh, bh
        mov  dl, [entr_cell+bx]
        xor  dh, dh
        mov  si, dx
        cmp  byte [occ+si], 0
        je   .free
        xor  bl, 1                      ; occupied: try the other entrance
        mov  dl, [entr_cell+bx]
        xor  dh, dh
        mov  si, dx
        cmp  byte [occ+si], 0
        jne  .out                       ; both busy: try again next tick
.free:  xor  di, di                     ; look for a free train slot
.f:     cmp  byte [t_act+di], 0
        je   .got
        inc  di
        cmp  di, MAXT
        jb   .f
        jmp  short .out
.got:   mov  byte [t_act+di], 1
        mov  [t_pos+di], dl
        mov  byte [t_mov+di], 0
        mov  byte [t_cnt+di], 0
        mov  ax, di
        inc  al
        mov  [occ+si], al               ; mark the entrance cell occupied
        mov  dh, [entr_mask+bx]         ; stations reachable from here
.pick:  call rand
        and  al, 3
        mov  cl, al
        mov  bl, 1
        shl  bl, cl                     ; bit for letter 0..3
        test bl, dh
        jz   .pick                      ; not reachable: pick again
        add  al, 'A'
        mov  [t_dest+di], al
        mov  al, [interval]             ; current (maybe halved) interval
        mov  [t_int+di], al
        mov  byte [spawn_cnt], 0
        call rand
        and  al, 31
        add  al, SPAWN_BASE
        mov  [spawn_delay], al
.out:   pop  di
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---- move_trains : one movement update ----
;  Phase 1 (decide): every train whose counter has expired asks for the
;     next cell.  It is granted only if occ[cell]==0 (empty at the START
;     of the update, because occ is not changed during this phase) and
;     claim[cell]==0 (no other train claimed it).  Otherwise it waits.
;  Phase 2 (commit): granted trains move, stations score/mistake.
move_trains:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        push cs
        pop  es                         ; ES=DS for STOSB
        mov  di, claim
        mov  cx, 256
        xor  al, al
        cld
        rep  stosb                      ; clear all claims
        pop  es
        ; ---- phase 1 ----
        mov  cx, MAXT
        mov  bl, [rot]                  ; rotating start = fair priority
.p1:    and  bl, MAXT-1
        xor  bh, bh
        cmp  byte [t_act+bx], 0
        je   .p1n
        mov  byte [t_mov+bx], 0
        inc  byte [t_cnt+bx]
        mov  al, [t_cnt+bx]
        cmp  al, [t_int+bx]
        jb   .p1n                       ; not its turn yet
        mov  byte [t_cnt+bx], 0
        mov  al, [t_pos+bx]
        call next_cell                  ; AL = wanted cell
        xor  ah, ah
        mov  si, ax
        cmp  byte [occ+si], 0
        jne  .p1n                       ; occupied at start of update
        cmp  byte [claim+si], 0
        jne  .p1n                       ; somebody else claimed it
        mov  byte [claim+si], 1
        mov  [t_new+bx], al
        mov  byte [t_mov+bx], 1
.p1n:   inc  bl
        loop .p1
        inc  byte [rot]
        ; ---- phase 2 ----
        xor  bx, bx
.p2:    cmp  byte [t_act+bx], 0
        je   .p2n
        cmp  byte [t_mov+bx], 0
        je   .p2n
        mov  byte [t_mov+bx], 0
        mov  al, [t_pos+bx]
        xor  ah, ah
        mov  si, ax
        mov  byte [occ+si], 0           ; leave the old cell
        mov  al, [t_new+bx]
        mov  [t_pos+bx], al
        call get_cell
        mov  dl, [si+3]                 ; type of the new cell
        cmp  dl, 'A'
        jb   .occupy                    ; ordinary cell or switch
        mov  byte [t_act+bx], 0         ; station: train is removed
        cmp  dl, [t_dest+bx]
        jne  .wrong
        inc  byte [score]               ; correct station
        jmp  short .p2n
.wrong: inc  byte [mistakes]            ; wrong station
        call beep
        jmp  short .p2n
.occupy:
        mov  al, [t_pos+bx]
        xor  ah, ah
        mov  si, ax
        mov  al, bl
        inc  al
        mov  [occ+si], al
.p2n:   inc  bx
        cmp  bx, MAXT
        jb   .p2
        pop  di
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---- apply_speedup : one-time halving of every interval ----
apply_speedup:
        push ax
        push bx
        mov  byte [speeded], 1
        xor  bx, bx
.l:     mov  al, [t_int+bx]
        shr  al, 1                      ; integer division by 2
        jnz  .ok
        mov  al, 1                      ; never below 1 tick
.ok:    mov  [t_int+bx], al
        inc  bx
        cmp  bx, MAXT
        jb   .l
        mov  al, [interval]             ; trains spawned later
        shr  al, 1
        jnz  .ok2
        mov  al, 1
.ok2:   mov  [interval], al
        mov  ax, [ticks]
        add  ax, BANNER_TICKS
        mov  [banner_until], ax
        mov  byte [banner_on], 1
        pop  bx
        pop  ax
        ret

; ---- draw_trains : letter of the destination on its station colour ----
draw_trains:
        push ax
        push bx
        push dx
        push si
        xor  bx, bx
.l:     cmp  byte [t_act+bx], 0
        je   .n
        mov  al, [t_pos+bx]
        call get_cell
        mov  dl, [si]
        mov  dh, [si+1]
        mov  al, [t_dest+bx]
        push bx
        mov  bl, al
        sub  bl, 'A'
        xor  bh, bh
        mov  ah, [lettattr+bx]
        pop  bx
        call putc
.n:     inc  bx
        cmp  bx, MAXT
        jb   .l
        pop  si
        pop  dx
        pop  bx
        pop  ax
        ret

; ---- beep : BEL through BIOS teletype (INT 10h AH=0Eh) ----
beep:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        mov  ax, 0x0E07
        xor  bx, bx
        int  0x10
        pop  bp
        pop  di
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ===== score.asm =====
; ============================================================
;  score.asm  -  HUD, elapsed time, win / lose / speed checks
; ============================================================

; ---- check_state : after each update ----
check_state:
        push ax
        cmp  byte [speeded], 0
        jne  .nos
        mov  al, [score]
        cmp  al, [speedat]
        jb   .nos
        call apply_speedup              ; one time only
.nos:   mov  al, [mistakes]
        cmp  al, MAXMIST
        jb   .nl
        mov  byte [gstate], GS_LOSE
        jmp  short .d
.nl:    mov  al, [score]
        cmp  al, [winat]
        jb   .d
        mov  byte [gstate], GS_WIN
.d:     pop  ax
        ret

; ---- get_time : AX = minutes, DX = seconds since the game started ----
;      seconds = ticks * 5 / 91   (18.2 ticks/s  ==  91 ticks per 5 s)
get_time:
        push cx
        mov  ax, [ticks]
        mov  dx, 5
        mul  dx
        mov  cx, 91
        div  cx                         ; AX = total seconds
        xor  dx, dx
        mov  cx, 60
        div  cx                         ; AX = minutes, DX = seconds
        cmp  ax, 99
        jbe  .ok
        mov  ax, 99
.ok:    pop  cx
        ret

; ---- draw_hud : numbers on row 1 ----
draw_hud:
        push ax
        push bx
        push cx
        push dx
        mov  byte [pattr], ATTR_HUDV
        xor  ah, ah
        mov  al, [score]
        mov  dl, 7
        mov  dh, 1
        call print_dec2
        xor  ah, ah
        mov  al, [winat]
        mov  dl, 10
        call print_dec2
        xor  ah, ah
        mov  al, [mistakes]
        mov  dl, 24
        call print_dec2
        mov  al, MAXMIST
        mov  dl, 27
        mov  ah, ATTR_HUDV
        add  al, '0'
        call putc
        ; mistake pips:  X X - - -
        xor  bx, bx
        mov  dl, 30
.p:     mov  al, '-'
        mov  ah, ATTR_DIM
        cmp  bl, [mistakes]
        jae  .pp
        mov  al, 'X'
        mov  ah, 0x4F
.pp:    call putc
        add  dl, 2
        inc  bx
        cmp  bx, MAXMIST
        jb   .p
        ; elapsed time MM:SS
        call get_time
        push dx
        mov  dh, 1
        mov  dl, 46
        call print_dec2
        pop  ax
        mov  dl, 49
        call print_dec2
        ; speed multiplier
        mov  al, '1'
        cmp  byte [speeded], 0
        je   .sp
        mov  al, '2'
.sp:    mov  ah, ATTR_HUDV
        mov  dl, 61
        call putc
        ; speed-up banner
        mov  ah, 0x4E
        mov  si, s_banner
        cmp  byte [banner_on], 0
        je   .nb
        mov  bx, [ticks]
        cmp  bx, [banner_until]
        jb   .showb
        mov  byte [banner_on], 0
.nb:    mov  ah, ATTR_LABEL
        mov  si, s_clear_banner
.showb: mov  dl, 5
        mov  dh, 20
        call puts
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ===== menu.asm =====
; ============================================================
;  menu.asm  -  main menu and win/lose screen
; ============================================================

mitems:         dw m_item0, m_item1, m_item2

; ---- draw_menu_items : highlight the item in [sel] ----
draw_menu_items:
        push ax
        push dx
        push si
        push di
        xor  di, di
.l:     mov  ax, di
        shl  al, 1
        add  al, 11                     ; rows 11, 13, 15
        mov  dh, al
        mov  ah, 0x0F
        cmp  di, [sel_w]
        jne  .n
        mov  ah, 0x70                   ; selected: black on grey
.n:     mov  si, di
        shl  si, 1
        mov  si, [mitems+si]
        mov  dl, 27
        call puts
        inc  di
        cmp  di, 3
        jb   .l
        pop  di
        pop  si
        pop  dx
        pop  ax
        ret
sel_w:          dw 0

; ---- show_menu : sets [gmode] = 0 single, 1 co-op, 2 exit ----
show_menu:
        push ax
        push cx
        push dx
        push si
        call clear_screen
        mov  ah, 0x1E
        mov  dl, 28
        mov  dh, 2
        mov  cl, 25
        mov  ch, 3
        call draw_frame
        mov  si, m_title
        mov  dl, 29
        mov  dh, 3
        call puts
        ; decorative rail with four coloured trains
        mov  al, G_H
        mov  ah, ATTR_TRK
        mov  dh, 6
        mov  dl, 10
.rail:  call putc
        inc  dl
        cmp  dl, 70
        jb   .rail
        mov  al, 'A'
        mov  ah, ATTR_A
        mov  dl, 20
        call putc
        mov  al, 'B'
        mov  ah, ATTR_B
        mov  dl, 32
        call putc
        mov  al, 'C'
        mov  ah, ATTR_C
        mov  dl, 44
        call putc
        mov  al, 'D'
        mov  ah, ATTR_D
        mov  dl, 56
        call putc
        mov  ah, ATTR_PANEL
        mov  si, m_sub
        mov  dl, 23
        mov  dh, 8
        call puts
        mov  ah, ATTR_LABEL
        mov  si, m_h1
        mov  dl, 18
        mov  dh, 18
        call puts
        mov  si, m_h2
        inc  dh
        call puts
        mov  si, m_h3
        inc  dh
        call puts
        mov  ah, ATTR_HUD
        mov  si, m_h4
        inc  dh
        call puts
        call kb_flush
        mov  word [sel_w], 0
        call draw_menu_items
.wait:  hlt
        call kb_get
        or   al, al
        jz   .wait
        cmp  al, SC_UP
        jne  .dn
        cmp  word [sel_w], 0
        jne  .dec
        mov  word [sel_w], 3
.dec:   dec  word [sel_w]
        jmp  short .redraw
.dn:    cmp  al, SC_DOWN
        jne  .en
        inc  word [sel_w]
        cmp  word [sel_w], 3
        jb   .redraw
        mov  word [sel_w], 0
        jmp  short .redraw
.en:    cmp  al, SC_ENTER
        je   .pick
        cmp  al, SC_1
        jne  .k2
        mov  word [sel_w], 0
        jmp  short .pick
.k2:    cmp  al, SC_2
        jne  .k3
        mov  word [sel_w], 1
        jmp  short .pick
.k3:    cmp  al, SC_ESC
        jne  .wait
        mov  word [sel_w], 2
.pick:  mov  ax, [sel_w]
        mov  [gmode], al
        pop  si
        pop  dx
        pop  cx
        pop  ax
        ret
.redraw:
        call draw_menu_items
        jmp  .wait

; ---- end_screen : pop-up with result.  Returns AL = 0 replay, 1 menu, 2 exit ----
end_screen:
        push cx
        push dx
        push si
        mov  byte [pattr], 0x2F         ; green box for a win
        mov  si, e_win
        mov  dl, 32
        cmp  byte [gstate], GS_WIN
        je   .go
        mov  byte [pattr], 0x4F         ; red box for a loss
        mov  si, e_lose
        mov  dl, 31
.go:    push si
        push dx
        mov  ah, [pattr]
        mov  al, ' '
        mov  dl, 18
        mov  dh, 6
        mov  cl, 44
        mov  ch, 12
        call fill_rect
        call draw_frame
        pop  dx
        pop  si
        mov  ah, [pattr]
        and  ah, 0xF0
        or   ah, 0x0E                   ; yellow title on the box colour
        mov  dh, 8
        call puts
        mov  ah, [pattr]
        mov  si, e_score
        mov  dl, 24
        mov  dh, 10
        call puts
        mov  si, e_mist
        inc  dh
        call puts
        mov  si, e_time
        inc  dh
        call puts
        xor  ah, ah
        mov  al, [score]
        mov  dl, 35
        mov  dh, 10
        call print_dec2
        xor  ah, ah
        mov  al, [mistakes]
        inc  dh
        call print_dec2
        call get_time
        push dx
        mov  dh, 12
        mov  dl, 35
        call print_dec2
        mov  al, ':'
        mov  ah, [pattr]
        mov  dl, 37
        call putc
        pop  ax
        mov  dl, 38
        call print_dec2
        mov  ah, [pattr]
        mov  si, e_keys
        mov  dl, 22
        mov  dh, 15
        call puts
        call kb_flush
.wait:  hlt
        call kb_get
        or   al, al
        jz   .wait
        cmp  al, SC_R
        jne  .m
        xor  al, al
        jmp  short .out
.m:     cmp  al, SC_M
        jne  .e
        mov  al, 1
        jmp  short .out
.e:     cmp  al, SC_ESC
        jne  .wait
        mov  al, 2
.out:   pop  si
        pop  dx
        pop  cx
        ret

; ===== game.asm =====
; ============================================================
;  game.asm  -  game session: reset, main loop, per-tick update
; ============================================================

; ---- reset_game : new game, same mode (used for first game and replay) ----
reset_game:
        push ax
        push cx
        push di
        push es
        push cs
        pop  es
        mov  di, rt_start               ; zero trains, switches, occupancy
        mov  cx, RT_LEN
        xor  al, al
        cld
        rep  stosb
        pop  es
        mov  byte [score], 0
        mov  byte [mistakes], 0
        mov  byte [speeded], 0
        mov  byte [interval], INIT_INTERVAL
        mov  byte [banner_on], 0
        mov  byte [rot], 0
        mov  byte [gstate], GS_PLAY
        mov  byte [winat], WIN_SINGLE
        mov  byte [speedat], SPEED_SINGLE
        cmp  byte [gmode], 0
        je   .s
        mov  byte [winat], WIN_COOP
        mov  byte [speedat], SPEED_COOP
.s:     mov  byte [spawn_delay], SPAWN_BASE
        mov  byte [spawn_cnt], SPAWN_BASE       ; first train at once
        cli
        mov  word [ticks], 0            ; timer restarts from zero
        mov  word [lasttick], 0
        sti
        call kb_flush
        call seed_rand
        pop  di
        pop  cx
        pop  ax
        ret

; ---- draw_dynamic : everything that changes ----
draw_dynamic:
        call draw_track
        call draw_branches
        call draw_trains
        call draw_hud
        call draw_panel
        ret

; ---- game_update : one timer tick of game logic ----
game_update:
        call spawn_train
        call move_trains
        call check_state
        ret

; ---- run_game : play until win, lose or ESC (gstate tells which) ----
run_game:
        call reset_game
        call clear_screen
        call draw_static
        call draw_dynamic
.loop:  call kb_game
        cmp  byte [gstate], GS_PLAY
        jne  .end
        mov  ax, [ticks]
        cmp  ax, [lasttick]
        jne  .tick
        hlt                             ; sleep until the next interrupt
        jmp  .loop
.tick:  inc  word [lasttick]
        call game_update
        call draw_dynamic
        jmp  .loop
.end:   cmp  byte [gstate], GS_ABORT
        je   .r
        call draw_dynamic               ; show the final position
.r:     ret


; ------------------------------------------------------------
start:
        cld
        call set_mode3
        call hide_cursor
        call hook_timer
        call hook_keyboard

main_menu:
        call show_menu
        cmp  byte [gmode], 2
        jne  play
        jmp  quit
play:   call run_game
        cmp  byte [gstate], GS_ABORT    ; ESC during play -> menu
        jne  .res
        jmp  main_menu
.res:   call end_screen
        or   al, al
        jz   play                       ; replay, same mode
        cmp  al, 1
        jne  quit
        jmp  main_menu

quit:   call unhook_keyboard            ; give DOS its vectors back
        call unhook_timer
        mov  ax, 0x0003                 ; clear screen, reset cursor
        int  0x10
        mov  ax, 0x4C00                 ; terminate, return to DOS
        int  0x21
