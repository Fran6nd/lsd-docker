#!/usr/bin/env python3
# mkstructures.py -- the structures a bot leader may order built, as KV6
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
#
#   python3 bot/tools/mkstructures.py            write bot/structures/*.kv6
#   python3 bot/tools/mkstructures.py --check    read them back and check them
#   python3 bot/tools/mkstructures.py --check F  ... or the files named
#
# The models are made here, from code, so that what each voxel is for can
# be read and changed; the .kv6 files are what botd loads (core/kv6.h has
# the format). Each is built for a squad of about four to put up in a
# minute or two: a hundred voxels or so.
#
# AXES, as in the map: x and y across, z DOWN -- the model's ground layer
# is z = zsiz - 1. The FRONT is +y: the engine lays a structure out with
# its +y the way the leader who ordered it looks, so a door or a stair's
# foot on +y faces where he came from. THE PIVOT is the bottom centre of
# the footprint: (xsiz / 2, ysiz / 2, zsiz), the ground under the middle.
#
# --check reads a file as the engine's reader does (core/kv6.c: the same
# refusals, and the closed inside filled the same way) and then asks one
# more thing of a structure: every voxel stands on the ground through
# faces -- a flood from the bottom layer's voxels, face to face, reaches
# all of them. A bot builds a block only against another one, and a part
# held up by nothing would fall the moment it was cut off.
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "structures"))

SIDE_MAX = 64           # core/kv6.h BC_KV6_SIDE_MAX
HEAD = struct.Struct("<4s3I3fI")
BLOCK = struct.Struct("<IHBB")
# the fourth colour byte: 128 by custom, as SLAB6 and the game write it
COLOUR_TAG = 128

# A player stands a little under 3 voxels tall and jumps 1 up: a step is
# 1 above the last, with this much air above its tread.
HEADROOM = 3


class Model:
    """Voxels by layer above the ground (h = 0: on the ground), turned
    into the format's z (down) only when written."""

    def __init__(self, xs, ys, height):
        self.xs, self.ys, self.zs = xs, ys, height
        self.vox = {}

    def put(self, x, y, h, rgb):
        assert 0 <= x < self.xs and 0 <= y < self.ys and 0 <= h < self.zs, (x, y, h)
        self.vox[(x, y, self.zs - 1 - h)] = rgb

    def cut(self, x, y, h):
        self.vox.pop((x, y, self.zs - 1 - h), None)

    def column(self, x, y, h0, h1, rgb):
        for h in range(h0, h1 + 1):
            self.put(x, y, h, rgb)


# ---------------------------------------------------------------- models

def bunker():
    """A low walled box, 7 by 7 outside: walls 3 high, a roof slab on
    them. A firing slit on every side in the wall's top layer, which is
    where a standing man's eyes are (2.25 above his feet); the door, 1
    wide and the walls' 3 high, in the middle of the front (+y). Inside,
    5 by 5 with the walls' 3 of headroom."""
    side, wall_h = 7, 3
    wall, roof = 0x7D7A68, 0x55613F             # concrete; a roof in drab green
    m = Model(side, side, wall_h + 1)
    last = side - 1
    mid = side // 2
    eye = wall_h - 1                            # the walls' top layer
    for h in range(wall_h):
        for i in range(side):
            for x, y in ((i, 0), (i, last), (0, i), (last, i)):
                m.put(x, y, h, wall)
    for x in range(side):
        for y in range(side):
            m.put(x, y, wall_h, roof)
    # the door, front middle, floor to roof
    for h in range(wall_h):
        m.cut(mid, last, h)
    # the slits: three wide on the back and the flanks; on the front, one
    # on each side of the door, a wall voxel between it and the door and
    # one at the corner
    for i in range(mid - 1, mid + 2):
        m.cut(i, 0, eye)
        m.cut(0, i, eye)
        m.cut(last, i, eye)
    m.cut(mid - 2, last, eye)
    m.cut(mid + 2, last, eye)
    return m


