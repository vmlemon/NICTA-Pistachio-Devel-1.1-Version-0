/*********************************************************************
 *
 * Copyright (C) 2002-2004,  Karlsruhe University
 *
 * File path:    glue/v4-ia32/trap.S 
 * Description:  Trap handlers
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 * $Id: trap.S,v 1.18 2004/03/15 21:31:32 ud3 Exp $
 *
 *********************************************************************/
#include <l4.h>
#include INC_ARCH(asm.h)
#include <tcb_layout.h>
#include <asmsyms.h>
	
.macro TID_TO_TCB reg
	shr	$THREADNO_SHIFT, \reg
	andl	$(THREADNO_MASK << KTCB_BITS), \reg
	add	$KTCB_AREA_START, \reg
.endm

.macro CURRENT_TCB reg
	mov	%esp, \reg
	and	$(KTCB_MASK), \reg
.endm

/* Pre-Condition:
 * EAX	= To
 * ECX	= UIP
 * EDX	= FromSpecifier
 * ESI	= MR0
 * EDI	= MR1
 * EBX	= USP / undef for int
 * EBP	= MR2
 * ESP	= &KSP for sysenter, KSP+20 for int
 *
 * Stack layout: SYSENTER	INT
 *		 (undef)	ss
 *		 usp		usp
 *		 (undef)	eflags
 *		 (undef)	cs
 *		 uip		uip
 */

BEGIN_PROC(exc_user_sysipc)
#if defined(CONFIG_IA32_SYSENTER)
	movl	(%esp), %esp
	subl	$20, %esp
	movl	%ebx, 12(%esp)			// save USP
#else
#endif

	movl	%ebx, 0(%esp)			// save UIP

#if defined(CONFIG_IA32_SMALL_SPACES)
	mov	$IA32_KDS, %ebx
	mov	%ebx, %ds
#endif
	
#if 0 /*def CONFIG_IPC_FASTPATH*/

	/* msgtag only untyped items and no flags */
	movl	%esi, %ebx
	andl	$(0x3ff << 6), %ebx

	/* no receive timeout */
	or	%cx, %bx
	jne	slowpath

	/* has send phase? (catch no receive later) */
	test	%eax, %eax
	je	slowpath

	/* calculate TCB pointers of current and dest */
	mov	%eax, %ebp
	TID_TO_TCB	%ebp
	CURRENT_TCB	%ebx

	/* check thread id of destination
	 * here we could also bail out!!! */
	cmp	%eax, OFS_TCB_MYSELF_GLOBAL(%ebp)
	jne	slowpath

	/* get myself */
	movl	OFS_TCB_MYSELF_GLOBAL(%ebx), %edi

	/* check that dest thread is waiting for current or any */
	cmp	$TSTATE_WAITING_FOREVER, OFS_TCB_THREAD_STATE(%ebp)
	jne	slowpath
	movl	OFS_TCB_PARTNER(%ebp), %ecx
	cmp	%edi, %ecx
	je	1f
	add	$1, %ecx	// any?
	jnc	slowpath

1:	
#ifdef CONFIG_SMP
	/* check that both threads are on the same CPU */
	mov	OFS_TCB_CPU(%ebp), %ecx
	cmp	%ecx, OFS_TCB_CPU(%ebx)
	jne	slowpath
#endif

	/* make sure that current really blocks
	 * (FromSpec == To) || (SendHead == NULL) */
	cmp	%eax, %edx
	je	2f

	/* edx == -1 && current->sendhead == 0 */
	cmp	$-1, %edx
	jne	slowpath
	cmpl	$0, OFS_TCB_SEND_HEAD(%ebx)
	jne	slowpath

2:	
	/* set partner field */
	movl	%edi, OFS_TCB_PARTNER(%ebp)

	/* set current thread state to waiting */
	movl	%edx, OFS_TCB_PARTNER(%ebx)
	movl	$TSTATE_WAITING_FOREVER, OFS_TCB_THREAD_STATE(%ebx)
	
	/**************************************************
	 * if we reach this point the transfer can 
	 * take place
	 **************************************************/

	mov	OFS_TCB_UTCB(%ebp), %edi	// dst UTCB
	mov	%esi, OFS_UTCB_MR(%edi)		// store MR0

	and	$0x3f, %esi
	test	%esi, %esi
	jnz	fp_copy_loop
fp_copy_loop_done:

4:	/* resource handling */
	cmpl	$0, OFS_TCB_RESOURCE_BITS(%ebx)		// any resources?
	jnz	fp_save_resources
fp_save_resources_done:

5:	/* perform thread switch: (see glue/tcb.h)
	 * EBX = current
	 * ESI = dest
	 */
	movl	%ebp, %esi

	// set tss.esp0
	addl	$KTCB_SIZE, %ebp
	movl	%ebp, (tss + 4)
	
