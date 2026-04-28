# Technical Analysis: Isolation Backends for AI Agent Sandboxes on AWS EKS

## Context

This analysis evaluates Kata + QEMU (current), Kata + Firecracker, Kata + Cloud Hypervisor, and gVisor as isolation backends for AI agent sandbox workloads on Amazon EKS. The workloads require: running arbitrary Python code, shell commands, package installation (pip/apt), persistent storage (EBS volumes), and strong multi-tenant isolation.

---

## 1. Kata + Firecracker Feasibility

### 1.1 Architecture Constraints

Firecracker is purpose-built for lightweight microVMs (it powers AWS Lambda and Fargate). Its minimalist design imposes two hard constraints relative to QEMU:

| Constraint | QEMU/CLH | Firecracker |
|---|---|---|
| Shared filesystem (virtio-fs) | Supported | **Not supported** |
| CPU/memory hotplug | Supported | **Not supported** |

**No virtio-fs**: QEMU and Cloud Hypervisor use virtio-fs to share the container image filesystem from the host into the guest VM. Firecracker's device model only implements virtio-net, virtio-block, and virtio-vsock -- there is no virtio-fs device. This means container images cannot be shared via a filesystem mount.

**No hotplug**: QEMU and CLH can dynamically add vCPUs and memory to a running VM. Firecracker requires all resources to be statically allocated at boot time (`static_sandbox_resource_mgmt = true` in `configuration-fc.toml`). This means the VM boots with its maximum CPU and memory allocation, and cannot scale up later.

### 1.2 Devmapper: Solving the Container Image Problem

Since Firecracker cannot use virtio-fs, container images must be delivered as **block devices**. This is where the devmapper snapshotter comes in.

**How it works:**

1. containerd is configured to use the `devmapper` snapshotter instead of the default `overlayfs` snapshotter.
2. The devmapper snapshotter stores container image layers as thin-provisioned block devices in a Device-mapper thin-pool.
3. When a container starts, the snapshotter creates a thin snapshot (a CoW block device) from the image layers.
4. Kata's Firecracker shim passes this block device directly to the microVM as a virtio-blk device.
5. The guest VM mounts the block device as its rootfs -- no shared filesystem needed.

**Thinpool configuration requirements:**

```bash
# Create sparse files for the thin-pool (development/testing)
sudo dd if=/dev/zero of=/var/lib/containerd/devmapper/data bs=1 count=0 seek=100G
sudo dd if=/dev/zero of=/var/lib/containerd/devmapper/metadata bs=1 count=0 seek=40G

# Create loop devices
DATA_DEV=$(sudo losetup --find --show /var/lib/containerd/devmapper/data)
META_DEV=$(sudo losetup --find --show /var/lib/containerd/devmapper/metadata)

# Create the thin-pool
sudo dmsetup create containerd-thinpool \
  --table "0 $(sudo blockdev --getsize $DATA_DEV) thin-pool $META_DEV $DATA_DEV 128 32768 1 skip_block_zeroing"
```

**containerd configuration (`/etc/containerd/config.toml`):**

```toml
[plugins."io.containerd.snapshotter.v1.devmapper"]
  pool_name = "containerd-thinpool"
  root_path = "/var/lib/containerd/devmapper"
  base_image_size = "10GB"
  discard_blocks = true
  fs_type = "ext4"
  async_remove = true
```

**Production considerations:**
- Loop-backed thinpools (sparse files) are suitable for development only. Production deployments should use a real block device (e.g., a dedicated EBS volume) as the thinpool backing store.
- A systemd service is required to recreate the loop device mappings on node reboot.
- The base_image_size (10GB default) determines the maximum size of each container's rootfs snapshot.
- At least 100GB free space is recommended for the data file to accommodate multiple container images and snapshots.

### 1.3 How EBS Works with Firecracker

This is a critical question. The answer: **EBS persistent volumes work with Firecracker because they are block devices, not shared filesystems.**

The flow is:

