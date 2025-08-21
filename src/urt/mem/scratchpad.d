module urt.mem.scratchpad;

import urt.util;

nothrow @nogc:


enum size_t MaxScratchpadSize = 2048;
enum size_t NumScratchBuffers = 4;

static assert(MaxScratchpadSize.is_power_of_2, "Scratchpad size must be a power of 2");


void[] alloc_scratchpad(size_t size = MaxScratchpadSize)
{
    if (size > MaxScratchpadSize)
    {
        assert(false, "Size is larger than max scratch page");
        return null;
    }

    size = max(size.next_power_of_2, WindowSize);
    size_t maskBits = size / WindowSize;
    size_t mask = (1 << maskBits) - 1;

    for (size_t page = 0; page < scratchpad_alloc.length; ++page)
    {
        for (size_t window = 0; window < 8; window += maskBits)
        {
            if ((scratchpad_alloc[page] & (mask << window)) == 0)
            {
                scratchpad_alloc[page] |= mask << window;
                return scratchpad[page*MaxScratchpadSize + window*WindowSize .. page*MaxScratchpadSize + window*WindowSize + size];
            }
        }
    }

    // did not find a free window!
    assert(false, "No scratchpad window available!");
    return null;
}

void free_scratchpad(void[] mem)
{
    size_t page = (cast(size_t)mem.ptr - cast(size_t)scratchpad.ptr) / MaxScratchpadSize;
    size_t window = (cast(size_t)mem.ptr - cast(size_t)scratchpad.ptr) % MaxScratchpadSize / WindowSize;

    size_t maskBits = mem.length / WindowSize;
    size_t mask = (1 << maskBits) - 1;

    assert((scratchpad_alloc[page] & (mask << window)) == (mask << window), "Freeing unallocated scratchpad memory!");
    scratchpad_alloc[page] &= ~(mask << window);
}

private:

enum WindowSize = MaxScratchpadSize / 8;

__gshared ubyte[MaxScratchpadSize*NumScratchBuffers] scratchpad;
__gshared ubyte[NumScratchBuffers] scratchpad_alloc;


unittest
{
    void[] t = alloc_scratchpad(MaxScratchpadSize);
    assert(t.length == MaxScratchpadSize);
    void[] t2 = alloc_scratchpad(MaxScratchpadSize / 2);
    assert(t2.length == MaxScratchpadSize / 2);
    void[] t3 = alloc_scratchpad(MaxScratchpadSize / 2);
    assert(t3.length == MaxScratchpadSize / 2);
    void[] t4 = alloc_scratchpad(MaxScratchpadSize / 4);
    assert(t4.length == MaxScratchpadSize / 4);
    void[] t5 = alloc_scratchpad(MaxScratchpadSize / 8);
    assert(t5.length == MaxScratchpadSize / 8);
    void[] t6 = alloc_scratchpad(MaxScratchpadSize / 4);
    assert(t6.length == MaxScratchpadSize / 4);
    void[] t7 = alloc_scratchpad(MaxScratchpadSize / 8);
    assert(t7.length == MaxScratchpadSize / 8);

    free_scratchpad(t);
    free_scratchpad(t7);
    free_scratchpad(t5);
    free_scratchpad(t4);
    free_scratchpad(t6);
    free_scratchpad(t2);
    free_scratchpad(t3);
}