#if !defined(CONFIG_IA32_SMALL_SPACES)
	pushl	$fp_ipc_done
	movl	OFS_TCB_UTCB_LOCATION(%esi), %edi	// utcb
	movl	OFS_TCB_PDIR_CACHE(%esi), %eax		// new PDIR
	movl	%edi, %gs:0
	movl	%esp, OFS_TCB_STACK(%ebx)		// store stack ptr
	movl	OFS_TCB_STACK(%esi), %esp		// load stack ptr
	popl	%ecx					// load dest addr

#ifndef CONFIG_CPU_IA32_P4
	cmpl	$0, OFS_TCB_SPACE(%esi)			// kernel thread?
	je	7f
	movl	%cr3, %edx				// load ptab
	cmpl	%eax, %edx
	je	7f
#else
	cmpl	%eax, OFS_TCB_PDIR_CACHE(%ebx)
	je	7f					// same ptab
	cmpl	$0, OFS_TCB_SPACE(%esi)
	jnz	6f					// kernel thread?
	movl	%eax, OFS_TCB_PDIR_CACHE(%esi)		// update pdir_cache
	jmp	7f
#endif

6:	mov	%eax, %cr3				// switch ptab
7:

#else /* CONFIG_IA32_SMALL_SPACES */
	pushl	$fp_ipc_done

	/* switch stacks */
	movl	%esp, OFS_TCB_STACK(%ebx)
	movl	OFS_TCB_STACK(%esi), %esp

	movl	OFS_TCB_MYSELF_LOCAL(%esi), %edi

	/* is kernel thread? */
	cmpl	$0, OFS_TCB_SPACE(%esi)
	je	9f

	/* calculate location of smallspace id in page table */
	movl	OFS_TCB_SPACE(%esi), %eax
	add	$((CONFIG_SMP_MAX_CPUS * IA32_PAGE_SIZE) + \
	 	  (SMALL_SPACE_ID >> IA32_PAGEDIR_BITS) * 4), %eax

	movl	__is_small, %edx
	movl	OFS_TCB_PDIR_CACHE(%ebx), %ebp
	cmpl	$0, (%eax)
	je	2f

	/* switch to small space */
	cmpl	OFS_TCB_PDIR_CACHE(%esi), %ebp
	je	1f
	movl	4(%eax), %ecx
	movl	8(%eax), %eax
	movl	$gdt, %ebp
	movl	%ecx, 32(%ebp)
	movl	%eax, 36(%ebp)
	orl	$0x800, %eax
	movl	%ecx, 24(%ebp)
	movl	%eax, 28(%ebp)
	movl	$IA32_UDS, %ecx
	movl	%ecx, %es
	movl	%ecx, %fs
	movl	$IA32_UTCB, %ecx
	movl	%ecx, %gs
	movl	$1, __is_small
1:	popl	%ecx
	movl	%edi, %gs:0
	jmp	*%ecx

2:	/* switch to large space */
	testl	%edx, %edx
	je	3f
	movl	$0, __is_small
	movl	$gdt, %eax
	movl	$0x0000ffff, 24(%eax)
	movl	$0x00cbfb00, 28(%eax)
	movl	$0x0000ffff, 32(%eax)
	movl	$0x00cbf300, 36(%eax)

	movl	$IA32_UDS, %edx
	movl	%edx, %es
	movl	%edx, %fs
	movl	$IA32_UTCB, %edx
	movl	%edx, %gs

3:	movl	OFS_TCB_PDIR_CACHE(%esi), %ecx
	cmpl	%ecx, %ebp
	je	9f
	movl	%ecx, %cr3

9:	popl	%ecx
	movl	%edi, %gs:0

#endif /* CONFIG_IA32_SMALL_SPACES */

/* VU:	unclear which one pays... */	
#if 0
	cmpl	$fp_ipc_done, %ecx
	jne	9f
	/* fall through otherwise */
#else
	jmp	*%ecx
#endif

fp_ipc_done:	
	/* reactivation after IPC:
	 *  ESI = current
	 *  EDI = UTCB
	 */
	cmpl	$0, OFS_TCB_RESOURCE_BITS(%esi)
	jne	fp_load_resources
fp_load_resources_done:
	
	movl	$TSTATE_RUNNING, OFS_TCB_THREAD_STATE(%esi)
	movl	OFS_TCB_PARTNER(%esi), %eax	// load partner

#if defined(CONFIG_IA32_SMALL_SPACES)
	movl	$IA32_UDS, %ecx
	mov	%ecx, %ds
#endif

	movl	0(%edi), %esi			// load MRs
	movl	4(%edi), %ebx
	movl	8(%edi), %ebp

#if defined(CONFIG_IA32_SYSENTER)
#if !defined(CONFIG_IA32_SMALL_SPACES)
	movl	16(%esp), %ecx			// user stack
	movl	4 (%esp), %edx			// user ip
	sti
	sysexit
