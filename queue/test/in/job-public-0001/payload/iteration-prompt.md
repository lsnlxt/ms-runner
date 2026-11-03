# Dry-run fixture prompt

This file exists only so `process_job` finds the prompt it requires.

In a real run this is the iteration prompt handed to the executor. In `--dry-run`
the executor is never invoked, so the content is irrelevant — its existence is
what matters.
