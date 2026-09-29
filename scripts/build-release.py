#!/usr/bin/env python3
"""Run the same release package installed by xtool's native bootstrap."""
from pathlib import Path
import runpy
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Tools/Release'))
runpy.run_module('xtool_release', run_name='__main__')
