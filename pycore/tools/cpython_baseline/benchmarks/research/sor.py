# pyperformance scimark_sor, SciMark 2.0 successive over-relaxation.
# The inner statement is the published SOR_execute kernel, omega 1.25:
#     G[x,y] = omega/4 * (four neighbors) + (1-omega) * G[x,y]
# Official size is n=100 for 10 cycles, on a zero matrix (the checksum of a
# zero matrix is zero). This grid is filled with a fixed pattern so the
# reduction is nonzero, and N / CYCLES are lower so Callgrind finishes.
# The grid is a list of lists, not array.array and not a class.
# Checksum: the sum of the interior after the cycles, scaled by 1e6.

N = 48
CYCLES = 6
OMEGA = 1.25


def make_grid(n):
    grid = []
    y = 0
    while y < n:
        row = []
        x = 0
        while x < n:
            row.append(((x * 13 + y * 7) % 100) / 100.0)
            x = x + 1
        grid.append(row)
        y = y + 1
    return grid


def sor_execute(grid, cycles):
    n = len(grid)
    p = 0
    while p < cycles:
        y = 1
        while y < n - 1:
            row = grid[y]
            up = grid[y - 1]
            down = grid[y + 1]
            x = 1
            while x < n - 1:
                row[x] = (
                    OMEGA * 0.25 * (up[x] + down[x] + row[x - 1] + row[x + 1])
                    + (1.0 - OMEGA) * row[x]
                )
                x = x + 1
            y = y + 1
        p = p + 1


def sor(n, cycles):
    grid = make_grid(n)
    sor_execute(grid, cycles)
    acc = 0.0
    y = 1
    while y < n - 1:
        x = 1
        while x < n - 1:
            acc = acc + grid[y][x]
            x = x + 1
        y = y + 1
    return acc


if __name__ == "__main__":
    print(int(sor(N, CYCLES) * 1000000.0))
