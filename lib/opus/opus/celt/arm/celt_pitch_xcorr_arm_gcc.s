@ Copyright (c) 2007-2008 CSIRO
@ Copyright (c) 2007-2009 Xiph.Org Foundation
@ Copyright (c) 2013      Parrot
@ Written by Aurélien Zanelli
@
@ Redistribution and use in source and binary forms, with or without
@ modification, are permitted provided that the following conditions
@ are met:
@
@ - Redistributions of source code must retain the above copyright
@ notice, this list of conditions and the following disclaimer.
@
@ - Redistributions in binary form must reproduce the above copyright
@ notice, this list of conditions and the following disclaimer in the
@ documentation and/or other materials provided with the distribution.
@
@ THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
@ ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
@ LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
@ A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
@ OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
@ EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
@ PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
@ PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
@ LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
@ NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
@ SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

  .text

  .include "celt/arm/armopts.s"

#if defined(OPUS_ARM_MAY_HAVE_EDSP)
  .global celt_pitch_xcorr_edsp
#endif

#if defined(OPUS_ARM_MAY_HAVE_NEON)
  .global celt_pitch_xcorr_neon
#endif

#if defined(OPUS_ARM_MAY_HAVE_NEON)

@ Compute sum[k]=sum(x[j]*y[j+k],j=0...len-1), k=0...3
  .type xcorr_kernel_neon, %function
xcorr_kernel_neon:
xcorr_kernel_neon_start:
  @ input:
  @   r3     = int         len
  @   r4     = opus_val16 *x
  @   r5     = opus_val16 *y
  @   q0     = opus_val32  sum[4]
  @ output:
  @   q0     = opus_val32  sum[4]
  @ preserved: r0-r3, r6-r11, d2, q4-q7, q9-q15
  @ internal usage:
  @   r12 = int j
  @   d3  = y_3|y_2|y_1|y_0
  @   q2  = y_B|y_A|y_9|y_8|y_7|y_6|y_5|y_4
  @   q3  = x_7|x_6|x_5|x_4|x_3|x_2|x_1|x_0
  @   q8  = scratch
  @
  @ Load y[0...3]
  @ This requires len>0 to always be valid (which we assert in the C code).
  vld1.16      {d5}, [r5]!
  subs         r12, r3, #8
  ble xcorr_kernel_neon_process4
@ Process 8 samples at a time.
@ This loop loads one y value more than we actually need. Therefore we have to
@ stop as soon as there are 8 or fewer samples left (instead of 7), to avoid
@ reading past the end of the array.
xcorr_kernel_neon_process8:
  @ This loop has 19 total instructions (10 cycles to issue, minimum), with
  @ - 2 cycles of ARM insrtuctions,
  @ - 10 cycles of load/store/byte permute instructions, and
  @ - 9 cycles of data processing instructions.
  @ On a Cortex A8, we dual-issue the maximum amount (9 cycles) between the
  @ latter two categories, meaning the whole loop should run in 10 cycles per
  @ iteration, barring cache misses.
  @
  @ Load x[0...7]
  vld1.16      {d6, d7}, [r4]!
  @ Unlike VMOV, VAND is a data processing instruction (and doesn't get
  @ assembled to VMOV, like VORR would), so it dual-issues with the prior VLD1.
  vand         d3, d5, d5
  subs         r12, r12, #8
  @ Load y[4...11]
  vld1.16      {d4, d5}, [r5]!
  vmlal.s16    q0, d3, d6[0]
  vext.16      d16, d3, d4, #1
  vmlal.s16    q0, d4, d7[0]
  vext.16      d17, d4, d5, #1
  vmlal.s16    q0, d16, d6[1]
  vext.16      d16, d3, d4, #2
  vmlal.s16    q0, d17, d7[1]
  vext.16      d17, d4, d5, #2
  vmlal.s16    q0, d16, d6[2]
  vext.16      d16, d3, d4, #3
  vmlal.s16    q0, d17, d7[2]
  vext.16      d17, d4, d5, #3
  vmlal.s16    q0, d16, d6[3]
  vmlal.s16    q0, d17, d7[3]
  bgt xcorr_kernel_neon_process8
