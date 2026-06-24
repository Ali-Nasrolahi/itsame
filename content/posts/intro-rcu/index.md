---
title: "Introduction to RCU"
date: 2026-06-23T18:30:49Z
draft: false
description: "A small introduction to RCU (Read-Copy Update) design"
tags: ['linux', 'kernel', 'concurrency']
---

## Abstract

Concurrency has always been one of the hardest problems in software engineering. Over the years, many synchronization techniques have been developed, from simple mutexes to sophisticated lock-free algorithms. Among them, Read-Copy Update (RCU) stands out as one of the most successful designs for read-heavy workloads.
RCU allows readers to access shared data with extremely low overhead while still permitting concurrent updates. The implementation details can become quite complex, especially in the Linux kernel, but the core idea is remarkably simple.
In this article, we'll look at what RCU is, what problem it solves, how it works at a high level, and why it has become a fundamental building block in the Linux kernel and many userspace projects.

## The Problem

Any brilliant idea must address a problem, and RCU is no exception.

Nowadays, most software relies on multithreading in one way or another. Whether it is a web server handling thousands of requests, a database managing concurrent transactions, or an operating system coordinating hundreds of tasks, multiple threads often need access to the same data. The challenge is not allowing multiple threads to access data. The challenge is allowing them to do so **safely**.

Without synchronization, concurrent accesses can lead to *race conditions*, *corrupted state*, *crashes*, or even subtle bugs that only appear once every few months. To solve this, programmers typically use **synchronization primitives** such as *mutexes*, *semaphores*, *spinlocks*, or *read-write locks*. These mechanisms work well and should generally be your default choice. In fact, in most projects you probably should not care about RCU at all.

However, some workloads are heavily biased toward reads. Imagine thousands of readers accessing a routing table while updates happen only occasionally. In such cases, even a relatively cheap lock can become a scalability bottleneck. This is precisely the kind of workload where paying a small cost during updates is preferable to making every packet lookup take a lock.

This is where RCU shines.

Instead of optimizing for writers, **RCU optimizes for readers**. The trade-off is that updates and memory reclamation become more complicated, but readers can often access data with little to no locking overhead.

## Theory

By my **oversimplified** interpretation, RCU works something like this:

Imagine multiple threads sharing an object. Readers simply access the currently published version of that object. When somebody wants to modify it, they do not update the object in place. Instead, they create a new version, apply their changes, and then atomically publish a pointer to the updated object. New readers will observe the new version, while existing readers may still be using the old one.

The obvious question then becomes:

> If some readers are still using the old object, when can we safely free it?

### More Formal Definition

Read-Copy Update (RCU) is a synchronization mechanism that allows readers and writers to access shared data concurrently.
Readers access the currently published version of an object inside a read-side critical section. Writers typically create a modified copy of the object, publish it atomically, and then wait for a grace period before reclaiming the old version.
The grace period guarantees that all readers that could have been referencing the old object have finished before the old memory is reclaimed.
This separation between **publication** and **reclamation** is what makes RCU different from many traditional synchronization mechanisms.

### What is a Quiescent State?

The atomic pointer swap is usually easy to understand. The difficult part is determining when old memory can be reclaimed.
This is where the concept of a **quiescent state** (QS) comes into play.

> A quiescent state is a point at which a thread or CPU is guaranteed to no longer be executing within an RCU read-side critical section that started earlier.

RCU uses quiescent states to determine when all pre-existing readers have completed. Once every participating thread or CPU has passed through a quiescent state, a **grace period** has elapsed and old data can be safely reclaimed.

The exact definition of a quiescent state depends on the implementation. The Linux kernel and userspace RCU libraries detect and track them differently, but the overall goal remains the same: **determine when old readers are gone**.

### Pros and Cons

Like every synchronization mechanism, RCU has strengths and weaknesses.

#### Advantages

* Extremely cheap reader path.
* Readers do not block writers.
* Excellent scalability on systems with many CPU cores.
* Particularly effective for read-mostly workloads.
* Can eliminate reader-side locking in many situations.

#### Disadvantages

* Updates are usually more expensive.
* Writers often need synchronization among themselves.
* Memory reclamation becomes significantly more complex.
* Not ideal for write-heavy workloads.
* Temporary memory usage increases because multiple versions may coexist.

The key idea is that RCU improves reader performance by pushing complexity toward updates and memory reclamation.

## Linux Kernel RCU Implementation

RCU existed before Linux, but the Linux kernel has arguably become its most famous and extensive user.
The kernel uses RCU in many performance-critical subsystems, including networking, process management, virtual filesystems, routing tables, and more.

Let's take a simplified look at how it works.

### 1. Access (Read)

Readers access RCU-protected objects inside an RCU read-side critical section.