def mirador():
    """A watchtower: four corner posts, a 5 by 5 platform on them at the
    eighth layer, and a rail one high round its edge. The way up winds
    inside the frame: seven steps round a centre pillar, each a column
    from the ground one higher than the last, the first one up from the
    ground at the front (+y) and the last one below the platform's level.
    The platform is open (a hatch) over the steps whose tread is within
    HEADROOM of its underside, so a man going up never has it over his
    head; he steps out of the hatch onto the platform."""
    side, deck = 5, 7                           # deck: the platform's layer
    post, plank, rail, tread = 0x4E3826, 0x8A6A44, 0x6B4F31, 0x9C7B50
    m = Model(side, side, deck + 2)             # the rail's layer on top
    last = side - 1
    c = side // 2
    for x, y in ((0, 0), (last, 0), (0, last), (last, last)):
        m.column(x, y, 0, deck - 1, post)
    m.column(c, c, 0, deck - 1, post)           # the pillar the stair winds round
    for x in range(side):
        for y in range(side):
            m.put(x, y, deck, plank)
            if x in (0, last) or y in (0, last):
                m.put(x, y, deck + 1, rail)
    # round the pillar from the front middle, going left (towards -x)
    ring = [(c, c + 1), (c - 1, c + 1), (c - 1, c), (c - 1, c - 1), (c, c - 1), (c + 1, c - 1), (c + 1, c)]
    assert len(ring) == deck, "a step a layer, the last one below the platform's"
    for i, (x, y) in enumerate(ring):
        m.column(x, y, 0, i, tread)
        # standing on step i the feet are at i + 1; air to i + HEADROOM
        if i + HEADROOM >= deck:
            m.cut(x, y, deck)
    # the step before the hatch too: from it a man jumps up under the
    # hatch's edge
    first_open = min(i for i in range(deck) if i + HEADROOM >= deck)
    m.cut(*ring[first_open - 1], deck)
    return m


MODELS = (("bunker", bunker), ("mirador", mirador))


# ---------------------------------------------------------------- writing

def faces(solid, x, y, z):
    """The visible faces, as the game's writer flags them: -x +x -y +y -z +z."""
    f = 0
    for bit, (dx, dy, dz) in enumerate(((-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1))):
        if (x + dx, y + dy, z + dz) not in solid:
            f |= 1 << bit
    return f


def encode(m):
    """The bytes of a KV6 file. Voxels with no face showing are left out,
    as the game's writer does: a reader fills the closed inside again."""
    solid = set(m.vox)
    blocks, xoffset, xyoffset = [], [0] * m.xs, [0] * (m.xs * m.ys)
    for x in range(m.xs):
        for y in range(m.ys):
            for z in range(m.zs):
                if (x, y, z) not in solid:
                    continue
                vis = faces(solid, x, y, z)
                if not vis:
                    continue
                r, g, b = m.vox[(x, y, z)] >> 16 & 255, m.vox[(x, y, z)] >> 8 & 255, m.vox[(x, y, z)] & 255
                colour = b | g << 8 | r << 16 | COLOUR_TAG << 24
                blocks.append(BLOCK.pack(colour, z, vis, 0))
                xoffset[x] += 1
                xyoffset[x * m.ys + y] += 1
    out = [HEAD.pack(b"Kvxl", m.xs, m.ys, m.zs, m.xs / 2, m.ys / 2, float(m.zs), len(blocks))]
    out += blocks
    out.append(struct.pack("<%dI" % m.xs, *xoffset))
    out.append(struct.pack("<%dH" % len(xyoffset), *xyoffset))
    return b"".join(out)


# ---------------------------------------------------------------- reading

class Refused(Exception):
    pass