#else
	movl	16(%esp), %ecx			// user stack
	lea	sysexit_tramp, %edx		// EIP for trampoline
	sysexit
#endif
#else
	addl	$4, %esp
	iret
#endif

9:
	jmp	*%ecx				// activate dest

slowpath:
#endif /* CONFIG_IPC_FASTPATH */

	CURRENT_TCB	%ecx
	movl	OFS_TCB_UTCB_LOCATION(%ecx), %ebx// source UTCB

	movl	%esi,	0(%ebx)			// store MRs
	movl	%edi,	4(%ebx)
	movl	%ebp,	8(%ebx)

	movl	%esp,	%ecx
	call	sys_ipc

	CURRENT_TCB	%ecx
	movl	OFS_TCB_UTCB_LOCATION(%ecx), %ebx// source UTCB

	movl	0(%ebx), %esi			// store MRs
	movl	4(%ebx), %edi
	movl	8(%ebx), %ebp

#if defined(CONFIG_IA32_SYSENTER)
#if !defined(CONFIG_IA32_SMALL_SPACES)
	movl	12(%esp), %ecx			// user stack
	movl	0 (%esp), %edx			// user ip
	sti
	sysexit
#else
	movl	12(%esp), %ecx			// user stack
	lea	sysexit_tramp, %edx		// EIP for trampoline
	sysexit
#endif

#else /* !CONFIG_IA32_SYSENTER */
#if defined(CONFIG_IA32_SMALL_SPACES)
	movl	$IA32_UDS, %ecx
	mov	%ecx, %ds
#endif
	iret
#endif /* !CONFIG_IA32_SYSENTER */

#if defined(CONFIG_IA32_SMALL_SPACES) && defined(CONFIG_IA32_SYSENTER)

	/*
	 * Trampoline for entering userlevel in a safe manner.
	 */
	.section .utramp, "ax", @progbits
	.type sysexit_tramp, @function
	.globl sysexit_tramp
	.globl sysexit_tramp_uaccess
sysexit_tramp:
	movl	$IA32_UDS, %edx
	mov	%edx, %ds
	mov	%edx, %ss
	sti
sysexit_tramp_uaccess:
	lret

	.globl sysexit_tramp_end
sysexit_tramp_end:

	/*
	 * If we caught a GP doing the LRET instruction (i.e., invalid
	 * code segment) we return through an IRET which sets the proper
	 * code segment.  If we got a pagefault during the LRET, the IRET
	 * back into the trampoline will fail because it is not accessible
	 * with CS=0x1b.  In both cases we reenter user-level through this
	 * stub.
	 */
	.p2align 4
	.globl reenter_sysexit
	.globl reenter_sysexit_uaccess
reenter_sysexit:
	movl	$IA32_UDS, %edx
	mov	%edx, %ds
reenter_sysexit_uaccess:
	movl	(%ecx), %edx		/* Get EIP */
	addl	$8, %ecx		/* Adjust for user ESP */

	pushl	$IA32_UDS		/* User SS */
	pushl	%ecx			/* User ESP */
	pushl	$IA32_USER_FLAGS	/* User EFlags */
	pushl	$IA32_UCS		/* User CS */
	pushl	%edx			/* User EIP */
	iret

	.previous
#endif /* CONFIG_IA32_SMALL_SPACE */


#ifdef CONFIG_IPC_FASTPATH
/* precondition %ebx == tcb */
fp_save_resources:
	/* no caller-saved registers contain values!!! */
	mov	%ebx, %edx
	add	$OFS_TCB_RESOURCES, %edx
	push	%ebx	/* tcb */
	push	%edx	/* tcb->resources == this */
	call	tcb_resources_save
	add	$8, %esp
	jmp	fp_save_resources_done

fp_load_resources:
	mov	%esi, %eax
	add	$OFS_TCB_RESOURCES, %eax
	push	%esi	/* tcb */
	push	%eax	/* tcb->resources == this */
	call	tcb_resources_load
	add	$8, %esp
	jmp	fp_load_resources_done

/* preconditions: 
	%esi == length 
	%edi == dest->utcb */
fp_copy_loop:
	/* copy loop */
#if defined(CONFIG_IA32_SMALL_SPACES)
	movl	$IA32_KDS, %ecx
	mov	%ecx, %es
#endif

	mov	OFS_TCB_UTCB(%ebx), %ecx	// source UTCB
	add	$(OFS_UTCB_MR+4), %ecx
	add	$(OFS_UTCB_MR+4), %edi
	xchg	%ecx, %esi
	cld
	rep	movsl	(%esi), (%edi)

#if defined(CONFIG_IA32_SMALL_SPACES)
	movl	$IA32_UDS, %ecx
	mov	%ecx, %es
#endif
	jmp	fp_copy_loop_done
#endif

END_PROC(exc_user_sysipc)

.end
