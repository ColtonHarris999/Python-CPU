# Integer n-body, three bodies. Nested loops and list-of-list updates,
# in the shape of pyperformance's nbody without floats or imports.
bodies = [
    [0, 0, 0, 0, 0, 0],
    [1000, 0, 0, 0, 10, 0],
    [0, 1000, 0, -10, 0, 0],
]
step = 0
while step < 20:
    i = 0
    while i < 3:
        j = i + 1
        while j < 3:
            dx = bodies[i][0] - bodies[j][0]
            dy = bodies[i][1] - bodies[j][1]
            dz = bodies[i][2] - bodies[j][2]
            dist2 = dx * dx + dy * dy + dz * dz
            mag = 1000000 // dist2
            bodies[i][3] = bodies[i][3] - dx * mag // 1000
            bodies[i][4] = bodies[i][4] - dy * mag // 1000
            bodies[i][5] = bodies[i][5] - dz * mag // 1000
            bodies[j][3] = bodies[j][3] + dx * mag // 1000
            bodies[j][4] = bodies[j][4] + dy * mag // 1000
            bodies[j][5] = bodies[j][5] + dz * mag // 1000
            j = j + 1
        i = i + 1
    i = 0
    while i < 3:
        bodies[i][0] = bodies[i][0] + bodies[i][3]
        bodies[i][1] = bodies[i][1] + bodies[i][4]
        bodies[i][2] = bodies[i][2] + bodies[i][5]
        i = i + 1
    step = step + 1
s = 0
i = 0
while i < 3:
    s = s + bodies[i][0] + bodies[i][1] + bodies[i][2]
    i = i + 1
print(s)
