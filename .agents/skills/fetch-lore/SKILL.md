---
name: fetch-lore
description: Fetch Linux kernel mailing list messages, patches, and threads from lore links or Message-IDs.
---

# Lore Fetch

1. Extract the Message-ID from the lore URL or input.
2. Prefer `b4 mbox <MESSAGE_ID>` when a Message-ID is available.
3. Prefer machine-readable public-inbox endpoints:
   - `/raw` for a single message
   - `t.mbox.gz` for a thread
4. If lore.kernel.org is blocked by Anubis, do not bypass it. Use a public mirror or fallback archive instead.
5. Prefer fallbacks in this order:
   - public-inbox mirror
   - machine-readable mailing list archive
   - HTML archives such as Openwall, MARC, or Spinics
6. For patch series, keep patch revisions (`v2`, `v3`, etc.) separate and avoid mixing revisions.
7. If only the final merged code is needed, check the corresponding kernel Git commit.
8. Verify the Message-ID, subject, and patch revision before using the fetched content.

Avoid User-Agent spoofing, anti-bot bypasses, and HTML scraping when raw or mbox sources are available.
