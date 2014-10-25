/*
 * rp_scope.c
 *
 *  Created on: 18 Oct 2014
 *      Author: nils
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/types.h>
#include <linux/errno.h>
#include <linux/mm.h>
#include <linux/gfp.h>
#include <linux/slab.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <asm/uaccess.h>
#include <asm/io.h>

#include "rp_pl.h"
#include "rp_pl_hw.h"
#include "rp_scope.h"

/* scope registers */
#define SCOPE_control		0x00000000UL
#define SCOPE_trig_src		0x00000004UL
#define SCOPE_a_tresh		0x00000008UL
#define SCOPE_b_tresh		0x0000000cUL
#define SCOPE_dly		0x00000010UL
#define SCOPE_dec		0x00000014UL
#define SCOPE_wp_cur		0x00000018UL
#define SCOPE_wp_trig		0x0000001cUL
#define SCOPE_a_hyst		0x00000020UL
#define SCOPE_b_hyst		0x00000024UL
#define SCOPE_avg_en		0x00000028UL
#define SCOPE_a_filt_aa		0x00000030UL
#define SCOPE_a_filt_bb		0x00000034UL
#define SCOPE_a_filt_kk		0x00000038UL
#define SCOPE_a_filt_pp		0x0000003cUL
#define SCOPE_b_filt_aa		0x00000040UL
#define SCOPE_b_filt_bb		0x00000044UL
#define SCOPE_b_filt_kk		0x00000048UL
#define SCOPE_b_filt_pp		0x0000004cUL
/* DDR Dump extension */
#define SCOPE_ddr_control	0x00000100UL
#define SCOPE_ddr_a_base	0x00000104UL
#define SCOPE_ddr_a_end		0x00000108UL
#define SCOPE_ddr_b_base	0x0000010cUL
#define SCOPE_ddr_b_end		0x00000110UL
#define SCOPE_ddr_a_curr	0x00000114UL
#define SCOPE_ddr_b_curr	0x00000118UL

static unsigned int ddr_minsize = 0x00010000UL;
static unsigned int ddr_maxsize = 0x00400000UL;


/*
 * allocate scope-specific resources:
 * - DMA memory buffers
 */
static struct rpad_device *rpad_setup_scope(const struct rpad_device *dev_temp)
{
	struct rpad_scope *scope;
	// FIXME dma_alloc_coherent mit ordentlichem device ?
	//dma_addr_t dma_handle;
	//void *cpu_addr;
	//size_t size;
	//struct device *dev = scope->rp_dev.dev;
	unsigned long cpu_addr;
	unsigned int size;

	scope = kzalloc(sizeof(struct rpad_scope), GFP_KERNEL);
	if (!scope)
		return ERR_PTR(-ENOMEM);

	scope->rp_dev = *dev_temp;

	//if (dma_set_coherent_mask(dev, DMA_BIT_MASK(32))) {
	//	printk(KERN_WARNING "rpad_scope: no suitable DMA available\n");
	//	return -ENOMEM;
	//}
	for (size = ddr_maxsize; size >= ddr_minsize; size >>= 1) {
		printk(KERN_INFO "rpad_scope: trying buffer size %x\n", size);
		//cpu_addr = dma_alloc_coherent(dev, size, &dma_handle, GFP_DMA);
		//if (!IS_ERR_OR_NULL(cpu_addr))
		//	break;
		cpu_addr = __get_free_pages(GFP_KERNEL,
		                            order_base_2(size >> PAGE_SHIFT));
		if (cpu_addr)
			break;
	}

	if (size < ddr_minsize) {
		printk(KERN_WARNING "rpad_scope: not enough contiguous memory\n");
		return ERR_PTR(-ENOMEM);
	}

	scope->buffer_addr = cpu_addr;
	scope->buffer_size = size;
	//scope->buffer_phys_addr = dma_handle;
	scope->buffer_phys_addr = virt_to_phys((void *)cpu_addr); // FIXME we're not supposed to use virt_to_phys

