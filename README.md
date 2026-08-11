<p align="center">
  <img src="logo.svg" alt="Threadscope" width="88" height="88">
</p>

<h1 align="center">Threadscope</h1>

<p align="center"><strong>Measure which settings run local AI models fastest on your machine - then use them.</strong></p>

Everyone chasing better local LLM performance buys something: a faster GPU, more RAM, a
newer CPU, a smaller quantized model. Almost nobody checks whether their machine is
configured correctly first. That part is free.

Most inference engines start one thread per logical CPU by default. On a machine reporting
16 threads but holding only 8 real cores, the extra 8 don't add capacity - they queue behind
the first 8 and compete for the same memory bandwidth. On the machine this was built
against, correcting that made runs **32% faster while burning 2.4× less CPU**. Same
hardware, same model, same weights. Only settings.

Threadscope measures that curve on *your* hardware and tells you where the bottom is.

**Your number will differ from mine.** That is the entire reason the tool exists.

---

## How to use this repo

Two pieces, because a browser cannot measure a machine:

| File | Runs where | Does what |
|---|---|---|
| `threadscope.sh` | Your machine | Times your model at different settings → `report.json` + `tuning_recommendations.sh` |
| `index.html` | Any static host, or opened from disk | Reads the report, draws the charts, names the setting to use |

### What's in here

| File | Purpose |
|---|---|
| `threadscope.sh` | The measurement script - run this |
| `index.html` | The analyzer page - self-contained, host anywhere |
| `logo.svg` | Logo, used by the page and this README |
| `LOGO-PROMPTS.md` | Prompts for generating a replacement logo |
| `LICENSE` | MIT |
| `DISCLAIMER.md` | Full liability notice |

### Step 1 - measure

```bash
curl -fsSLO https://raw.githubusercontent.com/nikleotide/threadscope/main/threadscope.sh
chmod +x threadscope.sh
./threadscope.sh --build --fetch medium
```

That builds llama.cpp into `./llama.cpp` and downloads a 1GB test model into `./models`.
Already have a model? Skip both flags:

```bash
./threadscope.sh -m ~/models/your-model.gguf
```

Takes a few minutes. Needs no root. Keep the machine otherwise idle while it runs.

Every run is archived under `./runs/` with a timestamp, so running it again never overwrites
an earlier result:

```
runs/report-20260811-143201-Qwen2.5-1.5B-Instruct-Q4_K_M.json
runs/report-20260811-152640-after-tuning-Qwen2.5-1.5B-Instruct-Q4_K_M.json
```

Copies of the most recent run are also left in the working directory as `report.json` and
`tuning_recommendations.sh`, so the instructions below always point at the latest result.
Use `--tag` to label a run and `--outdir` to archive somewhere else.

### Step 2 - read the result

Open `index.html` (locally or from your hosting) and drop `report.json` onto it. You get the
sweep curve, a default-vs-best comparison, an efficiency plot, and a plain-language
explanation of what the numbers mean.

Everything happens in your browser. Nothing is uploaded.

### Step 3 - apply it

```bash
./tuning_recommendations.sh              # show what would change, change nothing
./tuning_recommendations.sh --apply      # apply it (asks for sudo)
./tuning_recommendations.sh --revert     # put everything back
```

### Publishing the page

`index.html` is one self-contained file with no backend, no build step and no dependencies.
Drop it on GitHub Pages, Netlify, or any shared hosting. Replace the `YOU` placeholder in the
curl command inside it with your GitHub username first.

The page ships with 12 themes in a dropdown. Change `data-theme` on the `<html>` tag to set
the default.


---

## Command-line options

| Flag | Meaning |
|---|---|
| `-m, --model PATH` | GGUF model to test |
| `-b, --bin PATH` | Path to `llama-cli` if it isn't found automatically |
| `-n, --tokens N` | Tokens generated per run (default 128) |
| `-o, --out PATH` | Exact JSON path, overriding the archive naming |
| `--outdir DIR` | Where runs are archived (default `./runs`) |
| `--tag NAME` | Label a run, e.g. `--tag before-tuning` |
| `--build` | Clone and build llama.cpp into `./llama.cpp` |
| `--fetch SIZE` | Download a test model: `small` 0.4GB · `medium` 1GB · `large` 2GB |
| `--fetch-url URL` | Download a GGUF from your own host instead |
| `--quick` | Roughly half the sample points |

## Platform support

| | Thread sweep | CPU pinning | Huge pages | Governor |
|---|---|---|---|---|
| **Linux** | yes | yes | yes | yes |
| **macOS** | yes | no user-level API | n/a | n/a |
| **Windows** | via WSL | via WSL | via WSL | via WSL |

---

## What it reads

None of these are modified. They are read to describe the machine and to decide what to
suggest.

