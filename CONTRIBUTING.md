# Contributing to colorful

## Commit messages

colorful uses [Conventional Commits](https://www.conventionalcommits.org/).
Every non-merge commit subject must use:

```text
type(optional-scope): short description
```

Keep the subject at 100 characters or fewer. Use an imperative description,
keep unrelated changes in separate commits, and add `!` before the colon for a
breaking change.

Supported types:

- `feat`: user-visible functionality;
- `fix`: a bug fix;
- `perf`: a performance improvement;
- `refactor`: internal restructuring without a behavior change;
- `build`: build, packaging, versioning, or dependency work;
- `ci`: automation and workflow changes;
- `docs`: documentation only;
- `test`: test coverage or test infrastructure;
- `style`: formatting or visual-only changes;
- `chore`: repository maintenance that fits no other type;
- `revert`: reverting an earlier commit.

Examples:

```text
feat(home): add cross-provider daily mixes
fix(windows): use native text rendering at fractional DPI
perf(youtube): reuse cached player transforms
build(release): add labelled desktop dev artifacts
```

Commit bodies should explain why the change exists when the subject is not
self-explanatory. Put issue references and `BREAKING CHANGE:` details in the
footer.

The commit-style workflow validates new commits and pull-request commits with
`scripts/check-commit-style.sh`. Release notes are generated directly from
these subjects and grouped by type, so the convention applies equally to
direct commits and pull requests.

## Releases

`VERSION` remains the authoritative stable version. A matching annotated tag
starts the desktop release workflow:

```bash
git tag -a v0.2.0 -m "A short message for people installing this release."
git push origin v0.2.0
```

The annotated tag message is placed above the automatically generated,
type-grouped changelog. For a longer Markdown introduction, prepare a temporary
file and use `git tag -a v0.2.0 -F /path/to/release-intro.md`; the file does not
need to be committed.
