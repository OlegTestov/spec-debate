import time

BUCKETS = {}


def allow(key, limit=100, window=60):
    """Return True if this key may perform one more action inside the window."""
    now = time.time()
    hits = [t for t in BUCKETS.get(key, []) if now - t < window]
    hits.append(now)
    BUCKETS[key] = hits
    return len(hits) <= limit