1. The EBS CSI driver provisions a gp3 volume and attaches it to the EC2 bare-metal instance as `/dev/nvme*`.
2. Kubernetes binds the PVC to the pod.
3. The Kata runtime (containerd-shim-kata-v2) detects that the volume source is a block device.
4. Instead of using virtio-fs to share a directory, Kata passes the block device directly to the Firecracker microVM as a virtio-blk device.
5. Inside the guest VM, the kata-agent mounts the block device at the requested mount path (e.g., `/home/node/.openclaw`).

**This entirely bypasses the virtio-fs limitation.** The virtio-fs constraint only affects how the container *image* (rootfs) is delivered to the guest. Persistent volumes that originate as block devices (which EBS volumes are) are passed through as virtio-blk devices regardless of hypervisor. This is why the blog states "EBS is compatible with Firecracker" -- EBS volumes are natively block devices, so they align with Firecracker's device model.

**Key distinction:**
- Container image delivery: requires devmapper (block-based) instead of virtio-fs (filesystem-based)
- Persistent volume (EBS): works directly as virtio-blk -- no special configuration needed beyond the devmapper snapshotter for images

**EFS with Firecracker:** EFS is NFS-based, not block-based. For EFS to work with Firecracker, the NFS mount would need to happen inside the guest VM (requiring network access to the EFS mount target) or be shared via a different mechanism. This is more complex than EBS and may not work out-of-the-box. EBS is the natural storage choice for Firecracker-based sandboxes.

### 1.4 Static Resource Allocation Implications

Since Firecracker cannot hotplug, you must configure:

```toml
[hypervisor.fc]
static_sandbox_resource_mgmt = true
default_vcpus = 2          # Fixed at boot
default_memory = 512       # Fixed at boot (MiB)
default_maxvcpus = 2       # Cannot exceed default_vcpus
default_maxmemory = 512    # Cannot exceed default_memory
```

**Impact on AI agent sandboxes:**
- You must estimate the peak resource requirement at pod creation time.
- Over-provisioning wastes memory (each VM holds its allocation). Under-provisioning causes OOM kills.
- For agent sandboxes with predictable workloads (running Python scripts, pip install), this is manageable. Set 1-2 vCPUs and 512MB-1GB memory.
- Kubernetes resource requests/limits should match the static allocation exactly.

### 1.5 Firecracker Performance Benefits

- **Boot time**: ~125ms (vs ~500ms+ for QEMU, ~200ms for CLH)
- **Memory overhead**: ~5MB per VM (vs ~30-130MB for QEMU)
- **Density**: Significantly more sandboxes per node
- **Creation rate**: Up to 5 microVMs per host core per second

For a warm-pool architecture where sandboxes are pre-created and assigned to users on demand, the boot time advantage is less critical. But the memory overhead advantage directly improves sandbox density on expensive bare-metal instances.

### 1.6 Firecracker Summary

| Aspect | Assessment |
|---|---|
| Container images | Requires devmapper snapshotter -- additional node configuration |
| EBS persistent volumes | Works natively via virtio-blk -- no special handling |
| EFS support | Complex -- NFS must be mounted inside guest or via workaround |
| Resource allocation | Static only -- must pre-size CPU/memory |
| Boot speed | Excellent (~125ms) |
| Memory overhead | Excellent (~5MB/VM) |
| Operational complexity | Higher (devmapper thinpool + systemd service + static sizing) |
| Maturity with Kata | Good -- actively maintained, used by AWS internally |

---

## 2. gVisor Feasibility

### 2.1 gVisor vs Kata: Fundamental Architectural Difference

**gVisor is NOT a Kata Containers backend. It is a completely different isolation technology.** They cannot be combined -- you choose one or the other.