	scope->ba_addr = scope->buffer_addr;
	scope->ba_size = scope->buffer_size / 2;
	scope->ba_phys_addr = scope->buffer_phys_addr;
	scope->ba_last_curr = 0UL;
	scope->bb_addr = scope->buffer_addr + scope->buffer_size / 2;
	scope->bb_size = scope->buffer_size / 2;
	scope->bb_phys_addr = scope->buffer_phys_addr + scope->buffer_size / 2;
	scope->bb_last_curr = 0UL;

	printk(KERN_INFO "rpad_scope: virt %p\n", (void *)scope->buffer_addr);
	printk(KERN_INFO "rpad_scope: phys %p\n", (void *)scope->buffer_phys_addr);

	return &scope->rp_dev;
}

/*
 * release scope-specific resources.
 */
static void rpad_teardown_scope(struct rpad_device *rp_dev)
{
	struct rpad_scope *scope =
		container_of(rp_dev, struct rpad_scope, rp_dev);

	//struct device *dev = scope->rp_dev.dev;
	//dma_free_coherent(dev, scope->buffer_size, scope->buffer_addr,
	//                  scope->buffer_phys_addr);
	free_pages(scope->buffer_addr,
	           order_base_2(scope->buffer_size >> PAGE_SHIFT));

	kfree(scope);
}

/*
 *
 */
static int init_hardware(struct rpad_scope *scope)
{
	unsigned int id;

	if (scope->hw_init_done)
		return 0;

	id = ioread32(rp_addr(scope, RPAD_SYS_ID));
	if (RPAD_VERSION(id) != 1)
		return -ENODEV;

	/* load buffer addresses */
	iowrite32(scope->ba_phys_addr, rp_addr(scope, SCOPE_ddr_a_base));
	iowrite32(scope->ba_phys_addr + scope->ba_size,
	          rp_addr(scope, SCOPE_ddr_a_end));
	iowrite32(scope->bb_phys_addr, rp_addr(scope, SCOPE_ddr_b_base));
	iowrite32(scope->bb_phys_addr + scope->bb_size,
	          rp_addr(scope, SCOPE_ddr_b_end));

	/* stop scope */
	iowrite32(0x00000002, rp_addr(scope, SCOPE_control));
	/* activate address injection */
	iowrite32(0x0000000c, rp_addr(scope, SCOPE_ddr_control));
	/* injection takes a few ADC cycles */
	udelay(5);
	/* enable dumping on both channels */
	iowrite32(0x00000003, rp_addr(scope, SCOPE_ddr_control));
	/* arm scope */
	iowrite32(0x00000001, rp_addr(scope, SCOPE_control));

	scope->hw_init_done = 1;

	return 0;
}

/*
 *
 */
void stop_hardware(struct rpad_scope *scope)
{
	if (!scope->hw_init_done)
		return;

	iowrite32(0x00000002, rp_addr(scope, SCOPE_control));
	iowrite32(0x00000000, rp_addr(scope, SCOPE_ddr_control));
	scope->hw_init_done = 0;
}

/*
 * specific operations done during open are still in flux
 *
 * initialize hardware and allocate text_page, if not already done. reset the
 * singular current read pointer und prepare the first batch of data.
 */
static int rpad_scope_open(struct inode *inodp, struct file *filp)
{
	int retval = 0;
	struct rpad_scope *scope;

	scope = container_of(inodp->i_cdev, struct rpad_scope, rp_dev.cdev);
	filp->private_data = scope;

	if (down_interruptible(&scope->rp_dev.sem))
		return -ERESTARTSYS;

	retval = init_hardware(scope);

	up(&scope->rp_dev.sem);

	return retval;
}

/*
 * specific operations done during release are still in flux
 *
 * free text_page, mark device uninitialized.
 */
static int rpad_scope_release(struct inode *inodp, struct file *filp)
{
	struct rpad_scope *scope = (struct rpad_scope *)filp->private_data;

	if (down_interruptible(&scope->rp_dev.sem))
		return -ERESTARTSYS;

	stop_hardware(scope);

	up(&scope->rp_dev.sem);

	return 0;
}

