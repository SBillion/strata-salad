# strata-salad

[English](README.md) | [Français](README.fr.md)

Deploy [Strata](https://github.com/Niko1221/Strata) (Qwen3.8-Flash-Next, OpenAI/Anthropic-compatible API) on
[SaladCloud](https://salad.com) RTX 3090 container groups.

This repo packages four things:

| File | Role |
| --- | --- |
| `salad.sh` | SaladCloud REST CLI: build/push, deploy/update/start/stop/status/logs/recreate/delete |
| `salad-container-init.sh` | Container command (Salad overrides the `ENTRYPOINT`): defaults, IPv6→IPv4 `socat` relay, `exec` Strata's entrypoint |
| `salad-runtime-init.sh` | "Install at startup" variant from a generic image (no registry) |
| `.github/workflows/build.yml` | Engine image build on an **x86_64** runner + push to GHCR |

## How it works

The deployed image contains **only the Strata engine** (compiled for x86_64, CUDA arch 86). The model
(~40–70 GB) is **downloaded at container start**, into the instance's ephemeral disk.

`image_caching: true` (set by `salad.sh`) keeps the engine image cached on a node: subsequent
instances **on that node** don't re-pull the image; a reallocation to a **new** node re-downloads it.

> **No "baked" image (model embedded in the image): tried and abandoned.** The baked image
> (~100 GB in a single layer) systematically fails to start on SaladCloud
> (`Instance Start Failure: Other`), even with 250 GB of disk and an instance recreate; the
> non-baked image starts fine with the same configuration. All bake code
> (`Dockerfile.baked`, API bake B′, portal-terminal bake B″) has been removed from this repo.

## Prerequisites

- `bash`, `curl`, `jq`, `docker`.
- A SaladCloud account + an organization and a project (`SALAD_ORG`, `SALAD_PROJECT`).
- An image pushed to a registry Salad can read (GHCR/Docker Hub/ECR…).

## Quickstart

1. **Build the engine image** (x86_64 required, see "Building locally"): via GitHub Actions
   (*Actions → build-strata-image → Run workflow*), or on an x86_64 machine:

   ```sh
   export SALAD_IMAGE=ghcr.io/<user>/strata-salad:IQ2_XS
   ./salad.sh build && ./salad.sh push
   ```

2. **Deploy** (startup/liveness probes disabled, see below):

   ```sh
   export SALAD_API_KEY=...        # SaladCloud API key
   export SALAD_ORG=my-org
   export SALAD_PROJECT=my-project
   export SALAD_IMAGE=ghcr.io/<user>/strata-salad:IQ2_XS

   ./salad.sh gpu-classes          # check the "RTX 3090" class UUID
   SALAD_STARTUP_PROBE=0 SALAD_LIVENESS_PROBE=0 ./salad.sh deploy
   ./salad.sh status               # state + gateway URL
   ```

**Why disable the startup/liveness probes?** The first start downloads ~40–80 GB (~90–110 min at
~12 MB/s on a common node). A probe's maximum window is **60 minutes**: the `startup_probe` would
**restart** the container before the download finishes, and the ephemeral disk would lose the
download (endless loop). The `readiness_probe` alone never kills: it only gates traffic until the
model is ready.

## Commands

```sh
./salad.sh list                 # all container groups (name, state, URL)
./salad.sh deploy [NAME]        # create/update + start
./salad.sh update [NAME]        # change the config (PATCH, without starting)
./salad.sh start [NAME]         # start
./salad.sh stop  [NAME]         # stop
./salad.sh restart [NAME]       # stop then start
./salad.sh start-all            # start all groups in the project
./salad.sh stop-all             # stop all groups in the project
./salad.sh status [NAME]        # state + URL + instances
./salad.sh logs   [NAME]        # system logs
./salad.sh recreate [NAME]      # apply the current version WITHOUT re-pulling the image
./salad.sh delete [NAME]        # delete (irreversible, forces a re-pull afterwards)
```

- `update` (PATCH) keeps the group's **current** image/resources/model by default: only overridden
  fields change (via `SALAD_*`/`STRATA_*` env vars).
- **To apply a PATCH without rebuild/re-pull**: `update` then `recreate`. Salad's `recreate`
  endpoint destroys and restarts the container **on the same node**, image cached → no
  re-download. Avoid `delete` (it forces a re-pull).

## Runtime mode (no registry to feed)

Alternative: build/push nothing and let the container install Strata **at startup** from a public
generic image (`nvidia/cuda:13.0.0-devel-ubuntu24.04`):

```sh
export SALAD_IMAGE=nvidia/cuda:13.0.0-devel-ubuntu24.04   # public image, no push
SALAD_RUNTIME_BUILD=1 ./salad.sh deploy
```

`salad-runtime-init.sh` then does, inside the container: `apt` deps → `git clone` Strata → venv +
pip → `setup.py --setup --yes` (precompiled engine for RTX 30/40/50, otherwise compilation) →
model download → server.

| | CI image (recommended) | `SALAD_RUNTIME_BUILD=1` |
| --- | --- | --- |
| x86_64 build required | yes (once, in CI) | no |
| Registry to feed | yes (small: engine only) | no |
| Cost per new instance | model download | apt+pip+engine+model download |

> Salad's disk is **ephemeral**: in runtime mode, everything is redone on every new instance.
> Reserve this for testing.

## Model and resources (RTX 3090 defaults)

| Setting | Default | Note |
| --- | --- | --- |
| `STRATA_FAMILY` | `qwen` | `qwen` \| `swift` \| `coder` \| `unsloth` |
| `STRATA_MODEL` | `IQ2_XS` | `IQ2_XS` \| `Q2_0` \| `IQ3_XXS` \| `IQ3_S` |
| `STRATA_CONTEXT` | `32768` | |
| `STRATA_VISION` | `no` | `no` \| `cpu` \| `yes` |
| `STRATA_LOW_RAM` | `on` | see "Why LOW_RAM=on" below |
| `SALAD_CPU` | `8` | vCPU; **max 16** — setting **16** is the most useful lever in low-RAM |
| `SALAD_MEMORY_MB` | `61440` | 60 GB; **max ~61440 MB** on the API side |
| `SALAD_STORAGE_GB` | `120` | ephemeral disk |
| `SALAD_PRIORITY` | `high` | `high` \| `medium` \| `low` \| `batch` |
| `SALAD_NET_AUTH` | `true` | auth via Salad API key on the gateway |
| `STRATA_API_KEY` | (generated) | Strata server key (also injected as `STRATA_API_KEY`) |
| `STRATA_ALLOWED_HOSTS` | `auto` | `auto` = **this** group's gateway; csv; `.example.com`; `*` |

A 3090 (24 GB VRAM) handles Q2_0 and IQ2_XS; IQ3 sizes need more RAM/VRAM.
All variables are listed at the top of `salad.sh`.

### Why LOW_RAM=on ?

`setup.py` reads available RAM from **`/proc/meminfo`, i.e. the whole node's RAM**, not the
container's limit (Salad caps the instance at ~60 GB). Without `LOW_RAM`, setup believes it has
64-128 GB and plans to load 39-48 GB of experts **in RAM** (+ locking for the GPU): under the
container's cap, this goes OOM/thrash. `LOW_RAM=on` makes experts read from the **on-disk pack**
(`experts.bin`) instead of staying resident → small RAM footprint, fits under the cap.

Consequence: decoding is a bit slower (disk reads), but with 24 GB VRAM the GPU expert cache
absorbs the hottest ones. **More vCPU (up to 16) speeds up the CPU part** of the low-RAM path. If
your organization allowed >60 GB of RAM, you could switch to `LOW_RAM=off` (resident experts →
faster); at the documented 60 GB cap, keep `on`.

## Optimization

### Which model for an RTX 3090 (24 GB VRAM, 60 GB RAM, 16 vCPU) ?

In low-RAM, the **CPU** computes the experts the GPU doesn't keep. So **more vCPU = faster
decoding**, and it makes heavier models bearable.

| Model | Download | RAM | Expert area | Quality / speed |
| --- | --- | --- | --- | --- |
| `Q2_0` | 66 GB | 48 GB | 34 GB | fastest |
| `IQ2_XS` | 68 GB | 48 GB | 35.5 GB | recommended (balance) |
| `IQ3_XXS` | 76 GB | 60 GB | 43 GB | **best quality** fitting in 60 GB, slower |
| `IQ3_S` | 84 GB | **62 GB** | 50 GB | best quality but **exceeds 60 GB** → avoid |
| `coder` (IQ1_M) | 58 GB | 32 GB | 23 GB | for code, faster; weaker outside code |

- **Best realistic model here: `IQ3_XXS`** (RAM exactly at the 60 GB cap → tight; test it).
  Otherwise keep `IQ2_XS`.
- **`IQ3_S` not viable** at the 60 GB cap.
- **Code agent**: `STRATA_FAMILY=coder` (IQ1_M), fast and light, but weaker in general.

### Optimization levers (in order)

1. **`SALAD_CPU=16`**: the CPU part of low-RAM benefits directly (free, API max).
2. **`SALAD_MEMORY_MB=61440`** (already max): more resident experts = fewer disk reads.
3. **RAM > 60 GB?** if your org allows it: `STRATA_LOW_RAM=off` → resident experts, **the
   fastest** (but ~50 GB resident RAM).
4. **Context**: lowering `STRATA_CONTEXT` (e.g. `16384`/`8192`) shrinks the KV → more room for the
   GPU expert cache → faster. Keep `32768` if agents need a large context.
5. **`STRATA_KV=k8v4`** (INT8 K, 4-bit V): smaller KV in VRAM → more experts on the GPU.
6. **`SALAD_PRIORITY=high`**: more reliable/less interrupted nodes (costs more).
7. After a PATCH, the new version doesn't switch over by itself: **`./salad.sh recreate`**.
8. **`--parallel`** stays at 1 by default: on 24 GB, 2 simultaneous requests each slow down.
9. **`SALAD_CONVERSATION_CACHE_MIB=8192`**: multi-turn conversation cache (restarting long
   projects without re-reading ~90 % of the prompt). Written into the config at setup.

Example "max quality":
```sh
SALAD_CPU=16 STRATA_MODEL=IQ3_XXS STRATA_CONTEXT=32768 STRATA_KV=k8v4 \
SALAD_STARTUP_PROBE=0 SALAD_LIVENESS_PROBE=0 ./salad.sh deploy
```

## API access (Salad gateway + Strata server)

Two **independent** authentication layers, each with its own key:

| Layer | HTTP header | Key |
| --- | --- | --- |
| Salad gateway (`SALAD_NET_AUTH=true`) | `Salad-Api-Key` | **SaladCloud API key** (`SALAD_API_KEY`, portal) |
| Strata server (`api_key`) | `Authorization: Bearer` (client's `apiKey` field) | **Strata key** generated by `salad.sh` |

Gotcha: the Strata server reads **`STRATA_API_KEY`** (not `API_KEY`, which only feeds `setup.py`).
The init scripts propagate `API_KEY → STRATA_API_KEY` so the key set by `salad.sh` is actually
used by the server.

### DNS rebinding (403 "Host … is not allowed")

Without a server key, Strata only accepts known host names (DNS rebinding protection). Salad's
gateway relays requests with `Host: <group>.salad.cloud`, a name unknown to the server → **403**.
On deploy, `salad.sh` resolves the group's exact hostname (API field `networking.dns`) and sets
`STRATA_ALLOWED_HOSTS` to it. Accepted values:

- `auto` (default): only **this** container group's gateway;
- comma-separated list (`strata.example.com,nas.lan`); a dot prefix (`.example.com`) covers the
  domain and its subdomains;
- `*`: disables the check entirely (avoid).

With a Strata key (`STRATA_API_KEY`), the check is **disabled anyway**: the server does
`if svc.api_key or host_allowed(...)`. The allowlist only matters in no-server-key mode.

### OpenAI-compatible client

Endpoint: `https://<group>.salad.cloud/v1`, model reported by `GET /v1/models` (the name follows
`STRATA_MODEL`, e.g. `qwen3.8-flash-next-iq2_xs` or `qwen3.8-flash-next-iq3_xxs`). OpenCode example
(`~/.config/opencode/opencode.json`) — without a server key, `apiKey` is a dummy and the only auth
is the Salad header:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "saladcloud/qwen3.8-flash-next-iq2_xs",
  "provider": {
    "saladcloud": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Strata",
      "options": {
        "baseURL": "https://<group>.salad.cloud/v1",
        "apiKey": "dummy",
        "headers": { "Salad-Api-Key": "{env:SALAD_API_KEY}" }
      },
      "models": {
        "qwen3.8-flash-next-iq2_xs": {
          "name": "Qwen3.8 Flash Next (IQ2_XS)",
          "limit": { "context": 32768, "output": 8192 }
        }
      }
    }
  }
}
```

Verify access:

```sh
curl -H "Salad-Api-Key: $SALAD_API_KEY" "https://<group>.salad.cloud/v1/models"
```

> If the server has a Strata key (`STRATA_API_KEY`), put **that** key in `apiKey` (the client sends
> it as `Authorization: Bearer`) and keep `Salad-Api-Key` for the gateway.

## CI (GitHub Actions)

`build.yml` builds the engine image on an **x86_64** runner (required: the Strata engine compiles
native CPU code, AVX2/AVX-512) and pushes it to GHCR. Manual trigger: *Actions → build-strata-image
→ Run workflow* (choose the model, CUDA arch and Strata ref).

## Building locally

The engine's CPU code is compiled for the machine doing the build. From an ARM Mac, a
`linux/amd64` build via QEMU will likely produce an image unusable on Salad's nodes:
`salad.sh build` refuses until `SALAD_ALLOW_QEMU=1` is set. **Build on x86_64.**

## Known limitations

- **SaladCloud's gateway/probes communicate over IPv6.** Strata binds `0.0.0.0` (IPv4 only), so
  without a relay the `readiness_probe` **never** passes: the server runs (logs `ready: …`) but the
  gateway returns a 503 "SaladCloud" and the instance stays `ready=False`. Both init scripts
  install and run `socat TCP6-LISTEN:$PORT,ipv6only=1,fork TCP4:127.0.0.1:$PORT` for this.
  (Alternative: make Strata bind on `::`.)
- **Max 60 GB RAM** per instance → `LOW_RAM=on` by default.
- **`ulimit memlock` cannot be set** by Salad (no equivalent of `docker run --ulimit`):
  `salad-container-init.sh` tries to lift the limit; otherwise expect more page faults at load time.
- **Ephemeral disk**: the model is re-downloaded on every new instance; any change to the container
  group recreates the instance (an `update`/PATCH mid-download starts over) — configure everything
  **before** starting.
- **Cold start > probe window**: see "Quickstart" (`SALAD_STARTUP_PROBE=0 SALAD_LIVENESS_PROBE=0`).
- **Update = a "pending" version.** A PATCH creates a new version (`pending_change: true`) but Salad
  doesn't always replace the instance by itself: it keeps serving the old version. To force the
  switch **without re-downloading the image**, recreate the instance (`./salad.sh recreate`); this
  is what was used to apply the `allowed_hosts` fix. `salad.sh update` does not start the group, and
  a `start` may relaunch the old version while the new one is pending.
- **DNS rebinding / API keys**: see "API access" above (403 "Host … is not allowed",
  `STRATA_ALLOWED_HOSTS`, `API_KEY → STRATA_API_KEY` propagation).
- **`networking` cannot be changed after creation** (except `port`): `auth`, `load_balancer` and the
  timeouts are fixed at creation, otherwise the group must be recreated.

## Credits

Strata is a project by [Niko1221](https://github.com/Niko1221/Strata) (MIT). This repo only packages
it for SaladCloud.
