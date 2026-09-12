class Point:
    def __init__(self, x, y):
        self.x = x
        self.y = y

    def dot(self, other):
        return self.x * other.x + self.y * other.y


def managed_entry():
    pts = []
    i = 0
    while i < 20:
        pts.append(Point(i, i + 1))
        i = i + 1
    total = 0
    j = 0
    while j < 20:
        total = total + pts[j].dot(pts[19 - j])
        j = j + 1
    return total


managed_entry()