| Value | Source |
|---|---|
| CPU model name | `/proc/cpuinfo` |
| Logical CPU count | `getconf _NPROCESSORS_ONLN` |
| Threads per core → physical cores | `lscpu` |
| Physical core list, used for pinning | `lscpu -p=CPU,CORE` |
| NUMA node count | `lscpu` |
| Total RAM | `/proc/meminfo` |
| Transparent huge pages state | `/sys/kernel/mm/transparent_hugepage/enabled` |
| CPU frequency governor | `/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` |
| Virtualization / WSL | `systemd-detect-virt`, `/proc/version` |
| Kernel and OS | `uname` |
| Whether `taskset` exists | `command -v` |
| Model filename and size | the file itself |

On macOS, CPU brand, core counts and RAM come from `sysctl`. Huge pages, governor and
pinning do not exist there and are reported as `n/a`.

## What it measures

Four numbers per timed run:

- **Wall clock** - how long the run actually took
- **User CPU time** - processor seconds spent computing
- **System CPU time** - processor seconds spent in the kernel
- **Tokens per second** - read from llama.cpp's own output, or computed as tokens ÷ wall
  time when the engine doesn't report it

Configurations timed, on a 16-thread / 8-core machine as an example:

- One warm-up run, discarded. This pulls the model off disk so that one-off I/O doesn't
  pollute the first real measurement.
- Unpinned at **1, 2, 4, 8, 16** threads - powers of two, plus your physical and logical core
  counts, deduplicated and sorted.
- Pinned at the winning thread count, and at your physical core count if that differs.

About seven runs in total. `--quick` roughly halves it.

## What it recommends

**Measured** - the tool timed both options and picked the winner:

1. **Thread count** - `-t N`
2. **CPU pinning** - `taskset -c 0,1,2,…`, recommended only if the pinned run actually beat
   the unpinned run at the same thread count

**Inspected, not measured** - it read your current value and suggested the generally-faster
one without testing whether it helps on your hardware:

3. **Transparent huge pages** → `always`
4. **CPU frequency governor** → `performance`

**Flagged only, no action taken:**

5. More than one NUMA node → mentions `numactl --localalloc`
6. Running virtualized → warns that pinning may not map to real cores

That measured-versus-inspected split is the most important thing to understand about this
tool, and it is stated in the header of every generated script.

## What `--apply` actually changes

Only items 3 and 4 above. Items 1 and 2 are not system changes at all - they are flags on
your own command line.

| Setting | Change | Needs | Reverts |
|---|---|---|---|
| Transparent huge pages | to `always` | sudo | on reboot, or `--revert` |
| CPU frequency governor | to `performance` | sudo | on reboot, or `--revert` |

Original values are saved to `~/.threadscope-revert` before anything is touched.

Setting the governor to `performance` keeps CPU clocks high, which means more power draw and
more heat. On a laptop that shortens battery life. This is how the setting is supposed to
behave, not a fault.

## What it writes to disk

- `runs/report-<timestamp>[-<tag>]-<model>.json` - the measurements, archived
- `runs/report-<timestamp>[-<tag>]-<model>.tuning.sh` - the suggestions, archived
- `report.json` and `tuning_recommendations.sh` - copies of the most recent run
- `./llama.cpp/` - only with `--build`
- `./models/` - only with `--fetch` or `--fetch-url`
- `~/.threadscope-revert` - only when you run `--apply`

The only `rm` commands anywhere in the script delete its own temporary log, its own revert
file, and a partial download that failed.

## What it does not touch

GPU settings, batch size, context size, KV cache, mmap or mlock, BLAS backend, swappiness,
I/O scheduler, IRQ affinity, C-states, turbo, services, packages, configuration files, or
the bootloader. It never transmits anything anywhere.

---

## Known gaps

**Huge pages and governor are assumed, not tested.** The governor could be measured properly
without much work. Huge pages would need `sudo` partway through a run, which would break the
no-root property that makes this safe to run casually - so they stay labelled as
suggestions rather than findings.

**One model at a time.** The optimum can shift with model size and quantization. If you run
several models regularly, measure the one you use most.

**CPU only.** If your model runs entirely on a GPU, the processor mostly waits on the card
and these settings have little effect.

**Not a hardware fix.** The ceiling on CPU inference is memory bandwidth, which no setting
can raise. What this closes is the gap between how your machine is configured and how it
could be - often substantial, and always free.

## Reporting problems

Open an issue and attach `report.json` along with your hardware and OS. If the JSON itself
looks malformed, re-run the script - it validates its own output and will say so.

---

## Licence and liability

MIT. Copyright © 2026 Hamid Nikbakht. See [`LICENSE`](LICENSE).

**No warranty of any kind.** Threadscope measures and suggests. You run it, and act on its
recommendations, entirely at your own risk. The author accepts no liability for any damage,
data loss, downtime, hardware fault or other harm arising from its use. The full notice is in
[`DISCLAIMER.md`](DISCLAIMER.md).

Threadscope runs [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) and can download
model files from third-party hosts. Those carry their own licences and terms - model weights
in particular may restrict commercial use. Check the licence of any model you use.

---

### If this tool helped you: do something kind for someone else. That is the whole price.
