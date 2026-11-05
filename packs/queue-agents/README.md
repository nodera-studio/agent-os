# Pack: queue-agents (background-job specialists)

Two agents for projects that run queues, workers or other async pipelines. They are generic templates: adapt the
queue library, the processor directory and the retry semantics to what the project actually runs. Projects without
queues should not install them.

```bash
./install.sh <target> --pack queue-agents
./install.sh <target> --remove-pack queue-agents
```

| File | Role |
| --- | --- |
| `agents/debug/queue.md` | `/deep-debug` specialist for stalled jobs, stuck processing and worker issues; dispatched in place of `investigator.md` for an async-pipeline bug |
| `agents/codebase/error-audit/queue.md` | `/error-audit` scanner for queue processors, the error-to-user path of the processing pipeline and concurrent operations |

Without the pack, `/error-audit` skips its queue agents (the orchestrator says so in the report instead of
dispatching a stub) and `/deep-debug` uses the general investigator.
