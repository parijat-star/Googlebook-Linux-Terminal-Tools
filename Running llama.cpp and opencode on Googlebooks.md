# Running `llama.cpp` and OpenCode on Googlebooks

A guide to running local LLMs with **GPU acceleration** (`llama.cpp` via Vulkan / Virtio-GPU Venus) and **OpenCode** inside the Android **Linux Terminal** VM on **x86_64** and **ARM64** Googlebooks.

> **Note on "prebuilt APK" vs. Linux binaries:** Both `llama.cpp` and `opencode` run *inside* the Debian Linux Terminal VM, not as standalone Android `.apk` apps. You do **not** need to compile from source—both provide official prebuilt Linux binaries for `x86_64` and `arm64`.

---

## 1. Prerequisites: Improve the Terminal VM Experience

Before installing anything, configure the Android **Terminal** app so models fit in memory and can use the host GPU:

1. **Enable Graphics Acceleration:**
   - Open **Terminal** → **Settings** → enable **Graphics acceleration** (exposes the host GPU to the Linux VM via `Virtio-GPU Venus` / Vulkan).
   - Restart the Terminal VM if prompted.
2. **Increase VM Memory (8 GB+ recommended):**
   - Open **Terminal** → **Settings** → **Memory** (or VM RAM allocation) and increase it to at least **8 GB** (10 GB if your device has 16 GB+ host RAM).
   - *Why:* Quantized 2B–4B models (e.g., Gemma 4 E2B at ~2.6 GiB, E4B at ~4.3 GiB) plus Vulkan buffers and context KV cache will easily OOM or swap-thrash under the default smaller VM memory size.
3. **Store models and binaries on the VM's native disk (`~/`), not `/storage/emulated/10`:**
   - `/storage/emulated/10` is mounted via `virtiofs` / Android FUSE, which adds overhead for large reads and thousands of small files. Keep `~/llama-cpp` and `~/models` in your Linux home directory (`ext4`).

---

## 2. Two Ways to Work on Googlebooks

### Method A: Directly in the Linux Terminal App
Open the **Terminal** app on your Googlebook and run all commands interactively in the Debian shell.
- Best for interactive TUI tools like `opencode`, `llama-cli`, and running `llama-server` in a terminal tab or `tmux` session.

### Method B: Through Antigravity on Googlebooks
Antigravity runs on the Android host and automatically executes its shell commands inside the **Terminal** Linux VM.
- **Requirement:** Keep the **Terminal** app running so the VM is active.
- **Workflow:**
  1. Open your project folder (under `/storage/emulated/10/...`) in Antigravity.
  2. Ask Antigravity to run the installation, benchmark, or start `llama-server` in the VM for you.
  3. You can still open the **Terminal** app at any time to attach to the interactive `opencode` TUI in the same VM.

---

## 3. Install Prebuilt `llama.cpp` (x86_64 & ARM64)

Check your VM's CPU architecture first:
```bash
uname -m
```
- `x86_64` → Intel/AMD Googlebook (`ubuntu-vulkan-x64`)
- `aarch64` → ARM Googlebook (`ubuntu-vulkan-arm64`)

### Install Vulkan runtime tools (if not already present)
```bash
sudo apt-get update
sudo apt-get install -y curl tar vulkan-tools
```

### Download & extract the prebuilt Vulkan release
The script below automatically picks the right `ggml-org/llama.cpp` Vulkan tarball for `x86_64` or `aarch64` (tested with release `b12633`):

```bash
TAG="b12633"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ASSET="llama-${TAG}-bin-ubuntu-vulkan-x64.tar.gz" ;;
  aarch64) ASSET="llama-${TAG}-bin-ubuntu-vulkan-arm64.tar.gz" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

mkdir -p ~/llama-cpp && cd ~/llama-cpp
curl -fL -o "$ASSET" "https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/${ASSET}"
tar -xzf "$ASSET"
cd "llama-${TAG}"
```

> *(Optional)* Add `~/llama-cpp/llama-b12633` to your `PATH` in `~/.bashrc` so you can run `llama-cli`, `llama-server`, and `llama-bench` from anywhere.

---

## 4. Enable & Verify GPU Acceleration

### Step 1: Confirm Vulkan sees your GPU inside the VM
```bash
vulkaninfo --summary
```
Look for a `PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU` device using the **venus** driver, for example:
- `deviceName = Virtio-GPU Venus (Intel(R) Graphics (PTL))` (on Intel x86 Googlebooks)
- `Virtio-GPU Venus (...)` with your SoC's GPU on ARM64 Googlebooks

