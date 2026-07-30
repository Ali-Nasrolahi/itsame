---
title: "Brief Look At Linux Traffic Control"
date: 2026-07-29T15:52:37Z
draft: false
description: "An intuitive introduction to Linux Traffic Control (TC), explaining the mental model behind qdiscs, classes, filters, and actions."
tags: ['linux', 'network']
---


## Abstract

Traffic Control (`TC`) is one of those Linux subsystems that almost everyone has heard of, yet
to many, including me, is a bit complicated and confusing.

Historically, TC was designed for traffic shaping, bandwidth control, queue management, etc.
Today, however, it has grown into a much more flexible framework. With features such as packet
classification, actions, and even eBPF integration, TC is capable of solving far more than just
traffic shaping problems.

Although TC has existed for many years and is fairly documented, I often found myself jumping
between man pages, kernel source, and blog posts before the pieces finally started to fit together.
This article is an attempt to organize those pieces into the mental model which I hope will help
clarify one of the most sophisticated parts of the Linux networking stack.

---

## Where Does TC Live in the Networking Stack?

Before talking about TC-specific terms, it helps to understand where TC actually sits in the Linux's
networking stack.

The exact packet path inside the Linux kernel is much more involved than what I'll show here, but
for the purpose of understanding TC, we should be able to ignore many protocol-specific details.

On the **egress** side: (1) packets originate from an application and eventually make their way through
the networking stack. After (2) routing and firewall decisions have been made, (3) packets arrive at TC.
Once TC finishes processing them, they're handed to the (4) NIC driver and (5) eventually transmitted on the
wire.

On the **ingress** side, the process happens in reverse. Packets arrive from the NIC driver and are
handed to TC before continuing further up the networking stack.

The important takeaway isn't memorizing the packet path. It's understanding **why** TC lives where
it does. Since every packet passes through TC on both ingress and egress, it has an opportunity to
inspect, classify, delay, redirect, or even drop packets before they continue their journey.

---

## The Building Blocks of TC

One thing that confused me when I first started learning TC was that everyone immediately started
talking about `qdiscs`, `classes`, `filters`, and `actions`. These building blocks are one of the
reasons why TC is so flexible.

### Qdisc: Who Decides When Packets Leave?

Imagine applications generating packets faster than the network can transmit them. Those packets
have to wait somewhere (happens because CPUs are much faster than network interfaces).

That "somewhere" is managed by a `queueing discipline`, or `qdisc`.

Every network interface has at least one qdisc attached to it, even if you've never configured TC
yourself. Linux automatically creates a default one for every interface.

At its core, a qdisc performs two simple operations:

- **enqueue**: accept a packet
- **dequeue**: decide when to release it

Everything else such as traffic shaping, bandwidth limiting, fairness, prioritization, congestion
management, is ultimately built on top of these two.

A useful mental model is simply:

> A `qdisc` decides **when** packets leave.

That may sound like a small responsibility, but by controlling *when* packets leave, a qdisc can
smooth traffic bursts, enforce bandwidth limits, prioritize latency-sensitive traffic, or prevent
one application from monopolizing the entire link.

---

### Classes: What If Not All Traffic Is Equal?

Once you understand qdiscs, another question naturally appears.

> What if not all traffic should be treated the same?

Perhaps you want SSH traffic to remain responsive while a large backup is running. Or maybe
different containers should receive different bandwidth guarantees.

This is where **classes** come in.

One thing that tripped me up initially was thinking that a class was another queue. It isn't.

Instead, you can think of a class as a **traffic policy**. A class describes things such as
bandwidth guarantees, rate limits, priorities, and borrowing rules.

Classes only exist inside **classful qdiscs**, such as `HTB` or `HFSC`. These qdiscs support
hierarchical scheduling, allowing multiple classes to coexist under a single qdisc.  Each class can
even have another qdisc attached beneath it, making it possible to build fairly flexible scheduling
hierarchies.

The distinction that finally made sense to me was this:

> `Classes` describe **how traffic should be treated**.  
> `Qdiscs` decide **when packets are transmitted**.

---

### Filters: How Does TC Know Where Packets Belong?

Once multiple classes exist, another question immediately follows.

> How does TC decide which packets belong to which class?

That's the job of `filters` (also called `classifiers`).
A filter examines packet metadata and decides where the packet should go.

```text
packet
   │
   ▼
filter
   │
   ▼
class
```

TC provides several different classifiers, each suited to different workloads:

| Type       | Description                                                    |
| ---------- | -------------------------------------------------------------- |
| `u32`      | match arbitrary fields inside packet headers                   |
| `flower`   | match common protocol fields such as MAC, IP, ports, VLAN, etc |
| `cls_bpf`  | perform classification using an eBPF program                   |
| `fw`       | classify packets using firewall marks                          |
| `matchall` | match every packet                                             |

---

### Actions: Actually Doing Something

Classification alone isn't particularly interesting. Very often, matching a packet is only the
beginning.  Once a filter matches, we usually want to **do something** with that packet. That's
exactly what `actions` are for.

