---
title: "Introducing Mock: A Supercool RPM Builder"
date: 2025-10-17T16:56:55Z
draft: false
description: "Mock: Building RPMs in Clean and Reproducible Environments"
tags: ['rhel', 'rpm']
---

## Introduction

If you’ve worked with RHEL, Rocky, CentOS, or any of their downstreams, you’ve already seen **RPMs** — the standard way to distribute binaries in these ecosystems. They provide version tracking, dependency management, and consistent build and install rules across systems.

To build these packages cleanly, you usually want a reproducible environment that behaves exactly like your target system. That’s where **`mock`** (also known as `mockbuild`) comes in.

`mock` builds RPMs inside an isolated chroot (or container) environment. It installs all build dependencies automatically and ensures the resulting packages are built in a clean, minimal system. This eliminates the usual “it built fine on my machine” issue.

It’s also worth mentioning **Koji**, Fedora and RHEL’s official build system. Koji actually *uses* mock internally — the main difference is that Koji provides a distributed build farm with authentication, scheduling, and artifact management, while `mock` is the local standalone piece of that puzzle.

I’ve been using `mock` for tasks like rebuilding the RHEL kernel with local patches, building custom modules, and backporting packages from RHEL 9 to 8. It’s a solid tool once you get used to it, though not without its small annoyances.

---

## Background

Before diving deeper into `mock`, it’s worth understanding how an RPM build happens in the first place.

RPM builds are driven by **spec files**, which describe how to prepare, patch, build, install, and package the software.
They define everything from dependencies to `%prep` and `%install` stages. If you want to explore spec syntax, the [RPM spec manual](https://rpm.org/docs/6.0.x/manual/spec.html) is a great reference.

When building software, you usually start with a **source RPM (SRPM)** — a package that contains the original source code, patches, and the spec file. Building an SRPM produces binary RPMs, following these general stages:

1. **Preparation:** Extract source, apply patches.
2. **Build:** Compile the source code.
3. **Install:** Stage built files into a temporary directory tree.
4. **Package:** Create the final `.rpm` files with metadata and scripts.

This process is handled by `rpmbuild` in a local environment, or by `mock` in a clean, reproducible one.

---

## My Verdict

I used `mock` to build a patched RHEL kernel and some custom modules, and also to backport a few userspace packages. I’m still exploring some of its deeper internals, so I might miss certain nuances, but overall it’s been a useful and dependable tool.

### Positives

* **Clean environment:** every build happens in an isolated chroot or container.
* **Reproducibility:** ensures packages build correctly on a vanilla system.
* **Container (podman/docker) and chroot modes:** flexible for different setups.
* **Automation:** automatically installs build dependencies and sets up everything for you.

### Negatives

* **Documentation:** it has a very good man page, but the configuration explanations aren’t particularly enjoyable to read, and the lack of concrete examples makes things a bit painful.
* **Customization:** adding custom repositories, doing chain builds, or preparing staged builds for dependent packages can be slightly annoying. It’s possible, but not as straightforward as it should be.

---

## Practice: Patching the RHEL Kernel

Here’s a short walkthrough of using `mock` to patch and rebuild the RHEL kernel.

1. **Download the kernel source RPM**

   ```bash
   dnf download --source kernel-core
   ```

   You’ll get something like following on RHEL9:
   `kernel-5.14.0-...el9_6.src.rpm`

2. **Extract and prepare the source**

   ```bash
   rpmbuild -bp kernel-....src.rpm
   ```

   This extracts and prepares the kernel source tree.

3. **Create your patch**
   Make the changes you want in the source tree, then create a patch using `diff`.

4. **Update the spec file**
   Add your patch to the list under `Patch` entries and include it in the `%prep` section.
   Also update the version/release and changelog.

5. **Build the new source RPM**

   ```bash
   rpmbuild -bs kernel.spec
   ```

6. **Build with mock**

   ```bash
   mock kernel-<new-version>.src.rpm
   ```

   Then wait for the build to complete — kernel builds take time.
   When it’s done, you’ll find the resulting binary RPMs under your result directory.

---

## Useful Notes

While debugging builds, I found a few options that help a lot:

1. **Avoid cleanup:**
   By default, `mock` cleans the buildroot before and after each build.
   Use:

   ```bash
   mock -n   # skip cleanup before
   mock -N   # skip cleanup after
   ```

   to save time during iterative testing.

2. **Install packages inside buildroot:**

   ```bash
   mock -i <package>
   ```

   useful for installing debug tools without resetting the environment.

3. **Run DNF inside buildroot:**

   ```bash
   mock --dnf-cmd "dnf makecache"
   ```

4. **Skip bootstrap stage:**

   ```bash
   mock --no-bootstrap-chroot
   ```

   This reduces the build process to a single stage, making it faster for test runs.

5. **Directory options:**

   * `--resultdir`: output location for built RPMs
   * `--configdir`: location of configuration files
   * `--rootdir`: chroot/container root path

6. **Man page:**
   Honestly, `man mock` is still the most complete and accurate documentation.

---

## Closure

Thanks for reading. I wrote this mostly to document my own experience using `mock` and the small details that helped me along the way.
If you’ve worked on similar setups or have better approaches, feel free to reach out — always happy to discuss.

---

## References

* [Using Mock to Test Package Builds (Fedora Wiki)](https://fedoraproject.org/wiki/Using_Mock_to_test_package_builds#What_is_Mock)
* [Mock Official Documentation](https://rpm-software-management.github.io/mock/)
* [Rocky Linux Legacy Mock Guide](https://wiki.rockylinux.org/archive/legacy/mock_building_guide/)
* [Koji Documentation](https://docs.pagure.org/koji/)
* [Using the Koji Build System (Fedora Docs)](https://docs.fedoraproject.org/en-US/package-maintainers/Using_the_Koji_Build_System/)
* [Koji (Fedora Wiki)](https://fedoraproject.org/wiki/Koji)
* [Koji Source (Pagure)](https://pagure.io/koji)
