module urt.sync.mpmc;

import urt.atomic;

nothrow @nogc:


// Thread-safe FIFO for passing data between threads.
// Uses a CAS spinlock to protect enqueue/dequeue.
//
// NOTE: not ISR-safe. The producer spinlock can deadlock if an ISR-level
// producer is invoked while the lock is held by mainline. For ISR
// producers, use urt.sync.mpsc instead.
struct ThreadSafeQueue(uint capacity = 64, T = void*)
{
nothrow @nogc:

    // returns false if queue is full (item not enqueued).
    bool enqueue(T item)
    {
        while (!cas(&_lock, false, true)) {}
        uint count = _tail >= _head ? _tail - _head : capacity - _head + _tail;
        if (count >= capacity)
        {
            _lock = false;
            return false;
        }
        _queue[_tail] = item;
        _tail = (_tail + 1) % capacity;
        _lock = false;
        return true;
    }

    static if (is(T == U*, U) || is(T == void*))
    {
        // dequeue a pointer, or null if empty.
        T dequeue()
        {
            while (!cas(&_lock, false, true)) {}
            if (_head == _tail)
            {
                _lock = false;
                return null;
            }
            auto result = _queue[_head];
            _head = (_head + 1) % capacity;
            _lock = false;
            return result;
        }
    }
    else
    {
        // dequeue a value type via output parameter.
        // returns false if empty.
        bool dequeue(T* out_)
        {
            while (!cas(&_lock, false, true)) {}
            if (_head == _tail)
            {
                _lock = false;
                return false;
            }
            *out_ = _queue[_head];
            _head = (_head + 1) % capacity;
            _lock = false;
            return true;
        }
    }

private:
    T[capacity] _queue;
    shared uint _head;
    shared uint _tail;
    shared bool _lock;
}
