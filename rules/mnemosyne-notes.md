---
# Loaded only while a plan or auto-mode state file is touched; the Mnemosyne plugin skill covers everything else.
paths:
  - ".claude/auto-mode/**"
  - ".claude/plans/**"
---
Mnemosyne workspace queue workaround (a server bug, kept until it is fixed):

- `queue_item_add` and `queue_item_update` accept a `documentId` only for Ideas, Notes and Research
  documents. Never pass a board issue id as `documentId`. The server answers `INVALID_REQUEST` but
  still persists a broken row that makes `queue_get` and the web queue page fail; the only recovery
  found was deleting and recreating the queue.
- Put the issue's label and id in the item title instead: `<wave> — <summary> (<issue id>)`.