Then confirm `llama.cpp` sees it:
```bash
./llama-cli --list-devices
```
Expected output includes:
```text
Available devices:
  Vulkan0: Virtio-GPU Venus (...) (11660 MiB, 11660 MiB free)
```

### Step 2: Set the Vulkan allocation-size workaround
On Virtio-GPU Venus, large single-buffer Vulkan allocations can cause the VM to hang or reboot during model loading. Capping single Vulkan allocations to **256 MiB** avoids this in testing:

```bash
export GGML_VK_FORCE_MAX_ALLOCATION_SIZE=268435456
```
Add that line to `~/.bashrc` so it is always active.

### Step 3: Download a test model (Gemma 4 E2B)
```bash
mkdir -p ~/models && cd ~/models
curl -fL -o gemma-4-E2B-it-Q4_0.gguf \
  "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_0.gguf"
```

### Step 4: Benchmark GPU vs. Pure CPU
Run both commands from `~/llama-cpp/llama-b12633`:

```bash
export GGML_VK_FORCE_MAX_ALLOCATION_SIZE=268435456

# GPU (all layers offloaded to Vulkan0)
./llama-bench -m ~/models/gemma-4-E2B-it-Q4_0.gguf -ngl 99 -p 64 -n 16 -r 1

# Pure CPU baseline (important: include -dev none so Vulkan isn't used at all)
./llama-bench -m ~/models/gemma-4-E2B-it-Q4_0.gguf -ngl 0 -dev none -p 64 -n 16 -r 1
```

> **Tip:** Leaving out `-ngl` defaults to `-1` (offload all layers to GPU). Using `-ngl 0` *without* `-dev none` still sends some prompt-processing ops to the GPU, which skews CPU comparisons.

**How to confirm GPU acceleration is working:**
1. Startup logs show:
   - `load_backend: loaded Vulkan backend from .../libggml-vulkan.so`
   - `ggml_vulkan: 0 = Virtio-GPU Venus (...)`
2. In `llama-cli` / `llama-server` logs, you see `offloaded N/N layers to GPU`.
3. `llama-bench` shows substantially faster prompt processing (`pp64`) and faster token generation (`tg16`) with `-ngl 99` than with `-ngl 0 -dev none`.
   - *Reference on Intel Core Ultra 5 325 (x86_64):* **819.5 t/s** (`pp64`) / **24.9 t/s** (`tg16`) on Vulkan GPU vs. **125.1 t/s** (`pp64`) / **13.6 t/s** (`tg16`) on pure CPU.

---

## 5. Install OpenCode (x86_64 & ARM64)

OpenCode provides an official installer script that automatically detects `x86_64` or `arm64` on Linux:

```bash
curl -fsSL https://opencode.ai/install | bash
```
*(Alternatively, if you have Node.js installed: `npm install -g opencode-ai`)*

Reload your shell (`source ~/.bashrc`) and verify:
```bash
opencode --version
```

---

## 6. Connect OpenCode to `llama.cpp`

### Step 1: Start `llama-server` with GPU acceleration
In a Terminal tab (or background `tmux` session):
```bash
export GGML_VK_FORCE_MAX_ALLOCATION_SIZE=268435456
cd ~/llama-cpp/llama-b12633

./llama-server \
  -m ~/models/gemma-4-E2B-it-Q4_0.gguf \
  -ngl 99 \
  -c 8192 \
  --host 127.0.0.1 \
  --port 8080
```

Verify the server responds:
```bash
curl -s http://127.0.0.1:8080/v1/models
```

### Step 2: Configure `opencode.json` in your project directory
Create `opencode.json` in the root of your project:
```json
{
  "provider": {
    "llama": {
      "npm": "@opencode/provider-openai",
      "options": {
        "baseURL": "http://127.0.0.1:8080/v1"
      }
    }
  },
  "model": "llama/gemma-4-E2B-it-Q4_0"
}
```

### Step 3: Launch OpenCode
```bash
cd /path/to/your/project
opencode
```
Inside the OpenCode TUI, you can run `/models` to verify the local `llama.cpp` endpoint is selected and start coding offline.

---

## Troubleshooting

- **VM crashes or hangs when loading a model on GPU:** Make sure `export GGML_VK_FORCE_MAX_ALLOCATION_SIZE=268435456` is set, ensure VM RAM is ≥ 8 GB in Terminal settings, and avoid loading larger models (e.g. 4B+) right after a cold boot without the cap.
- **`opencode` or `llama-cli` command not found:** Check `echo $PATH` and add `~/.local/bin` / `~/llama-cpp/llama-b12633` to `~/.bashrc`.
- **Antigravity can't run commands:** Make sure the Android **Terminal** app is open/running so the Linux VM is booted.