@ Process 4 samples here if we have > 4 left (still reading one extra y value).
xcorr_kernel_neon_process4:
  adds         r12, r12, #4
  ble xcorr_kernel_neon_process2
  @ Load x[0...3]
  vld1.16      d6, [r4]!
  @ Use VAND since it's a data processing instruction again.
  vand         d4, d5, d5
  sub          r12, r12, #4
  @ Load y[4...7]
  vld1.16      d5, [r5]!
  vmlal.s16    q0, d4, d6[0]
  vext.16      d16, d4, d5, #1
  vmlal.s16    q0, d16, d6[1]
  vext.16      d16, d4, d5, #2
  vmlal.s16    q0, d16, d6[2]
  vext.16      d16, d4, d5, #3
  vmlal.s16    q0, d16, d6[3]
@ Process 2 samples here if we have > 2 left (still reading one extra y value).
xcorr_kernel_neon_process2:
  adds         r12, r12, #2
  ble xcorr_kernel_neon_process1
  @ Load x[0...1]
  vld2.16      {d6[],d7[]}, [r4]!
  @ Use VAND since it's a data processing instruction again.
  vand         d4, d5, d5
  sub          r12, r12, #2
  @ Load y[4...5]
  vld1.32      {d5[]}, [r5]!
  vmlal.s16    q0, d4, d6
  vext.16      d16, d4, d5, #1
  @ Replace bottom copy of {y5,y4} in d5 with {y3,y2} from d4, using VSRI
  @ instead of VEXT, since it's a data-processing instruction.
  vsri.64      d5, d4, #32
  vmlal.s16    q0, d16, d7
@ Process 1 sample using the extra y value we loaded above.
xcorr_kernel_neon_process1:
  @ Load next *x
  vld1.16      {d6[]}, [r4]!
  adds         r12, r12, #1
  @ y[0...3] are left in d5 from prior iteration(s) (if any)
  vmlal.s16    q0, d5, d6
  movle        pc, lr
@ Now process 1 last sample, not reading ahead.
  @ Load last *y
  vld1.16      {d4[]}, [r5]!
  vsri.64      d4, d5, #16
  @ Load last *x
  vld1.16      {d6[]}, [r4]!
  vmlal.s16    q0, d4, d6
  mov          pc, lr
  .size xcorr_kernel_neon, .-xcorr_kernel_neon

@ opus_val32 celt_pitch_xcorr_neon(opus_val16 *_x, opus_val16 *_y,
@  opus_val32 *xcorr, int len, int max_pitch, int arch)
  .type celt_pitch_xcorr_neon, %function