| Aspect | Kata Containers | gVisor |
|---|---|---|
| Isolation mechanism | Hardware VM (KVM + hypervisor) | Userspace kernel (syscall interception) |
| Runtime binary | `containerd-shim-kata-v2` | `runsc` (containerd-shim-runsc-v1) |
| Guest kernel | Full Linux kernel in VM | Sentry (Go application implementing Linux syscall ABI) |
| Hardware requirement | Bare metal or nested virt | None (runs on any Linux) |
| OCI runtime type | `io.containerd.kata.v2` | `io.containerd.runsc.v1` |

**Kata** runs each pod in a real virtual machine with its own Linux kernel. The hypervisor (QEMU/Firecracker/CLH) provides hardware-level isolation via KVM.

**gVisor** intercepts application syscalls in userspace via the Sentry component. The Sentry re-implements a subset of the Linux kernel API in memory-safe Go code. The application never directly interacts with the host kernel. A separate Gofer process mediates all filesystem access.

### 2.2 gVisor Security Model vs Kata

**Kata (VM isolation):**
- Attack surface: hypervisor virtual device interface (small, well-audited)
- Escape requires: guest-to-host VM escape (hypervisor vulnerability)
- Kernel exposure: guest has its own kernel; host kernel sees only KVM ioctls
- Strength: hardware-enforced boundary; decades of x86 virtualization hardening

**gVisor (syscall filtering):**
- Attack surface: Sentry's syscall implementation (large but memory-safe Go code)
- Escape requires: Sentry vulnerability + seccomp escape + host kernel vulnerability
- Kernel exposure: Sentry uses ~70 host syscalls (vs ~300+ in a normal container)
- Strength: defense-in-depth (userspace reimplementation + seccomp + capability dropping)

**For multi-tenant AI agent sandboxes running arbitrary code**, Kata's VM boundary is stronger. A guest-to-host VM escape is a much harder exploit than a Sentry bug. However, gVisor provides meaningful isolation improvement over standard containers with much lower operational complexity.

### 2.3 gVisor on EKS

gVisor can run on EKS, but it is not natively supported like on GKE (which offers first-class "GKE Sandbox" integration).

**Setup on EKS:**

