"""Installed entry point for xtool's native release pipeline."""
import sys

from .release import main

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, AssertionError) as error:
        print(f'xtool release: {error}', file=sys.stderr)
        raise SystemExit(1) from None
