---
name: fetch-lore
description: Fetch Linux kernel mailing list messages and patches reliably. Use when reading lore.kernel.org links, Message-IDs, or kernel mailing list threads.
---

# Lore Fetch

1. Prefer `b4 mbox <MESSAGE_ID>` when a Message-ID is available.
2. Prefer public-inbox raw endpoints such as `/raw` or `t.mbox.gz` over HTML scraping.
3. If lore.kernel.org is blocked by Anubis, do not bypass the challenge.
4. Try configured lore fallback servers or public mirrors such as Openwall.
5. If only the final patch is needed, check the corresponding kernel Git commit.
6. Avoid browser User-Agent spoofing and HTML scraping when machine-readable sources are available.
