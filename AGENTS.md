<!-- trav-ai:start -->
<!-- Managed by `trav ai` and regenerated on every install. Put project rules outside this section, below the end marker. -->

# basic/rules

## Git Conventions
Atomic commits.
Ban committing secrets, credentials, or large binary files.
Split large changes into a stack of dependent PRs.

## Code Design
Solve every problem with the smallest diff possible.
Reduce coupling.
No new dependencies without explicit approval.
Fail Fast.
Do not add caching unless given explicit approval.
Testing: quality over quantity.
No abstraction, generic or extension point with a single use; no code for requirements that do not exist yet.
No design pattern the problem does not force; no Singletons — pass the dependency.
No `Manager`, `Helper`, `Utils` class names.
At most 3 parameters; no boolean flag parameters — split the function.
Nesting depth at most 3 — use early returns.
No commented-out code.
Cleaning up never changes behaviour.

Flag insecure patterns or known anti-patterns

## Documentation
Documentation explain *why* code exists.
Documentation is never in past tense.
Keep documentation up to date.
Keep documentation lean.

## Decisions
Settled a durable trade-off, or reversed one? Record it with the `docs-author` skill.

# python/rules

## Tooling

require: zero Ruff warnings — run `poetry run ruff check .` before committing
require: dependencies through Poetry (`poetry add`, `poetry remove`, `poetry install`); `pip` only to bootstrap tooling or throwaway environments

## Code

require: custom exception types for domain errors; ban `raise Exception(...)`
ban: function-level imports, including to break an import cycle — move the shared types to their own module
require: Google-style docstrings (`Args`, `Returns`, `Raises`) on every function and method; a module docstring in every `__init__.py` stating the package's responsibility
require: `logger = logging.getLogger(__name__)` per module; ban `print()` for logging; applications configure logging once, in `logging.py`
require: timezone-aware UTC timestamps — `datetime.datetime.now(tz=datetime.timezone.utc)`
require: `pathlib.Path` for paths
require: `dataclass` (prefer `frozen=True`) for plain data, `pydantic` where validation is needed, `Enum` for fixed value sets; convert raw `dict`s to one of these at the boundary
require: type hints on every signature — `T | None` and built-in generics (`list[T]`) on 3.10+, `Self` for current-class returns; `_` prefix for module-private names; `__all__` in every `__init__.py`

## Async

ban: blocking I/O in `async def` — use `httpx`, `asyncpg`, `aiofiles`
ban: `asyncio.run()` outside the top-level entry point
prefer: `asyncio.gather()` for independent coroutines

## Security

require: secrets from the project's credentials service (Doppler-backed), never from code or files
require: `subprocess` with an argument list and `shell=False` for anything user-controlled; ban `os.system` and `eval` on such input
require: paths from external input resolved with `Path.resolve()` and checked against an allowed base directory
<!-- trav-ai:end -->
