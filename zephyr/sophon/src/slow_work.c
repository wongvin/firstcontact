/*
 * The slow work queue. See slow_work.h for why it exists.
 */

#include <zephyr/init.h>
#include <zephyr/kernel.h>

#include "slow_work.h"

/*
 * Below the LoRa sensor thread (K_PRIO_PREEMPT(8)) as well as the system queue,
 * so a battery read never delays a send either. Nothing here is urgent: a
 * reading or a confirm that runs a few milliseconds late costs nothing.
 */
#define SLOW_WORK_PRIORITY   K_PRIO_PREEMPT(10)
#define SLOW_WORK_STACK_SIZE 2048

static K_THREAD_STACK_DEFINE(slow_work_stack, SLOW_WORK_STACK_SIZE);
static struct k_work_q slow_work_q;

int sophon_slow_work_submit(struct k_work *work)
{
	return k_work_submit_to_queue(&slow_work_q, work);
}

static int slow_work_init(void)
{
	const struct k_work_queue_config cfg = {.name = "sophon_slow"};

	k_work_queue_start(&slow_work_q, slow_work_stack, K_THREAD_STACK_SIZEOF(slow_work_stack),
			   SLOW_WORK_PRIORITY, &cfg);
	return 0;
}

SYS_INIT(slow_work_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
