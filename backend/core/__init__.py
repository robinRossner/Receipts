"""App-independent plumbing of the Receipts server: bearer auth with a failed-token throttle,
settings base (paths, API token, scheduler switch, Claude credentials), database helpers, log
redaction and the scheduler helper. Core never imports from `receipts`.
"""