```text
filter matches
        │
        ▼
     action
```

Some common actions include:

| Action     | Description                     |
| ---------- | ------------------------------- |
| `drop`     | discard the packet              |
| `redirect` | forward it to another interface |
| `mirror`   | clone the packet for monitoring |
| `police`   | enforce a rate limit            |

This is one of the reasons TC has become much more than a traffic shaping framework. By combining
filters with actions, TC can implement packet mirroring, policy-based forwarding, traffic policing,
encapsulation, and many other networking features.

---

## At a Glance

| Component  | Responsibility                                                            | Example                                           |
| ---------- | ------------------------------------------------------------------------- | ------------------------------------------------- |
| **Qdisc**  | Decides **when** packets are transmitted                                  | HTB, HFSC, FQ-Codel                               |
| **Class**  | Describes **how** traffic should be treated (bandwidth, priority, limits) | VoIP class with guaranteed 1 Mbit/s               |
| **Filter** | Decides **where** a packet belongs by inspecting its metadata             | Match packets destined for port 5060 → VoIP class |
| **Action** | Defines **what** happens to a matched packet                              | Drop, redirect, mirror, police                    |

## Putting It Into Practice

Let's put everything we've discussed together with a simple example.

Imagine a small office where employees are making VoIP calls while someone else is uploading a large
backup. Without any traffic management, the backup can easily consume most of the available
bandwidth. While both applications continue to work, the increased latency and jitter can noticeably
affect call quality.

Our goal is simple:

> prioritize VoIP traffic while still allowing the backup to use whatever bandwidth remains.

The first thing we need is a **qdisc**. Since packets may have to wait before they can be
transmitted, something has to decide **when** they're allowed onto the wire. That's exactly the
responsibility of the qdisc.

```text
                Root qdisc
```

Next, we see that not all traffic should be treated equally. Voice packets deserve higher
priority than a bulk file transfer, so we divide our traffic into separate **classes**.

```text
                Root qdisc
               /          \
      VoIP Class      Best-effort Class
```

Of course, TC has no way of knowing which packets belong to each class on its own. That's where
**filters** come in. They inspect incoming packets and classify them into the appropriate traffic
class.

```text
            Incoming Packet
                    │
                    ▼
                 Filter
               /         \
      VoIP Packet     Backup Packet
           │                │
           ▼                ▼
     VoIP Class      Best-effort Class
```

Finally, we may want to perform additional processing once a packet has been classified. For
example, we could police traffic that exceeds a certain rate, mirror packets for monitoring, or
redirect them elsewhere. These operations are implemented as **actions**, allowing TC to do much
more than simply decide where packets belong.

One interesting thing to notice is that we never configured a "VoIP scheduler" or a "backup
scheduler." Instead, we built our traffic policy by combining several independent building blocks.
The qdisc decides **when** packets are transmitted, classes describe **how** different traffic
should be treated, filters decide **where** packets belong, and actions define **what** happens
to matching packets.

Our example also only uses a single level of classes, but that's not a limitation of TC. Since
classes can themselves have child qdiscs attached, the same building blocks can be used to build
much larger traffic hierarchies.

```text
                    Root qdisc
                         │
          ┌──────────────┴──────────────┐
          │                             │
     VoIP Class                 Best-effort Class
                                        │
                               Child qdisc
                                  │
                     ┌────────────┴────────────┐
                     │                         │
                  Web Traffic          Backup Traffic
```

This flexibility is one of TC's greatest strengths. Rather than being a single traffic shaping
algorithm, TC provides a framework for constructing packet processing pipelines, from simple
policies like the one above to sophisticated hierarchical schedulers used in production networks.

---

## Conclusion

TC is one of those Linux subsystems that initially feels far more complicated than it actually is.
At first glance, the terminology alone can make it seem overwhelming. In reality, each concept has a
well-defined responsibility, and the complexity comes from how these building blocks can be used
together.

Rather than being a single traffic shaping algorithm, TC provides a flexible framework for building
packet processing pipelines. Whether your goal is bandwidth management, packet scheduling, traffic
classification, or packet manipulation, the same core concepts remain the foundation.

Thanks for reading, and see you in the next :)

---

## Further Reading

- [Linux Traffic Control HOWTO](https://tldp.org/HOWTO/Traffic-Control-HOWTO/)
- [tc(8) — Linux Manual Page](https://man7.org/linux/man-pages/man8/tc.8.html)
- [Linux Advanced Routing & Traffic Control HOWTO](https://lartc.org/)
- [Kernel Networking Documentation](https://docs.kernel.org/networking/index.html)
- [Linux Networking Documentation (netdev mailing list and resources)](https://docs.kernel.org/process/maintainer-netdev.html)
- [iproute2 Source Code](https://github.com/iproute2/iproute2)
- [Linux Kernel Source — net/sched](https://github.com/torvalds/linux/tree/master/net/sched)