celt_pitch_xcorr_neon:
  @ input:
  @   r0  = opus_val16 *_x
  @   r1  = opus_val16 *_y
  @   r2  = opus_val32 *xcorr
  @   r3  = int         len
  @ output:
  @   r0  = int         maxcorr
  @ internal usage:
  @   r4  = opus_val16 *x (for xcorr_kernel_neon())
  @   r5  = opus_val16 *y (for xcorr_kernel_neon())
  @   r6  = int         max_pitch
  @   r12 = int         j
  @   q15 = int         maxcorr[4] (q15 is not used by xcorr_kernel_neon())
  @ ignored:
  @         int         arch
  stmfd        sp!, {r4-r6, lr}
  ldr          r6, [sp, #16]
  vmov.s32     q15, #1
  @ if (max_pitch < 4) goto celt_pitch_xcorr_neon_process4_done
  subs         r6, r6, #4
  blt celt_pitch_xcorr_neon_process4_done
celt_pitch_xcorr_neon_process4:
  @ xcorr_kernel_neon parameters:
  @ r3 = len, r4 = _x, r5 = _y, q0 = {0, 0, 0, 0}
  mov          r4, r0
  mov          r5, r1
  veor         q0, q0, q0
  @ xcorr_kernel_neon only modifies r4, r5, r12, and q0...q3.
  @ So we don't save/restore any other registers.
  bl xcorr_kernel_neon_start
  subs         r6, r6, #4
  vst1.32      {q0}, [r2]!
  @ _y += 4
  add          r1, r1, #8
  vmax.s32     q15, q15, q0
  @ if (max_pitch < 4) goto celt_pitch_xcorr_neon_process4_done
  bge celt_pitch_xcorr_neon_process4
@ We have less than 4 sums left to compute.
celt_pitch_xcorr_neon_process4_done:
  adds         r6, r6, #4
  @ Reduce maxcorr to a single value
  vmax.s32     d30, d30, d31
  vpmax.s32    d30, d30, d30
  @ if (max_pitch <= 0) goto celt_pitch_xcorr_neon_done
  ble celt_pitch_xcorr_neon_done
@ Now compute each remaining sum one at a time.
celt_pitch_xcorr_neon_process_remaining:
  mov          r4, r0
  mov          r5, r1
  vmov.i32     q0, #0
  subs         r12, r3, #8
  blt celt_pitch_xcorr_neon_process_remaining4
@ Sum terms 8 at a time.
celt_pitch_xcorr_neon_process_remaining_loop8:
  @ Load x[0...7]
  vld1.16      {q1}, [r4]!
  @ Load y[0...7]
  vld1.16      {q2}, [r5]!
  subs         r12, r12, #8
  vmlal.s16    q0, d4, d2
  vmlal.s16    q0, d5, d3
  bge celt_pitch_xcorr_neon_process_remaining_loop8
@ Sum terms 4 at a time.
celt_pitch_xcorr_neon_process_remaining4:
  adds         r12, r12, #4
  blt celt_pitch_xcorr_neon_process_remaining4_done
  @ Load x[0...3]
  vld1.16      {d2}, [r4]!
  @ Load y[0...3]
  vld1.16      {d3}, [r5]!
  sub          r12, r12, #4
  vmlal.s16    q0, d3, d2
celt_pitch_xcorr_neon_process_remaining4_done:
  @ Reduce the sum to a single value.
  vadd.s32     d0, d0, d1
  vpaddl.s32   d0, d0
  adds         r12, r12, #4
  ble celt_pitch_xcorr_neon_process_remaining_loop_done
@ Sum terms 1 at a time.
celt_pitch_xcorr_neon_process_remaining_loop1:
  vld1.16      {d2[]}, [r4]!
  vld1.16      {d3[]}, [r5]!
  subs         r12, r12, #1
  vmlal.s16    q0, d2, d3
  bgt celt_pitch_xcorr_neon_process_remaining_loop1
celt_pitch_xcorr_neon_process_remaining_loop_done:
  vst1.32      {d0[0]}, [r2]!
  vmax.s32     d30, d30, d0
  subs         r6, r6, #1
  @ _y++
  add          r1, r1, #2
  @ if (--max_pitch > 0) goto celt_pitch_xcorr_neon_process_remaining
  bgt celt_pitch_xcorr_neon_process_remaining
celt_pitch_xcorr_neon_done:
  vmov.32      r0, d30[0]
  ldmfd        sp!, {r4-r6, pc}
  .size celt_pitch_xcorr_neon, .-celt_pitch_xcorr_neon

#endif

#if defined(OPUS_ARM_MAY_HAVE_EDSP)

@ This will get used on ARMv7 devices without NEON, so it has been optimized
@ to take advantage of dual-issuing where possible.
  .type xcorr_kernel_edsp, %function
xcorr_kernel_edsp:
xcorr_kernel_edsp_start:
  @ input:
  @   r3      = int         len
  @   r4      = opus_val16 *_x (must be 32-bit aligned)
  @   r5      = opus_val16 *_y (must be 32-bit aligned)
  @   r6...r9 = opus_val32  sum[4]
  @ output:
  @   r6...r9 = opus_val32  sum[4]
  @ preserved: r0-r5
  @ internal usage
  @   r2      = int         j
  @   r12,r14 = opus_val16  x[4]
  @   r10,r11 = opus_val16  y[4]
  stmfd        sp!, {r2,r4,r5,lr}
  ldr          r10, [r5], #4      @ Load y[0...1]
  subs         r2, r3, #4         @ j = len-4
  ldr          r11, [r5], #4      @ Load y[2...3]
  ble xcorr_kernel_edsp_process4_done
  ldr          r12, [r4], #4      @ Load x[0...1]
  @ Stall
xcorr_kernel_edsp_process4:
  @ The multiplies must issue from pipeline 0, and can't dual-issue with each
  @ other. Every other instruction here dual-issues with a multiply, and is
  @ thus "free". There should be no stalls in the body of the loop.
  smlabb       r6, r12, r10, r6   @ sum[0] = MAC16_16(sum[0],x_0,y_0)
  ldr          r14, [r4], #4      @ Load x[2...3]
  smlabt       r7, r12, r10, r7   @ sum[1] = MAC16_16(sum[1],x_0,y_1)
  subs         r2, r2, #4         @ j-=4
  smlabb       r8, r12, r11, r8   @ sum[2] = MAC16_16(sum[2],x_0,y_2)
  smlabt       r9, r12, r11, r9   @ sum[3] = MAC16_16(sum[3],x_0,y_3)
  smlatt       r6, r12, r10, r6   @ sum[0] = MAC16_16(sum[0],x_1,y_1)
  ldr          r10, [r5], #4      @ Load y[4...5]
  smlatb       r7, r12, r11, r7   @ sum[1] = MAC16_16(sum[1],x_1,y_2)
  smlatt       r8, r12, r11, r8   @ sum[2] = MAC16_16(sum[2],x_1,y_3)
  smlatb       r9, r12, r10, r9   @ sum[3] = MAC16_16(sum[3],x_1,y_4)
  ldrgt        r12, [r4], #4      @ Load x[0...1]
  smlabb       r6, r14, r11, r6   @ sum[0] = MAC16_16(sum[0],x_2,y_2)
  smlabt       r7, r14, r11, r7   @ sum[1] = MAC16_16(sum[1],x_2,y_3)
  smlabb       r8, r14, r10, r8   @ sum[2] = MAC16_16(sum[2],x_2,y_4)
  smlabt       r9, r14, r10, r9   @ sum[3] = MAC16_16(sum[3],x_2,y_5)
  smlatt       r6, r14, r11, r6   @ sum[0] = MAC16_16(sum[0],x_3,y_3)
  ldr          r11, [r5], #4      @ Load y[6...7]
  smlatb       r7, r14, r10, r7   @ sum[1] = MAC16_16(sum[1],x_3,y_4)
  smlatt       r8, r14, r10, r8   @ sum[2] = MAC16_16(sum[2],x_3,y_5)
  smlatb       r9, r14, r11, r9   @ sum[3] = MAC16_16(sum[3],x_3,y_6)
  bgt xcorr_kernel_edsp_process4
xcorr_kernel_edsp_process4_done:
  adds         r2, r2, #4
  ble xcorr_kernel_edsp_done
  ldrh         r12, [r4], #2      @ r12 = *x++
  subs         r2, r2, #1         @ j--
  @ Stall
  smlabb       r6, r12, r10, r6   @ sum[0] = MAC16_16(sum[0],x,y_0)
  ldrhgt       r14, [r4], #2      @ r14 = *x++
  smlabt       r7, r12, r10, r7   @ sum[1] = MAC16_16(sum[1],x,y_1)
  smlabb       r8, r12, r11, r8   @ sum[2] = MAC16_16(sum[2],x,y_2)
  smlabt       r9, r12, r11, r9   @ sum[3] = MAC16_16(sum[3],x,y_3)
  ble xcorr_kernel_edsp_done
  smlabt       r6, r14, r10, r6   @ sum[0] = MAC16_16(sum[0],x,y_1)
  subs         r2, r2, #1         @ j--
  smlabb       r7, r14, r11, r7   @ sum[1] = MAC16_16(sum[1],x,y_2)
  ldrh         r10, [r5], #2      @ r10 = y_4 = *y++
  smlabt       r8, r14, r11, r8   @ sum[2] = MAC16_16(sum[2],x,y_3)
  ldrhgt       r12, [r4], #2      @ r12 = *x++
  smlabb       r9, r14, r10, r9   @ sum[3] = MAC16_16(sum[3],x,y_4)
  ble xcorr_kernel_edsp_done
  smlabb       r6, r12, r11, r6   @ sum[0] = MAC16_16(sum[0],tmp,y_2)
  cmp          r2, #1             @ j--
  smlabt       r7, r12, r11, r7   @ sum[1] = MAC16_16(sum[1],tmp,y_3)
  ldrh         r2, [r5], #2       @ r2 = y_5 = *y++
  smlabb       r8, r12, r10, r8   @ sum[2] = MAC16_16(sum[2],tmp,y_4)
  ldrhgt       r14, [r4]          @ r14 = *x
  smlabb       r9, r12, r2, r9    @ sum[3] = MAC16_16(sum[3],tmp,y_5)
  ble xcorr_kernel_edsp_done
  smlabt       r6, r14, r11, r6   @ sum[0] = MAC16_16(sum[0],tmp,y_3)
  ldrh         r11, [r5]          @ r11 = y_6 = *y
  smlabb       r7, r14, r10, r7   @ sum[1] = MAC16_16(sum[1],tmp,y_4)
  smlabb       r8, r14, r2, r8    @ sum[2] = MAC16_16(sum[2],tmp,y_5)
  smlabb       r9, r14, r11, r9   @ sum[3] = MAC16_16(sum[3],tmp,y_6)
xcorr_kernel_edsp_done:
  ldmfd        sp!, {r2,r4,r5,pc}
  .size xcorr_kernel_edsp, .-xcorr_kernel_edsp

  .type celt_pitch_xcorr_edsp, %function
celt_pitch_xcorr_edsp:
  @ input:
  @   r0  = opus_val16 *_x (must be 32-bit aligned)
  @   r1  = opus_val16 *_y (only needs to be 16-bit aligned)
  @   r2  = opus_val32 *xcorr
  @   r3  = int         len
  @ output:
  @   r0  = maxcorr
  @ internal usage
  @   r4  = opus_val16 *x
  @   r5  = opus_val16 *y
  @   r6  = opus_val32  sum0
  @   r7  = opus_val32  sum1
  @   r8  = opus_val32  sum2
  @   r9  = opus_val32  sum3
  @   r1  = int         max_pitch
  @   r12 = int         j
  @ ignored:
  @         int         arch
  stmfd        sp!, {r4-r11, lr}
  mov          r5, r1
  ldr          r1, [sp, #36]
  mov          r4, r0
  tst          r5, #3
  @ maxcorr = 1
  mov          r0, #1
  beq          celt_pitch_xcorr_edsp_process1u_done
@ Compute one sum at the start to make y 32-bit aligned.
  subs         r12, r3, #4
  @ r14 = sum = 0
  mov          r14, #0
  ldrh         r8, [r5], #2
  ble celt_pitch_xcorr_edsp_process1u_loop4_done
  ldr          r6, [r4], #4
  mov          r8, r8, lsl #16
celt_pitch_xcorr_edsp_process1u_loop4:
  ldr          r9, [r5], #4
  smlabt       r14, r6, r8, r14     @ sum = MAC16_16(sum, x_0, y_0)
  ldr          r7, [r4], #4
  smlatb       r14, r6, r9, r14     @ sum = MAC16_16(sum, x_1, y_1)
  ldr          r8, [r5], #4
  smlabt       r14, r7, r9, r14     @ sum = MAC16_16(sum, x_2, y_2)
  subs         r12, r12, #4         @ j-=4
  smlatb       r14, r7, r8, r14     @ sum = MAC16_16(sum, x_3, y_3)
  ldrgt        r6, [r4], #4
  bgt celt_pitch_xcorr_edsp_process1u_loop4
  mov          r8, r8, lsr #16
celt_pitch_xcorr_edsp_process1u_loop4_done:
  adds         r12, r12, #4
celt_pitch_xcorr_edsp_process1u_loop1:
  ldrhge       r6, [r4], #2
  @ Stall
  smlabbGE     r14, r6, r8, r14    @ sum = MAC16_16(sum, *x, *y)
  subsGE       r12, r12, #1
  ldrhgt       r8, [r5], #2
  bgt celt_pitch_xcorr_edsp_process1u_loop1
  @ Restore _x
  sub          r4, r4, r3, lsl #1
  @ Restore and advance _y
  sub          r5, r5, r3, lsl #1
  @ maxcorr = max(maxcorr, sum)
  cmp          r0, r14
  add          r5, r5, #2
  movlt        r0, r14
  subs         r1, r1, #1
  @ xcorr[i] = sum
  str          r14, [r2], #4
  ble celt_pitch_xcorr_edsp_done
celt_pitch_xcorr_edsp_process1u_done:
  @ if (max_pitch < 4) goto celt_pitch_xcorr_edsp_process2
  subs         r1, r1, #4
  blt celt_pitch_xcorr_edsp_process2
celt_pitch_xcorr_edsp_process4:
  @ xcorr_kernel_edsp parameters:
  @ r3 = len, r4 = _x, r5 = _y, r6...r9 = sum[4] = {0, 0, 0, 0}
  mov          r6, #0
  mov          r7, #0
  mov          r8, #0
  mov          r9, #0
  bl xcorr_kernel_edsp_start  @ xcorr_kernel_edsp(_x, _y+i, xcorr+i, len)
  @ maxcorr = max(maxcorr, sum0, sum1, sum2, sum3)
  cmp          r0, r6
  @ _y+=4
  add          r5, r5, #8
  movlt        r0, r6
  cmp          r0, r7
  movlt        r0, r7
  cmp          r0, r8
  movlt        r0, r8
  cmp          r0, r9
  movlt        r0, r9
  stmia        r2!, {r6-r9}
  subs         r1, r1, #4
  bge celt_pitch_xcorr_edsp_process4
celt_pitch_xcorr_edsp_process2:
  adds         r1, r1, #2
  blt celt_pitch_xcorr_edsp_process1a
  subs         r12, r3, #4
  @ {r10, r11} = {sum0, sum1} = {0, 0}
  mov          r10, #0
  mov          r11, #0
  ldr          r8, [r5], #4
  ble celt_pitch_xcorr_edsp_process2_loop_done
  ldr          r6, [r4], #4
  ldr          r9, [r5], #4
celt_pitch_xcorr_edsp_process2_loop4:
  smlabb       r10, r6, r8, r10     @ sum0 = MAC16_16(sum0, x_0, y_0)
  ldr          r7, [r4], #4
  smlabt       r11, r6, r8, r11     @ sum1 = MAC16_16(sum1, x_0, y_1)
  subs         r12, r12, #4         @ j-=4
  smlatt       r10, r6, r8, r10     @ sum0 = MAC16_16(sum0, x_1, y_1)
  ldr          r8, [r5], #4
  smlatb       r11, r6, r9, r11     @ sum1 = MAC16_16(sum1, x_1, y_2)
  ldrgt        r6, [r4], #4
  smlabb       r10, r7, r9, r10     @ sum0 = MAC16_16(sum0, x_2, y_2)
  smlabt       r11, r7, r9, r11     @ sum1 = MAC16_16(sum1, x_2, y_3)
  smlatt       r10, r7, r9, r10     @ sum0 = MAC16_16(sum0, x_3, y_3)
  ldrgt        r9, [r5], #4
  smlatb       r11, r7, r8, r11     @ sum1 = MAC16_16(sum1, x_3, y_4)
  bgt celt_pitch_xcorr_edsp_process2_loop4
celt_pitch_xcorr_edsp_process2_loop_done:
  adds         r12, r12, #2
  ble  celt_pitch_xcorr_edsp_process2_1
  ldr          r6, [r4], #4
  @ Stall
  smlabb       r10, r6, r8, r10     @ sum0 = MAC16_16(sum0, x_0, y_0)
  ldr          r9, [r5], #4
  smlabt       r11, r6, r8, r11     @ sum1 = MAC16_16(sum1, x_0, y_1)
  sub          r12, r12, #2
  smlatt       r10, r6, r8, r10     @ sum0 = MAC16_16(sum0, x_1, y_1)
  mov          r8, r9
  smlatb       r11, r6, r9, r11     @ sum1 = MAC16_16(sum1, x_1, y_2)
celt_pitch_xcorr_edsp_process2_1:
  ldrh         r6, [r4], #2
  adds         r12, r12, #1
  @ Stall
  smlabb       r10, r6, r8, r10     @ sum0 = MAC16_16(sum0, x_0, y_0)
  ldrhgt       r7, [r4], #2
  smlabt       r11, r6, r8, r11     @ sum1 = MAC16_16(sum1, x_0, y_1)
  ble celt_pitch_xcorr_edsp_process2_done
  ldrh         r9, [r5], #2
  smlabt       r10, r7, r8, r10     @ sum0 = MAC16_16(sum0, x_0, y_1)
  smlabb       r11, r7, r9, r11     @ sum1 = MAC16_16(sum1, x_0, y_2)
celt_pitch_xcorr_edsp_process2_done:
  @ Restore _x
  sub          r4, r4, r3, lsl #1
  @ Restore and advance _y
  sub          r5, r5, r3, lsl #1
  @ maxcorr = max(maxcorr, sum0)
  cmp          r0, r10
  add          r5, r5, #2
  movlt        r0, r10
  sub          r1, r1, #2
  @ maxcorr = max(maxcorr, sum1)
  cmp          r0, r11
  @ xcorr[i] = sum
  str          r10, [r2], #4
  movlt        r0, r11
  str          r11, [r2], #4
celt_pitch_xcorr_edsp_process1a:
  adds         r1, r1, #1
  blt celt_pitch_xcorr_edsp_done
  subs         r12, r3, #4
  @ r14 = sum = 0
  mov          r14, #0
  blt celt_pitch_xcorr_edsp_process1a_loop_done
  ldr          r6, [r4], #4
  ldr          r8, [r5], #4
  ldr          r7, [r4], #4
  ldr          r9, [r5], #4
celt_pitch_xcorr_edsp_process1a_loop4:
  smlabb       r14, r6, r8, r14     @ sum = MAC16_16(sum, x_0, y_0)
  subs         r12, r12, #4         @ j-=4
  smlatt       r14, r6, r8, r14     @ sum = MAC16_16(sum, x_1, y_1)
  ldrge        r6, [r4], #4
  smlabb       r14, r7, r9, r14     @ sum = MAC16_16(sum, x_2, y_2)
  ldrge        r8, [r5], #4
  smlatt       r14, r7, r9, r14     @ sum = MAC16_16(sum, x_3, y_3)
  ldrge        r7, [r4], #4
  ldrge        r9, [r5], #4
  bge celt_pitch_xcorr_edsp_process1a_loop4
celt_pitch_xcorr_edsp_process1a_loop_done:
  adds         r12, r12, #2
  ldrge        r6, [r4], #4
  ldrge        r8, [r5], #4
  @ Stall
  smlabbGE     r14, r6, r8, r14     @ sum = MAC16_16(sum, x_0, y_0)
  SUBGE        r12, r12, #2
  smlattGE     r14, r6, r8, r14     @ sum = MAC16_16(sum, x_1, y_1)
  adds         r12, r12, #1
  ldrhge       r6, [r4], #2
  ldrhge       r8, [r5], #2
  @ Stall
  smlabbge     r14, r6, r8, r14     @ sum = MAC16_16(sum, *x, *y)
  @ maxcorr = max(maxcorr, sum)
  cmp          r0, r14
  @ xcorr[i] = sum
  str          r14, [r2], #4
  movlt        r0, r14
celt_pitch_xcorr_edsp_done:
  ldmfd        sp!, {r4-r11, pc}
  .size celt_pitch_xcorr_edsp, .-celt_pitch_xcorr_edsp

#endif

  .end