1. Deploy a DaemonSet that installs `runsc` and `containerd-shim-runsc-v1` on each node.
2. Update containerd configuration to register the `runsc` runtime handler.
3. Create a RuntimeClass:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
```

4. Pods specify `runtimeClassName: gvisor`.

**Platform selection on AWS:**
- gVisor's **systrap** platform (default since 2023) is recommended for VMs, including EC2 instances.
- The **KVM** platform offers better performance but requires `/dev/kvm` access, which is only available on bare-metal instances. Running gVisor's KVM platform inside a standard EC2 VM would be nested virtualization with poor performance.
- Standard EC2 instances (non-metal) work fine with the systrap platform -- **no bare-metal requirement** (unlike Kata).

### 2.4 gVisor Storage Support

**EBS volumes:** Work normally. gVisor's Gofer process mediates filesystem access between the sandbox and the host. Host-mounted volumes (including EBS-backed PVCs that Kubernetes has already mounted on the node) are exposed to the sandbox through the Gofer. No special configuration needed.

**EFS volumes:** Similarly work, since by the time gVisor sees them, they are already NFS-mounted directories on the host. The Gofer serves them to the sandbox.

**Limitation:** gVisor cannot mount block device filesystems (ext4, FAT32) *from within the sandbox*. This is irrelevant for typical Kubernetes volume usage where the kubelet handles mounting before the container starts.

### 2.5 gVisor Limitations for AI Agent Workloads

This is where gVisor faces real challenges:

| Capability | gVisor Support | Impact on Agent Workloads |
|---|---|---|
| Python execution | Good -- regression tested | Core agent functionality works |
| Shell commands (bash) | Good | Standard shell operations work |
| pip install | Generally works | May fail for packages with native extensions using unsupported syscalls |
| apt-get install | Generally works | Some packages may fail during post-install scripts |
| File system operations | Good via Gofer | Read/write/create/delete work normally |
| subprocess spawning | Good | Agent can spawn child processes |
| Networking (outbound HTTP) | Good | API calls, package downloads work |
| iptables | Partial | May affect packages that configure firewall rules |
| /proc and /sys | Partial | Some tools that inspect system state may break |
| io_uring | Not supported by default | Some high-performance I/O libraries may fall back to alternatives |
| cgroups enforcement | Accounting only | Resource limits enforced at host level, not within sandbox |
| Block device mount | Not supported | Cannot mount raw block devices from within sandbox |
| Custom hardware devices | Not supported | No GPU passthrough (except NVIDIA via special support) |

**The key risk for AI agents:** An agent running arbitrary code may encounter packages or operations that use unsupported syscalls. gVisor implements the "common path" but not every Linux syscall variant. Most Python packages work, but edge cases exist. When an unsupported syscall is hit, gVisor returns ENOSYS, and the application either falls back gracefully or crashes.

**Practical examples that may fail:**
- Packages using `io_uring` for async I/O
- System monitoring tools that read obscure `/proc` entries
- Containers trying to configure iptables/nftables rules
- Software using `prctl` with uncommon options
- Some `strace`/`ptrace`-based debugging tools

### 2.6 gVisor Summary

| Aspect | Assessment |
|---|---|
| Relationship to Kata | Alternative, not a backend -- mutually exclusive choice |
| EKS support | Works via DaemonSet + RuntimeClass; no native AWS integration |
| EBS support | Works -- Gofer mediates host-mounted volumes |
| EFS support | Works -- same Gofer mechanism |
| Hardware requirement | None -- runs on standard EC2 instances (no bare metal needed) |
| Security model | Userspace syscall interception -- weaker than VM boundary, stronger than containers |
| Python/shell support | Good for standard workloads |
| Package installation | Generally works, edge cases possible with native extensions |
| Boot time | Near-instant (no VM to start) |
| Memory overhead | Minimal (~15-50MB for Sentry/Gofer per sandbox) |
| Operational complexity | Low -- no hypervisor, no bare metal, no devmapper |

---

## 3. Cloud Hypervisor (CLH) -- The Middle Ground

Cloud Hypervisor deserves specific attention as it combines many of QEMU's features with better performance.

| Feature | QEMU | Cloud Hypervisor | Firecracker |
|---|---|---|---|
| virtio-fs | Yes | Yes | No |
| CPU hotplug | Yes | Yes | No |
| Memory hotplug | Yes | Yes | No |
| VFIO passthrough | Yes | Yes (hot + cold) | No |
| GPU support | Yes | No | No |
| Boot time | ~500ms+ | ~200ms | ~125ms |
| Memory overhead | ~30-130MB | ~10-20MB | ~5MB |
| Confidential computing | Yes (TDX, SEV-SNP) | No | No |
| Block device drivers | virtio-scsi, virtio-blk, nvdimm | virtio-blk | virtio-blk |
| Rootfs type | ext4, xfs, erofs | ext4, xfs, erofs | ext4, xfs, erofs |
| Architecture support | All (x86, ARM, s390x, PPC) | x86_64, aarch64 | x86_64, aarch64 |

CLH is explicitly positioned as a "modern replacement for QEMU" in the Kata ecosystem. It shares code lineage with Firecracker (both derive from crosvm) but adds the features Firecracker deliberately omits: virtio-fs, hotplug, and VFIO.

**For AI agent sandboxes, CLH is a drop-in replacement for QEMU** that provides:
- Same storage model (virtio-fs for images, virtio-blk for PVCs)
- Same hotplug capability (dynamic CPU/memory)
- Better boot time (~200ms vs ~500ms)
- Lower memory overhead (~10-20MB vs ~30-130MB)
- No devmapper required

The blog's current setup already enables CLH alongside QEMU via RuntimeClass differentiation.

---

## 4. Practical Recommendation

### Requirements Recap

The AI agent sandbox needs to:
1. Run arbitrary Python code
2. Execute shell commands
3. Install packages (pip, apt)
4. Mount persistent storage (EBS)
5. Provide strong multi-tenant isolation
6. Support warm pool / fast startup
7. Run on AWS EKS

### Recommendation: Cloud Hypervisor (Primary) + Firecracker (High-Density)

**Tier 1 -- Cloud Hypervisor (recommended default):**

CLH is the best overall choice for AI agent sandboxes. Rationale:

- **Full Linux kernel in guest**: Arbitrary Python code, shell commands, pip install, apt-get -- everything works because the guest runs a real Linux kernel, not a syscall reimplementation. Zero compatibility risk.
- **virtio-fs support**: No devmapper setup needed. Simpler node configuration than Firecracker.
- **Hotplug support**: Can right-size VMs dynamically. Start small, scale up if the agent needs more resources.
- **EBS works identically to QEMU**: Block devices pass through as virtio-blk.
- **Meaningful performance improvement over QEMU**: ~2.5x faster boot, ~3-6x less memory overhead.
- **Same operational model as current QEMU setup**: Swap `runtimeClassName: kata-qemu` to `kata-clh`. No infrastructure changes.
- **VM-level isolation**: Hardware-enforced boundary appropriate for running untrusted code from multiple tenants.

**Tier 2 -- Firecracker (for high-density scenarios):**

If sandbox density is the primary concern (hundreds of sandboxes per node) and you can accept:
- Higher operational complexity (devmapper thinpool management)
- Static resource allocation (must pre-size VMs)
- No EFS support (EBS only for persistent storage)

Then Firecracker's ~5MB overhead and ~125ms boot make it compelling. The warm pool pattern already mitigates the static allocation drawback -- pre-create VMs with a known resource profile, assign them on demand.

**Not recommended -- gVisor:**

While gVisor has the lowest operational barrier (no bare metal, no hypervisor), its syscall compatibility limitations create an ongoing risk for AI agent workloads. An agent that installs an arbitrary pip package and hits an unsupported syscall will fail in ways that are hard to debug and impossible to predict. For a sandbox that explicitly runs untrusted, arbitrary code, the full Linux kernel guarantee of VM-based isolation (Kata) is a significant advantage in both security and compatibility.

gVisor would be suitable if the agent workloads were well-known and tested against gVisor's compatibility matrix. For open-ended AI agent sandboxes, it is not the right choice.

**Not recommended as primary -- QEMU:**

QEMU remains a solid fallback with the best feature completeness (GPU passthrough, confidential computing). But for this workload, CLH provides every needed feature with better performance. Keep QEMU available as a RuntimeClass for edge cases requiring GPU or TDX/SEV-SNP.

### Decision Matrix

| Criterion | CLH | Firecracker | gVisor | QEMU |
|---|---|---|---|---|
| Arbitrary code compatibility | Excellent | Excellent | Risky | Excellent |
| Multi-tenant security | VM boundary | VM boundary | Syscall filter | VM boundary |
| EBS persistent storage | Yes | Yes | Yes | Yes |
| EFS support | Yes | Complex | Yes | Yes |
| Boot time | ~200ms | ~125ms | ~10ms | ~500ms+ |
| Memory overhead per sandbox | ~10-20MB | ~5MB | ~15-50MB | ~30-130MB |
| Operational complexity | Low | High (devmapper) | Low | Low |
| Bare metal required | Yes | Yes | No | Yes |
| Hotplug / dynamic sizing | Yes | No | N/A | Yes |
| Drop-in from current QEMU | Yes | No | No | Current |

### Migration Path

1. **Immediate**: Switch default RuntimeClass from `kata-qemu` to `kata-clh`. The blog already configures both. Validate with existing workloads.
2. **If density matters**: Add Firecracker as a third RuntimeClass for lightweight, short-lived sandboxes. Requires devmapper setup on nodes (Karpenter userData or custom AMI).
3. **Keep QEMU**: Available for GPU workloads or confidential computing if those requirements emerge.
