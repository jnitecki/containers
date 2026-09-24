# ollama

[Ollama](https://ollama.com) LLM server for NVIDIA Jetson devices (JetPack 6, L4T r36.x, `arm64`), built on top of [`dustynv/ollama`](https://hub.docker.com/r/dustynv/ollama) with an up-to-date Ollama release installed over it for GPU-accelerated inference.

## Requirements

- An NVIDIA Jetson device running JetPack 6 (L4T r36.x).
- The NVIDIA Container Toolkit, so the container can be started with `--runtime nvidia`.

## Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `OLLAMA_HOST` | `0.0.0.0` | Address the Ollama API listens on. |
| `OLLAMA_MODELS` | `/data/models/ollama/models` | Directory where pulled models are stored. |

Any other [Ollama environment variable](https://github.com/ollama/ollama/blob/main/docs/faq.md) (e.g. `OLLAMA_KEEP_ALIVE`, `OLLAMA_NUM_PARALLEL`) can be passed with `-e` as well.

## Ports

| Port | Purpose |
|------|---------|
| `11434` | Ollama HTTP API. |

## Volumes

| Path | Purpose |
|------|---------|
| `/data/models/ollama/models` | Pulled models — mount a host directory here so models survive container re-creation. |

The container starts the Ollama server and then an interactive shell, so it must be run with a TTY (`-t`, together with `-i`) to stay up in the background:

```sh
docker run -dit --name ollama --restart unless-stopped \
           --runtime nvidia \
           -p 11434:11434 \
           -v /path/to/models:/data/models/ollama/models \
           docker.io/jnitecki/ollama:latest
```

Pull and run a model inside the running container:

```sh
docker exec -it ollama ollama run llama3.2
```