/*
 * specific operations done during read are still in flux
 * read data from DMA buffer and copy to userspace
 * block until data available
 */
static ssize_t rpad_scope_read(struct file *filp,
                               char __user *ubuf,
                               size_t usize,
                               loff_t *uoffp)
{
	ssize_t size;
	struct rpad_scope *scope = (struct rpad_scope *)filp->private_data;
	unsigned long curr;
	unsigned long uoff = *uoffp;

	if (down_interruptible(&scope->rp_dev.sem))
		return -ERESTARTSYS;

	/* TODO how to distinguish channel A/B requests ? */
	/* for now, just read A */
	if (uoff > scope->ba_size) {
		size = -EINVAL;
		goto out;
	}

	curr = ioread32(rp_addr(scope, SCOPE_ddr_a_curr)) - scope->ba_phys_addr;

	while (uoff == scope->ba_last_curr && curr == scope->ba_last_curr) {
		/* no unread data */
		/* FIXME block non-busy and interruptable until data available */

		curr = ioread32(rp_addr(scope, SCOPE_ddr_a_curr)) - scope->ba_phys_addr;
	}

	/* unread data */
	scope->ba_last_curr = curr;
	if (curr < uoff) {
		if (uoff == scope->ba_size) {
			uoff = 0UL;
			*uoffp = 0LL;
		} else {
			curr = scope->ba_size;
		}
	}

	if (uoff + usize > curr)
		size = curr - uoff;
	else
		size = usize;

	if (copy_to_user(ubuf, (void *)(scope->ba_addr + uoff), size)) {
		size = -EFAULT;
		goto out;
	}
	*uoffp += size;

out:
	up(&scope->rp_dev.sem);

	return size;
}

static ssize_t rpad_scope_write(struct file *filp,
                                const char __user *ubuf,
                                size_t usize,
                                loff_t *uoffp)
{
	// TODO
	return -EINVAL;
}

static const struct vm_operations_struct rpad_scope_mmap_mem_ops = {
};

/*
 * create mapping for IO range of scope, derived from dev/mem code
 */
static int rpad_scope_mmap(struct file *filp, struct vm_area_struct *vma)
{
	struct rpad_scope *scope = (struct rpad_scope *)filp->private_data;
	size_t size = vma->vm_end - vma->vm_start;
	resource_size_t addr = vma->vm_pgoff << PAGE_SHIFT;

	printk(KERN_ALERT "rpad_scope0: vm %p sa %p\n", (void *)vma->vm_pgoff, (void *)scope->rp_dev.sys_addr);
	if (addr        < scope->rp_dev.sys_addr ||
	    addr + size > scope->rp_dev.sys_addr + RPAD_PL_REGION_SIZE)
		return -EINVAL;

	vma->vm_page_prot = phys_mem_access_prot(filp, vma->vm_pgoff, size,
	                                         vma->vm_page_prot);

	vma->vm_ops = &rpad_scope_mmap_mem_ops;

	/* Remap-pfn-range will mark the range VM_IO */
	if (remap_pfn_range(vma, vma->vm_start, vma->vm_pgoff, size,
	                    vma->vm_page_prot))
		return -EAGAIN;

	return 0;
}

static struct file_operations rpad_scope_fops = {
	.owner		= THIS_MODULE,
	.open		= rpad_scope_open,
	.release	= rpad_scope_release,
	.read		= rpad_scope_read,
	.write		= rpad_scope_write,
	.mmap		= rpad_scope_mmap,
};

struct rpad_devtype_data rpad_scope_data = {
	.type		= RPAD_SCOPE_TYPE,
	.setup		= rpad_setup_scope,
	.teardown	= rpad_teardown_scope,
	.fops		= &rpad_scope_fops,
	.name		= "scope",
};

/*
 * supported parameters on the insmod command line
 */
module_param(ddr_minsize, uint, S_IRUGO);
module_param(ddr_maxsize, uint, S_IRUGO);
