"""Allow `python3 -m registry …` to dispatch to the CLI."""
from registry.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
