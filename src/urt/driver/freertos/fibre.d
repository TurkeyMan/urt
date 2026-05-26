// FreeRTOS task-based fibre implementation.
// Each fibre is a FreeRTOS task that blocks on a task notification.
// co_switch does a notify-target + wait-for-notification handoff,
// giving us cooperative coroutine semantics on top of FreeRTOS.

module urt.driver.freertos.fibre;

import urt.fibre : cothread_t, coentry_t;
import urt.internal.sys.freertos;
import urt.mem;

nothrow @nogc:


struct co_fibre_data
{
    void* user_data;
    uint stack_size;
    TaskHandle_t task_handle;
    coentry_t coentry;
}

co_fibre_data main_fibre_data;
cothread_t co_active_handle = null;

inout(co_fibre_data)* co_get_fibre_data(inout cothread_t fibre) pure
    => cast(co_fibre_data*)fibre;

cothread_t co_active()
{
    if (!co_active_handle)
    {
        main_fibre_data.task_handle = xTaskGetCurrentTaskHandle();
        co_active_handle = &main_fibre_data;
    }
    return co_active_handle;
}

void* co_data()
    => (cast(co_fibre_data*)co_active_handle).user_data;

cothread_t co_derive(void[] memory, coentry_t entry, void* data)
{
    return null; // not supported with FreeRTOS tasks
}

extern(C) static void co_freertos_entry(void* param) nothrow @nogc
{
    co_active_handle = cast(cothread_t)param; // set TLS for this task
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY); // block until first co_switch
    (cast(co_fibre_data*)param).coentry();
}

cothread_t co_create(size_t stack_size, coentry_t entry, void* data)
{
    assert(stack_size <= uint.max, "Stack size too large");
    co_active(); // ensure main fibre initialized

    auto fdata = defaultAllocator().allocT!co_fibre_data();
    if (!fdata) return null;

    fdata.user_data = data;
    fdata.stack_size = cast(uint)stack_size;
    fdata.coentry = entry;

    UBaseType_t priority = uxTaskPriorityGet(null);

    if (xTaskCreate(&co_freertos_entry, "fibre", cast(uint)stack_size,
                    fdata, priority, &fdata.task_handle) != pdPASS)
    {
        defaultAllocator().freeT(fdata);
        return null;
    }

    return fdata;
}

void co_delete(cothread_t handle)
{
    auto fdata = cast(co_fibre_data*)handle;
    if (fdata && fdata != &main_fibre_data)
    {
        if (fdata.task_handle)
            vTaskDelete(fdata.task_handle);
        defaultAllocator().freeT(fdata);
    }
}

void co_switch(cothread_t handle)
{
    xTaskNotifyGive((cast(co_fibre_data*)handle).task_handle);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
}