def decode(data):
    """As core/kv6.c: (xs, ys, zs, pivot, {(x, y, z): rgb}) with the closed
    inside filled, or Refused with the reason."""
    if len(data) < HEAD.size:
        raise Refused("truncated: shorter than a KV6 header")
    magic, xs, ys, zs, px, py, pz, blklen = HEAD.unpack_from(data, 0)
    if magic != b"Kvxl":
        raise Refused('not a KV6 file (no "Kvxl" at the start)')
    if not all(1 <= s <= SIDE_MAX for s in (xs, ys, zs)):
        raise Refused("size %dx%dx%d: each side 1 to %d" % (xs, ys, zs, SIDE_MAX))
    if any(v != v or v in (float("inf"), float("-inf")) for v in (px, py, pz)):
        raise Refused("the pivot is not a number")
    if blklen > xs * ys * zs:
        raise Refused("%d blocks in %d cells" % (blklen, xs * ys * zs))
    if blklen == 0:
        raise Refused("an empty model: no voxel listed")
    xy_at = HEAD.size + blklen * BLOCK.size + xs * 4
    need = xy_at + xs * ys * 2
    if len(data) < need:
        raise Refused("truncated: %d bytes, %d needed" % (len(data), need))
    xyoffset = struct.unpack_from("<%dH" % (xs * ys), data, xy_at)
    if sum(xyoffset) != blklen:
        raise Refused("the columns hold %d blocks, the header says %d" % (sum(xyoffset), blklen))
    vox, pos = {}, 0
    for x in range(xs):
        for y in range(ys):
            last = -1
            for _ in range(xyoffset[x * ys + y]):
                colour, z, _vis, _light = BLOCK.unpack_from(data, HEAD.size + pos * BLOCK.size)
                if z >= zs:
                    raise Refused("block %d: z %d outside a model %d deep" % (pos, z, zs))
                if z <= last:
                    raise Refused("column (%d, %d): z %d after %d, not rising (a duplicate, or not sorted)"
                                  % (x, y, z, last))
                last = z
                vox[(x, y, z)] = colour & 0xFFFFFF     # B, G, R bytes: 0xRRGGBB
                pos += 1
    # the closed inside: what no air from the volume's sides reaches is
    # solid, coloured as the voxel right above it (already settled: z rising)
    outside = set()
    stack = [(x, y, z) for x in range(xs) for y in range(ys) for z in range(zs)
             if (x in (0, xs - 1) or y in (0, ys - 1) or z in (0, zs - 1)) and (x, y, z) not in vox]
    outside.update(stack)
    while stack:
        p = stack.pop()
        for q in neighbours(p, xs, ys, zs):
            if q not in vox and q not in outside:
                outside.add(q)
                stack.append(q)
    for z in range(zs):
        for y in range(ys):
            for x in range(xs):
                if (x, y, z) not in vox and (x, y, z) not in outside:
                    vox[(x, y, z)] = vox[(x, y, z - 1)]
    return xs, ys, zs, (px, py, pz), vox


def neighbours(p, xs, ys, zs):
    x, y, z = p
    for dx, dy, dz in ((-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1)):
        q = (x + dx, y + dy, z + dz)
        if 0 <= q[0] < xs and 0 <= q[1] < ys and 0 <= q[2] < zs:
            yield q


def unsupported(vox, xs, ys, zs):
    """The voxels no face-to-face path joins to the bottom layer."""
    stack = [p for p in vox if p[2] == zs - 1]
    held = set(stack)
    while stack:
        for q in neighbours(stack.pop(), xs, ys, zs):
            if q in vox and q not in held:
                held.add(q)
                stack.append(q)
    return sorted(set(vox) - held)


def check(path):
    with open(path, "rb") as f:
        data = f.read()
    try:
        xs, ys, zs, pivot, vox = decode(data)
    except Refused as e:
        print("%s: refused: %s" % (path, e))
        return False
    loose = unsupported(vox, xs, ys, zs)
    if loose:
        print("%s: %d voxel%s not on the ground through faces, first %s"
              % (path, len(loose), "" if len(loose) == 1 else "s", loose[0]))
        return False
    if pivot != (xs / 2, ys / 2, float(zs)):
        print("%s: pivot %s, not the bottom centre %s" % (path, pivot, (xs / 2, ys / 2, float(zs))))
        return False
    print("%s: ok, %dx%dx%d, %d voxels, %d colours" % (path, xs, ys, zs, len(vox), len(set(vox.values()))))
    return True


def main(argv):
    if argv[:1] == ["--check"]:
        paths = argv[1:] or [os.path.join(OUT_DIR, name + ".kv6") for name, _ in MODELS]
        return 0 if all([check(p) for p in paths]) else 1
    if argv:
        print("usage: mkstructures.py [--check [FILE...]]", file=sys.stderr)
        return 2
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, make in MODELS:
        m = make()
        path = os.path.join(OUT_DIR, name + ".kv6")
        with open(path, "wb") as f:
            f.write(encode(m))
        print("%s: %dx%dx%d, %d voxels" % (os.path.normpath(path), m.xs, m.ys, m.zs, len(m.vox)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
