# Synthetic parser fixtures

These minimal examples are authored locally. They are not downloaded pages and never fetch their reserved `fixture.invalid` URLs. Gallery IDs and tokens are arbitrary samples; the canonical URL in the detail fixture exists only to exercise the parser's expected host pattern.

- `gallery-list.html`: compact table, relative paging cursors, a row without a gallery and normal metadata.
- `favorites.html`: cursor/search navigation, mixed category markup and thumbnail-only result fallback.
- `detail.html`: title, canonical identity, metadata, tag, rating and favorite state.
- `showpage.json`: reader API payload with embedded markup and encoded query strings.
