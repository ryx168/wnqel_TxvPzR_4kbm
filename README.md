# Site tooling

Editing runs on demand inside a GitHub Actions runner. Nothing is hosted here:
the database and content are restored from object storage at the start of a
session and written back at the end, and the public site is published as static
files.

- `Actions -> Edit session -> Run workflow` opens a session.
- `idle_minutes` stops it once the admin has been quiet that long.
- `tunnel: false` does a restore/export dry run without opening the editor.
- `export_only: true` exports and uploads the result as an artifact instead of
  publishing it, so a suspect export can be inspected first.

No credentials, database dumps or content live in this repository; they are
repository secrets and object storage respectively.
