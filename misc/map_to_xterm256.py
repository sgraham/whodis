"""Maps from #rrggbb to an xterm256 index suitable for using in Vim syntax
definitions. Just uses 3D distance, not anything smart.

xterm256 colour definitions in colour_data.json from
https://jonasjacek.github.io/colors/data.json.
"""

import json
import math
import os
import sys

SCRIPT_DIR = os.path.dirname(__file__)


def _Distance(a, b):
    x = (a[0] - b[0]) ** 2
    y = (a[1] - b[1]) ** 2
    z = (a[2] - b[2]) ** 2
    return math.sqrt(x + y + z)


def main():
  json_data = json.load(open(os.path.join(SCRIPT_DIR, 'colour_data.json'), 'r'))
  colours = [(x['rgb']['r'], x['rgb']['g'], x['rgb']['b']) for x in json_data]
  if len(colours) != 256:
    print 'expected 256 xterm colours'
    return 1

  for rgb in sys.stdin.readlines():
    rgb = rgb.strip(' #\n')
    if len(rgb) != 6:
      print 'unrecognized input', rgb
      continue
    r, g, b = int(rgb[0:2], 16), int(rgb[2:4], 16), int(rgb[4:6], 16)
    min_dist = 9999999999
    for i, c in enumerate(colours):
      d = _Distance((r, g, b), c)
      if d < min_dist:
        min_dist = d
        best = i
    print best


if __name__ == "__main__":
  sys.exit(main())