```c
struct my_data *p;

rcu_read_lock();

p = rcu_dereference(global_ptr);

do_something(p->value);

rcu_read_unlock();
```

The workflow is straightforward:

1. Enter a read-side critical section.
2. Obtain a protected pointer.
3. Access the object.
4. Exit the critical section.

One interesting aspect of Linux RCU is that read-side sections are extremely lightweight. Depending on the RCU flavor and kernel configuration, `rcu_read_lock()` may compile down to very little code or even none.

This is one of the reasons RCU scales so well on large systems.

### 2. Update (Write)

Writers typically create a new version of the object instead of modifying the existing one in place.

```c
struct my_data *old;
struct my_data *new;

old = rcu_dereference_protected(global_ptr, true);

new = kmalloc(sizeof(*new), GFP_KERNEL);

*new = *old;
new->value = 42;

old = rcu_replace_pointer(global_ptr, new, true);

synchronize_rcu();

kfree(old);
```

The update process is usually:

1. Allocate a new object.
2. Copy the old state.
3. Apply modifications.
4. Publish the new pointer atomically.
5. Wait for a grace period.
6. Reclaim the old object.

### 3. Grace Periods and Quiescent States

The kernel must ensure that **every CPU that could have been executing an old reader has passed through a quiescent state**. Only then can it conclude that all pre-existing readers are gone. Different RCU flavors use different methods to detect this condition. Depending on the context, quiescent states may involve context switches, transitions to user mode, idle states, or other events recognized by the kernel.

Once all required quiescent states have been observed, the grace period ends and old memory becomes eligible for reclamation.
Although the concept sounds simple, modern kernel RCU contains a sophisticated distributed system for tracking grace periods efficiently across large CPU counts.

## What About Userspace?

Naturally, RCU is not limited to the Linux kernel.

One of the most mature userspace implementations is Userspace RCU (`liburcu`), which provides multiple RCU flavors optimized for different workloads and environments. Unlike the kernel, userspace applications cannot directly rely on scheduler internals to track quiescent states. As a result, userspace RCU implementations employ different techniques depending on the selected flavor.

Projects such as `QEMU` make extensive use of RCU to manage shared data structures efficiently while maintaining good scalability.

If you are interested in using RCU in your own applications, `liburcu` is usually the first place to look.

### A C++ Trick

I would not call this true RCU, but it is a useful pattern that I have used in some personal projects.

The idea is to combine atomic publication with `std::shared_ptr`.

Readers obtain a shared pointer to the currently published object. Writers construct a new object and atomically replace the old shared pointer.

```cpp
std::shared_ptr<T> get_obj() {
    return obj.load();
}

void set_obj(std::shared_ptr<T> obj_) {
    obj.store(std::move(obj_));
}

std::atomic<std::shared_ptr<T>> obj;
```

For pre-C++20, the non-member `std::atomic_load()` and `std::atomic_store()` functions can be used instead.

The nice thing about this approach is that memory reclamation becomes automatic. Once the last `shared_ptr` referencing the old object disappears, the object is destroyed.

The downside is that every reader must participate in reference counting. This introduces atomic operations on the reference count and can become a scalability bottleneck under heavy contention.

Real RCU avoids this overhead by using grace periods instead of reference counting, which is one reason it scales so well in highly concurrent systems.

Still, for many applications this pattern provides a simple and practical approximation of the RCU update model without introducing a dedicated RCU library.

## Conclusion

RCU is one of those ideas that appears almost trivial at first glance, yet turns out to be surprisingly deep once you explore the implementation details.

Its core goal is simple: allow readers to access shared data efficiently while enabling safe concurrent updates. The trick is not the pointer swap itself, but safely determining when old versions can be reclaimed.

By shifting complexity away from readers and toward updates and memory reclamation, RCU achieves excellent scalability for read-heavy workloads. This trade-off has made it a fundamental component of the Linux kernel and many other high-performance systems.

Hopefully this article gave you a useful introduction and sparked your curiosity to explore the topic further.

Thanks for reading, and see you in the next post :)

## Further Reading

* [What is RCU, Fundamentally? (series)](https://lwn.net/Articles/262464/)
* [Linux Kernel RCU Documentation](https://docs.kernel.org/RCU/index.html)
* [What is RCU? — Linux Kernel Documentation](https://docs.kernel.org/RCU/whatisRCU.html)
* [Linux Memory Barriers Documentation](https://docs.kernel.org/core-api/wrappers/memory-barriers.html)
* [Userspace RCU Project](https://liburcu.org/)
* [Is Parallel Programming Hard, And, If So, What Can You Do About It?](https://mirrors.edge.kernel.org/pub/linux/kernel/people/paulmck/perfbook/perfbook.html)
* [Paul E. McKenney's RCU Resources](https://paulmckrcu.wordpress.com/)
