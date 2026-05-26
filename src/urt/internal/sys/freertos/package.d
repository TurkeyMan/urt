module urt.internal.sys.freertos;

// Config assumptions (true for ESP-IDF and Bouffalo SDK):
//   - configUSE_16_BIT_TICKS = 0 (TickType_t = uint32_t)
//   - portBASE_TYPE size     = 4 (BaseType_t = int32_t)
// If a future port violates these, this module must be revised.

version (FreeRTOS):
nothrow @nogc:


alias TickType_t   = uint;
alias BaseType_t   = int;
alias UBaseType_t  = uint;

alias QueueHandle_t      = void*;
alias SemaphoreHandle_t  = void*;
alias TaskHandle_t       = void*;
alias EventGroupHandle_t = void*;
alias EventBits_t        = TickType_t;

enum uint portMUX_FREE_VAL = 0xB33FFFFF;

// SMP-aware spinlock used by portENTER_CRITICAL on ESP-IDF FreeRTOS.
// Default-init (zero owner is wrong) is patched by giving owner a default
// value of portMUX_FREE_VAL -- so a zero-initialised portMUX_TYPE is in
// the "unlocked" state, no explicit constructor needed.
// (Non-debug layout; CONFIG_FREERTOS_PORTMUX_DEBUG adds two more fields
// we don't need.)
struct portMUX_TYPE
{
    uint owner = portMUX_FREE_VAL;
    uint count;
}

alias TaskFunction_t = void function(void*) nothrow @nogc;

enum eNotifyAction : int
{
    eNoAction = 0,
    eSetBits,
    eIncrement,
    eSetValueWithOverwrite,
    eSetValueWithoutOverwrite,
}

enum BaseType_t  pdPASS                  = 1;
enum BaseType_t  pdFAIL                  = 0;
enum BaseType_t  pdTRUE                  = 1;
enum BaseType_t  pdFALSE                 = 0;

enum TickType_t  portMAX_DELAY           = TickType_t.max;
enum ubyte       queueQUEUE_TYPE_MUTEX   = 1;
enum BaseType_t  queueSEND_TO_BACK       = 0;
enum TickType_t  semGIVE_BLOCK_TIME      = 0;
enum UBaseType_t tskDEFAULT_INDEX_TO_NOTIFY = 0;


extern(C)
{
    // queue / semaphore (queue.c)
    QueueHandle_t xQueueCreateMutex(ubyte ucQueueType);
    QueueHandle_t xQueueCreateCountingSemaphore(UBaseType_t uxMaxCount, UBaseType_t uxInitialCount);
    BaseType_t    xQueueSemaphoreTake(QueueHandle_t xQueue, TickType_t xTicksToWait);
    BaseType_t    xQueueGenericSend(QueueHandle_t xQueue, const(void)* pvItemToQueue, TickType_t xTicksToWait, BaseType_t xCopyPosition);
    void          vQueueDelete(QueueHandle_t xQueue);

    // tasks (tasks.c)
    BaseType_t   xTaskCreate(TaskFunction_t pxTaskCode, const(char)* pcName, uint usStackDepth, void* pvParameters, UBaseType_t uxPriority, TaskHandle_t* pxCreatedTask);
    void         vTaskDelete(TaskHandle_t xTaskToDelete);
    TaskHandle_t xTaskGetCurrentTaskHandle();
    UBaseType_t  uxTaskPriorityGet(TaskHandle_t xTask);

    // task notifications -- generic forms (the macros xTaskNotifyGive and
    // ulTaskNotifyTake expand to these with default index/value args).
    BaseType_t xTaskGenericNotify(TaskHandle_t xTaskToNotify, UBaseType_t uxIndexToNotify, uint ulValue, eNotifyAction eAction, uint* pulPreviousNotificationValue);
    uint       ulTaskGenericNotifyTake(UBaseType_t uxIndexToWaitOn, BaseType_t xClearCountOnExit, TickType_t xTicksToWait);

    // critical sections (portmacro). portENTER_CRITICAL(mux) on ESP-IDF
    // expands ultimately to vPortEnterCritical(mux); same for exit.
    void vPortEnterCritical(portMUX_TYPE* mux);
    void vPortExitCritical(portMUX_TYPE* mux);

    // event groups (event_groups.c). Requires configUSE_EVENT_GROUPS=1.
    EventGroupHandle_t xEventGroupCreate();
    void               vEventGroupDelete(EventGroupHandle_t xEventGroup);
    EventBits_t        xEventGroupSetBits(EventGroupHandle_t xEventGroup, EventBits_t uxBitsToSet);
    EventBits_t        xEventGroupClearBits(EventGroupHandle_t xEventGroup, EventBits_t uxBitsToClear);
    EventBits_t        xEventGroupGetBits(EventGroupHandle_t xEventGroup);
    EventBits_t        xEventGroupWaitBits(EventGroupHandle_t xEventGroup, EventBits_t uxBitsToWaitFor, BaseType_t xClearOnExit, BaseType_t xWaitForAllBits, TickType_t xTicksToWait);
}

pragma(inline, true)
BaseType_t xTaskNotifyGive(TaskHandle_t task)
    => xTaskGenericNotify(task, tskDEFAULT_INDEX_TO_NOTIFY, 0, eNotifyAction.eIncrement, null);

pragma(inline, true)
uint ulTaskNotifyTake(BaseType_t clear_on_exit, TickType_t ticks)
    => ulTaskGenericNotifyTake(tskDEFAULT_INDEX_TO_NOTIFY, clear_on_exit, ticks);
